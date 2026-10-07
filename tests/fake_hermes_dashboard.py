#!/usr/bin/env python3
"""Fake Hermes dashboard gateway (127.0.0.1 only) for tests/HermesSignInTests.swift.

Usage: python3 fake_hermes_dashboard.py <port-file>

It stands in for the real server: nothing here talks to any other host, and every token is made up.

HTTP
  GET  /auth/native/authorize   S256 + loopback redirect_uri checks, then 302 to redirect_uri?code&state
  POST /auth/native/token       {"code","code_verifier"}: single use code, PKCE verified, else 400
  POST /auth/native/refresh     {"refresh_token","provider"}: rotates; unknown or reused RT -> 401 session_expired
  GET  /api/auth/me, GET /api/profiles, POST /api/auth/ws-ticket   bearer required, else 401 session_expired
  GET  /api/ws                  WebSocket (JSON-RPC 2.0 text frames), ticket in subprotocol or in the query
Test control
  POST /_test/reset             back to defaults
  POST /_test/config            JSON merged into the config (see CONFIG)
  GET  /_test/state             counters and logs seen by the server
  GET  /api/captured            target of the redirect test; records whether Authorization arrived

CONFIG
  expires_in            seconds of life of new access tokens (default 3600)
  no_refresh            token answers carry no refresh_token
  authorize_mode        ok | bad_state | error | no_code
  refresh_mode          ok | 503 | slow (0.5 s)
  ticket_401            answer the next N ticket requests with 401
  reject_subprotocol    the subprotocol ticket form is refused (403 before the upgrade)
  profiles_redirect     /api/profiles answers 302 to /api/captured
  ready_delay           seconds to wait before gateway.ready (cancellation while the socket is not ready yet)
  omit_stored_id        session.create answers without stored_session_id
  ticket_drop           accept the next N ticket requests and close the connection without answering (counted)
  ticket_status         answer every ticket request with this HTTP status (0 = normal)
  refresh_drop          accept the next N refresh requests, READ THE WHOLE BODY, then close without answering (the token
                        is not rotated; the request reached the server, so the client must not send it again)
  ws_drop               accept the next N WebSocket handshakes and close without answering (ticket not consumed)
  ws_stall              hold the next N WebSocket handshakes for ws_stall_seconds, then close without answering
  ws_stall_seconds      how long a stalled handshake is held (default 2)
  profiles_drop         accept the next N /api/profiles requests and close without answering
  ticket_delay          seconds every ticket request waits before it answers (round trip latency)

WebSocket prompt scenarios (the prompt text picks one): hello, error, error-partial, bare-error, close,
approval, withdrawn, busy, queued, queued-early, queued-noterm, queued-start-first, binary, binary-flood, steered, redirected, early-terminal, early-error, submit-slow,
silence, flood, flood-big, slow, big, echo-history, ping-wait, foreign, close-empty.

  queued        the submit answers "queued"; the earlier turn ends (interrupted), then the queued turn runs and answers
  queued-early  the earlier turn's terminal event arrives BEFORE the "queued" answer, then the queued turn runs
  queued-noterm the "queued" answer, and NO terminal event of the earlier turn on this socket: only its delta,
                then the drained turn's message.start, deltas and complete
  queued-start-first   the drained turn's message.start (and first delta) arrive BEFORE the "queued" answer
  binary        one binary frame in the middle of the turn, then the rest of a normal turn
  binary-flood  an answer start, then thousands of binary frames
  steered, redirected   accepted into the live turn: same answer statuses as the real server, then a normal turn
  early-terminal, early-error   the terminal event arrives BEFORE the prompt.submit answer (the real server starts the
                run thread first)
  submit-slow   prompt.submit answers after 1 s
  silence       no frame at all for 22.5 s, then the answer
  flood, flood-big   an answer start, then many small / a few large unknown events

"""

import base64
import hashlib
import json
import re
import secrets
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOOPBACK = re.compile(r"^http://(127\.0\.0\.1|\[::1\])(:\d+)?/[^\s\\#@]*$")

DEFAULT_CONFIG = {
    "expires_in": 3600, "no_refresh": False, "authorize_mode": "ok", "refresh_mode": "ok",
    "ticket_401": 0, "reject_subprotocol": False, "profiles_redirect": False,
    "ready_delay": 0, "omit_stored_id": False,
    "ticket_drop": 0, "ticket_status": 0, "refresh_drop": 0, "ws_drop": 0, "ws_stall": 0, "ws_stall_seconds": 2,
    "profiles_drop": 0, "ticket_delay": 0,
}


LOCK = threading.RLock()
CONFIG = dict(DEFAULT_CONFIG)


def take(key):
    """True while the counter CONFIG[key] still has failures to hand out (and uses one up)."""
    with LOCK:
        if CONFIG[key] > 0:
            CONFIG[key] -= 1
            return True
    return False


STATE = {}


def reset():
    with LOCK:
        CONFIG.clear()
        CONFIG.update(DEFAULT_CONFIG)
        STATE.clear()
        STATE.update({
            "codes": {}, "access": {}, "refresh": {}, "tickets": {}, "sessions": {}, "runtime": {},
            "refresh_count": 0, "authorize_count": 0, "token_count": 0, "ticket_count": 0, "profiles_count": 0,
            "ticket_bearers": [], "ws": [], "rpc": [], "interrupts": [], "rejections": [], "pings": 0,
            "closes": 0, "captured_hits": 0, "captured_with_auth": 0, "counter": 0,
        })


reset()


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def next_id():
    with LOCK:
        STATE["counter"] += 1
        return STATE["counter"]


def issue_tokens():
    with LOCK:
        access = "at-" + secrets.token_hex(12)
        exp = time.time() + CONFIG["expires_in"]
        STATE["access"][access] = exp
        body = {"access_token": access, "token_type": "Bearer", "expires_at": int(exp),
                "provider": "self-hosted", "user_id": "u1"}
        if not CONFIG["no_refresh"]:
            rt = "rt-" + secrets.token_hex(12)
            STATE["refresh"][rt] = True
            body["refresh_token"] = rt
        return body


# ── WebSocket helpers ────────────────────────────────────────────────────────

class Conn:
    def __init__(self, handler):
        self.h = handler
        self.wlock = threading.Lock()
        self.interrupted = threading.Event()
        self.closed = threading.Event()

    def send_frame(self, opcode, payload):
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([n])
        elif n < 65536:
            head += bytes([126]) + struct.pack(">H", n)
        else:
            head += bytes([127]) + struct.pack(">Q", n)
        with self.wlock:
            try:
                self.h.wfile.write(head + payload)
                self.h.wfile.flush()
            except OSError:
                self.closed.set()

    def send_json(self, obj):
        self.send_frame(0x1, json.dumps(obj).encode())

    def event(self, etype, session=None, payload=None):
        params = {"type": etype}
        if session is not None:
            params["session_id"] = session
        if payload is not None:
            params["payload"] = payload
        self.send_json({"jsonrpc": "2.0", "method": "event", "params": params})

    def read_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.h.rfile.read(n - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    def read_frame(self):
        b1, b2 = self.read_exact(2)
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self.read_exact(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self.read_exact(8))[0]
        mask = self.read_exact(4) if masked else b""
        payload = self.read_exact(n)
        if masked:
            payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        return opcode, payload


def scenario(conn, runtime, text, stored):
    """Runs on its own thread after prompt.submit answered 'streaming'."""
    sid = runtime
    try:
        if text in ("close", "close-empty"):
            conn.event("message.start", sid)
            if text == "close":
                conn.event("message.delta", sid, {"text": "partial answer"})
            time.sleep(0.15)
            conn.send_frame(0x8, struct.pack(">H", 1011))
            try:
                conn.h.connection.shutdown(2)
            except OSError:
                pass
            return
        if text == "error":
            conn.event("message.complete", sid, {"text": "", "status": "error", "error": "boom from the agent"})
            return
        if text == "error-partial":
            conn.event("message.delta", sid, {"text": "half an answer"})
            conn.event("message.complete", sid, {"text": "", "status": "error", "error": "provider failed"})
            return
        if text == "bare-error":
            conn.event("error", sid, {"message": "bare boom"})
            return
        if text == "approval":
            conn.send_json({"jsonrpc": "2.0", "id": "srq-" + secrets.token_hex(6), "method": "approval",
                            "params": {"session_id": sid, "request_id": "r1", "command": "rm -rf /tmp/x",
                                       "description": "test", "choices": ["once", "session", "always", "deny"]}})
            time.sleep(0.3)
            conn.event("message.delta", sid, {"text": "continued after the approval."})
            conn.event("message.complete", sid, {"text": "continued after the approval.", "status": "complete"})
            return
        if text == "withdrawn":
            conn.event("tool.complete", sid, {"name": "terminal", "preview": "approval was withdrawn before the user answered"})
            conn.event("message.complete", sid, {"text": "I could not run that.", "status": "complete"})
            return
        if text == "slow":
            for i in range(300):
                if conn.interrupted.is_set() or conn.closed.is_set():
                    break
                conn.event("message.delta", sid, {"text": "tick%d " % i})
                time.sleep(0.1)
            if conn.interrupted.is_set():
                conn.event("message.complete", sid, {"text": "", "status": "interrupted"})
            return
        if text == "big":
            for i in range(40):
                if conn.interrupted.is_set() or conn.closed.is_set():
                    break
                conn.event("message.delta", sid, {"text": "x" * 400})
                time.sleep(0.02)
            for _ in range(100):
                if conn.interrupted.is_set() or conn.closed.is_set():
                    break
                time.sleep(0.05)
            return
        if text in ("queued", "queued-early", "queued-noterm", "queued-start-first"):
            if text in ("queued", "queued-noterm"):
                conn.event("message.delta", sid, {"text": "OLD "})
                time.sleep(0.15)
            if text == "queued":
                conn.event("message.complete", sid, {"text": "OLD", "status": "interrupted"})
            parts = ("Drained ", "answer.")
            if text == "queued-start-first":
                parts = ("answer.",)   # the start and "Drained " went out before the answer
            else:
                time.sleep(0.15)
                conn.event("message.start", sid)
            for part in parts:
                conn.event("message.delta", sid, {"text": part})
                time.sleep(0.03)
            conn.event("message.complete", sid, {"text": "Drained answer.", "status": "complete"})
            return
        if text == "binary":
            conn.event("message.start", sid)
            conn.event("message.delta", sid, {"text": "before "})
            conn.send_frame(0x2, b"\x00\x01\x02 binary frame")
            conn.event("message.delta", sid, {"text": "after."})
            conn.event("message.complete", sid, {"text": "before after.", "status": "complete"})
            return
        if text == "binary-flood":
            conn.event("message.delta", sid, {"text": "start "})
            for i in range(3000):
                if conn.interrupted.is_set() or conn.closed.is_set():
                    break
                conn.send_frame(0x2, b"\x00" * 100)
            for _ in range(100):
                if conn.interrupted.is_set() or conn.closed.is_set():
                    break
                time.sleep(0.05)
            return
        if text == "silence":
            time.sleep(22.5)
            conn.event("message.delta", sid, {"text": "quiet answer"})
            conn.event("message.complete", sid, {"text": "quiet answer", "status": "complete"})
            return
        if text in ("flood", "flood-big"):
            conn.event("message.delta", sid, {"text": "start "})
            pad = "z" * (1000 if text == "flood" else 200000)
            for i in range(3000 if text == "flood" else 40):
                if conn.interrupted.is_set() or conn.closed.is_set():
                    break
                conn.event("tool.progress", sid, {"name": "noise", "pad": pad})
            for _ in range(100):
                if conn.interrupted.is_set() or conn.closed.is_set():
                    break
                time.sleep(0.05)
            return
        if text == "ping-wait":
            time.sleep(1.6)
            conn.event("message.delta", sid, {"text": "waited"})
            conn.event("message.complete", sid, {"text": "waited", "status": "complete"})
            return
        if text == "foreign":
            conn.event("message.delta", "someone-else", {"text": "WRONG "})
            conn.event("message.complete", "someone-else", {"text": "WRONG", "status": "complete"})
        if text == "echo-history":
            with LOCK:
                n = len(STATE["sessions"][stored]["prompts"])
            answer = "prompts=%d" % n
            conn.event("message.delta", sid, {"text": answer})
            conn.event("message.complete", sid, {"text": answer, "status": "complete"})
            return
        # hello (default)
        conn.event("message.start", sid)
        for part in ("Hello ", "from ", "Steve."):
            conn.event("message.delta", sid, {"text": part, "rendered": part})
            time.sleep(0.03)
        conn.event("tool.progress", sid, {"name": "unknown event kinds must be ignored"})
        conn.event("message.complete", sid, {"text": "Hello from Steve.", "status": "complete",
                                             "usage": {"input": 1, "output": 3}})
    except OSError:
        pass


def serve_socket(conn):
    runtime_to_stored = {}
    while True:
        try:
            opcode, payload = conn.read_frame()
        except (EOFError, OSError):
            break
        if opcode == 0x8:
            conn.send_frame(0x8, payload[:2])
            break
        if opcode == 0x9:
            conn.send_frame(0xA, payload)
            continue
        if opcode != 0x1:
            continue
        try:
            msg = json.loads(payload.decode())
        except ValueError:
            conn.send_json({"jsonrpc": "2.0", "error": {"code": -32700, "message": "parse error"}, "id": None})
            continue
        # A response to a server request (our approval).
        if "method" not in msg and "error" in msg and isinstance(msg.get("id"), str):
            with LOCK:
                STATE["rejections"].append(msg["error"].get("code"))
            continue
        method = msg.get("method")
        rid = msg.get("id")
        params = msg.get("params") or {}
        if method == "gateway.ping":
            with LOCK:
                STATE["pings"] += 1
            conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {"ok": True}})
            continue
        with LOCK:
            STATE["rpc"].append({"method": method, "params": params})

        def reply(result):
            conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})

        def fail(code, message):
            conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})

        if method == "session.create":
            n = next_id()
            stored, runtime = "stored-%d" % n, "run-%d" % n
            with LOCK:
                STATE["sessions"][stored] = {"prompts": []}
            runtime_to_stored[runtime] = stored
            result = {"session_id": runtime, "stored_session_id": stored, "messages": [],
                      "info": {"model": "fake-model", "profile_name": params.get("profile", "default")}}
            with LOCK:
                if CONFIG["omit_stored_id"]:
                    del result["stored_session_id"]
            reply(result)
        elif method == "session.resume":
            stored = params.get("session_id", "")
            if not stored:
                fail(4006, "session_id required")
            elif stored not in STATE["sessions"]:
                fail(4001, "session not found")
            else:
                runtime = "run-%d" % next_id()
                runtime_to_stored[runtime] = stored
                reply({"session_id": runtime, "resumed": stored, "message_count": len(STATE["sessions"][stored]["prompts"]),
                       "messages": [], "messages_omitted": True, "info": {"model": "fake-model"}, "running": False})
        elif method == "prompt.submit":
            runtime = params.get("session_id", "")
            text = params.get("text", "")
            stored = runtime_to_stored.get(runtime)
            if stored is None:
                fail(4001, "session not found")
                continue
            if text == "busy":
                fail(4009, "session busy")
                continue
            with LOCK:
                STATE["sessions"][stored]["prompts"].append(text)   # accepted: the message is on the server
            if text == "submit-slow":
                time.sleep(1.0)
            status = text if text in ("steered", "redirected") else "queued" if text.startswith("queued") else "streaming"
            if text in ("early-terminal", "early-error", "queued-early", "queued-start-first"):
                # The run thread starts before the answer: its terminal event can overtake the answer.
                if text == "early-terminal":
                    conn.event("message.complete", runtime, {"text": "Early answer.", "status": "complete"})
                elif text == "early-error":
                    conn.event("error", runtime, {"message": "early boom"})
                elif text == "queued-start-first":
                    conn.event("message.delta", runtime, {"text": "OLD "})
                    conn.event("message.complete", runtime, {"text": "OLD", "status": "interrupted"})
                    conn.event("message.start", runtime)
                    conn.event("message.delta", runtime, {"text": "Drained "})
                else:
                    conn.event("message.complete", runtime, {"text": "OLD", "status": "interrupted"})
            reply({"status": status})
            if text not in ("early-terminal", "early-error"):
                threading.Thread(target=scenario, args=(conn, runtime, text, stored), daemon=True).start()
        elif method == "session.interrupt":
            with LOCK:
                STATE["interrupts"].append(params.get("session_id"))
            conn.interrupted.set()
            reply({"status": "interrupted"})
        else:
            fail(-32601, "method not found")
    conn.closed.set()
    with LOCK:
        STATE["closes"] += 1


# ── HTTP ─────────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, status, obj, extra=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw.decode() or "{}")
        except ValueError:
            return None

    def bearer(self):
        h = self.headers.get("Authorization", "")
        return h[7:] if h.startswith("Bearer ") else None

    def authed(self):
        token = self.bearer()
        with LOCK:
            exp = STATE["access"].get(token)
        if exp is None or exp < time.time():
            self.send_json(401, {"error": "session_expired", "reason": "invalid_or_expired_session"})
            return None
        return token

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path
        if path == "/auth/native/authorize":
            return self.authorize(q)
        if path == "/api/ws":
            return self.websocket(q)
        if path == "/_test/state":
            with LOCK:
                snap = {k: v for k, v in STATE.items() if k not in ("codes", "access", "refresh", "tickets", "runtime")}
                snap["sessions"] = {k: len(v["prompts"]) for k, v in STATE["sessions"].items()}
                snap["live_refresh_tokens"] = sum(1 for v in STATE["refresh"].values() if v)
            return self.send_json(200, snap)
        if path == "/api/captured":
            with LOCK:
                STATE["captured_hits"] += 1
                if self.headers.get("Authorization"):
                    STATE["captured_with_auth"] += 1
            return self.send_json(200, {"ok": True})
        if path == "/api/auth/me":
            if self.authed() is None:
                return
            return self.send_json(200, {"user_id": "u1", "email": "tester@example.test", "display_name": "Test User",
                                        "org_id": None, "provider": "self-hosted", "expires_at": int(time.time()) + 100})
        if path == "/api/profiles":
            with LOCK:
                STATE["profiles_count"] += 1
                redirect = CONFIG["profiles_redirect"]
            if take("profiles_drop"):
                self.close_connection = True
                return
            if redirect:
                return self.send_json(302, {}, {"Location": "/api/captured"})
            if self.authed() is None:
                return
            return self.send_json(200, {"profiles": [
                {"name": "default", "is_default": True, "display_name": "Default", "description": "", "model": "m"},
                {"name": "codex", "is_default": False, "display_name": "Steve", "description": "", "model": "m"},
                {"name": "bad name!", "is_default": False, "display_name": "Skipped"},
            ]})
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/_test/reset":
            self.body_json()
            reset()
            return self.send_json(200, {"ok": True})
        if path == "/_test/config":
            body = self.body_json() or {}
            with LOCK:
                CONFIG.update(body)
            return self.send_json(200, {"ok": True})
        if path == "/auth/native/token":
            return self.token()
        if path == "/auth/native/refresh":
            return self.refresh()
        if path == "/api/auth/ws-ticket":
            self.body_json()
            with LOCK:
                STATE["ticket_count"] += 1
            if take("ticket_drop"):
                self.close_connection = True
                return
            with LOCK:
                delay = CONFIG["ticket_delay"]
            if delay:
                time.sleep(delay)
            with LOCK:
                if CONFIG["ticket_status"]:
                    return self.send_json(CONFIG["ticket_status"], {"error": "boom"})
                if CONFIG["ticket_401"] > 0:
                    CONFIG["ticket_401"] -= 1
                    return self.send_json(401, {"error": "session_expired", "reason": "invalid_or_expired_session"})
            token = self.authed()
            if token is None:
                return
            ticket = secrets.token_urlsafe(32)
            with LOCK:
                STATE["tickets"][ticket] = time.time() + 30
                STATE["ticket_bearers"].append(token)
            return self.send_json(200, {"ticket": ticket, "ttl_seconds": 30})
        self.send_json(404, {"error": "not found"})

    def authorize(self, q):
        with LOCK:
            STATE["authorize_count"] += 1
            mode = CONFIG["authorize_mode"]
        redirect = q.get("redirect_uri", "")
        if q.get("code_challenge_method") != "S256" or not q.get("code_challenge") or not LOOPBACK.match(redirect) or not q.get("state"):
            return self.send_json(400, {"detail": "bad authorize request"})
        sep = "&" if "?" in redirect else "?"
        if mode == "error":
            loc = "%s%serror=access_denied&state=%s" % (redirect, sep, q["state"])
        elif mode == "no_code":
            loc = "%s%sstate=%s" % (redirect, sep, q["state"])
        else:
            code = "code-" + secrets.token_urlsafe(18)
            with LOCK:
                STATE["codes"][code] = q["code_challenge"]
            state = "tampered" if mode == "bad_state" else q["state"]
            loc = "%s%scode=%s&state=%s" % (redirect, sep, code, state)
        self.send_response(302)
        self.send_header("Location", loc)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def token(self):
        body = self.body_json() or {}
        code, verifier = body.get("code", ""), body.get("code_verifier", "")
        with LOCK:
            STATE["token_count"] += 1
            challenge = STATE["codes"].pop(code, None)   # consumed on every path
        if challenge is None or b64url(hashlib.sha256(verifier.encode()).digest()) != challenge:
            return self.send_json(400, {"detail": "Invalid or expired authorization code."})
        self.send_json(200, issue_tokens())

    def refresh(self):
        body = self.body_json() or {}
        rt = body.get("refresh_token", "")
        with LOCK:
            STATE["refresh_count"] += 1
            mode = CONFIG["refresh_mode"]
        if take("refresh_drop"):
            self.close_connection = True
            return
        if not rt:
            return self.send_json(400, {"detail": "refresh_token required"})
        if mode == "503":
            return self.send_json(503, {"detail": "Auth provider unreachable"})
        if mode == "slow":
            time.sleep(0.5)
        with LOCK:
            live = STATE["refresh"].get(rt)
            if live:
                STATE["refresh"][rt] = False   # rotation: the old one is dead
        if not live:
            return self.send_json(401, {"error": "session_expired", "detail": "Refresh token expired or invalid; start a new sign-in."})
        self.send_json(200, issue_tokens())

    def websocket(self, q):
        key = self.headers.get("Sec-WebSocket-Key")
        entry = {"origin": self.headers.get("Origin"), "authorization": bool(self.headers.get("Authorization")),
                 "cookie": bool(self.headers.get("Cookie")), "protocols": self.headers.get("Sec-WebSocket-Protocol"),
                 "form": None, "accepted": False}
        with LOCK:
            STATE["ws"].append(entry)

        def refuse():
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

        if take("ws_drop"):
            self.close_connection = True
            return
        if take("ws_stall"):
            with LOCK:
                hold = CONFIG["ws_stall_seconds"]
            time.sleep(hold)
            self.close_connection = True
            return
        if not key or self.headers.get("Origin"):
            return refuse()
        protocols = [p.strip() for p in (self.headers.get("Sec-WebSocket-Protocol") or "").split(",") if p.strip()]
        tickets = [p for p in protocols if p.startswith("hermes-gateway-ticket.")]
        ticket, form = None, None
        if tickets:
            if "hermes-gateway-v1" not in protocols or len(tickets) != 1:
                return refuse()
            ticket, form = tickets[0].split(".", 1)[1], "subprotocol"
            entry["form"] = form
            with LOCK:
                refused = CONFIG["reject_subprotocol"]
            if refused:
                return refuse()
        else:
            ticket, form = q.get("ticket"), "query"
        entry["form"] = form
        with LOCK:
            exp = STATE["tickets"].pop(ticket, None) if ticket else None   # single use
        if exp is None or exp < time.time():
            return refuse()
        entry["accepted"] = True
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        if form == "subprotocol":
            self.send_header("Sec-WebSocket-Protocol", "hermes-gateway-v1")
        self.end_headers()
        self.close_connection = True
        conn = Conn(self)
        with LOCK:
            delay = CONFIG["ready_delay"]
        if delay:
            time.sleep(delay)
        conn.event("gateway.ready", payload={"skin": {}, "change_events": True})
        serve_socket(conn)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
