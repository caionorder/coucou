#!/usr/bin/env python3
"""Minimal fake Hermes API server (localhost only) for tests/HermesChatTests.swift.

Usage: python3 fake_hermes.py <port-file>

Keys: test-key-default (unprefixed and /p/default), test-key-mark (/p/mark).
Routes (prefix is "", "/p/default" or "/p/mark"):
  GET  <prefix>/v1/models            -> {"data":[{"id":"mark"}]} / hermes-agent
  GET  /dashboard/v1/models          -> 200 text/html (SSO page stand-in)
  GET  /sso/v1/models                -> 302 to /login
  POST <prefix>/v1/chat/completions  -> SSE (keepalive, named event, reasoning, content, finish, [DONE])
        last user message "fail" -> finish_reason "error" + error.message "boom"
        last user message "busy" -> 429 OpenAI envelope
        "content_error"  -> some content, then finish_reason "error" + message
        "content_closed" -> some content, then the connection closes (no finish, no [DONE])
        "content_reset"  -> some content, then the connection is reset (RST)
        "longline"       -> one 5000 byte line without a newline
        "bigtext"        -> content frames totalling 3000 characters
        "slow"           -> some content, then keepalive lines for ~8 s
        "bigmodels"      -> (GET /big/v1/models) a 100 KB body
Test control (shared by both endpoints):
  POST /_test/reset                    counters and failures back to zero
  POST /_test/config {"models_drop": N, "chat_drop": N, "chat_stall": seconds, "chat_stall_count": N, "chat_status": 500,
                      "models_stall": seconds, "models_stall_count": N}
        models_drop: accept the next N models requests and close the connection without answering
        chat_drop: accept the next N chat requests, READ THE WHOLE BODY, then close without answering (the request
          reached the server, so the client must not send it again)
        models_stall: hold the response headers of the next models_stall_count models requests for that long
        chat_stall: hold the response headers of the next chat_stall_count chat requests for that long
        chat_status: answer every chat request with this status
  GET  /_test/state                    {"models_hits": n, "chat_hits": n}
Wrong/missing key -> 401 gateway_auth_failed. Unknown profile -> 404.
Response header X-Test-Model echoes the request "model"; X-Test-System is "1" if a system
message was sent (the client must not send one).
"""

import json
import socket
import socketserver
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

KEYS = {"": "test-key-default", "default": "test-key-default", "mark": "test-key-mark"}
MODEL_IDS = {"": "hermes-agent", "default": "hermes-agent", "mark": "mark"}

CONTENT = ["Hello ", "from ", "mark."]
EXPECTED_RESPONSE = "Hello from mark."


def envelope(message, etype, code):
    return json.dumps({"error": {"message": message, "type": etype, "code": code}}).encode()


LOCK = threading.Lock()
CONFIG = {}
COUNTS = {}


def reset():
    with LOCK:
        CONFIG.clear()
        CONFIG.update({"models_drop": 0, "chat_drop": 0, "chat_stall": 0, "chat_stall_count": 0, "chat_status": 0,
                       "models_stall": 0, "models_stall_count": 0})
        COUNTS.clear()
        COUNTS.update({"models_hits": 0, "chat_hits": 0})


reset()


def take(key):
    with LOCK:
        if CONFIG[key] > 0:
            CONFIG[key] -= 1
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, status, body, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def route(self):
        """Returns (profile, tail) or None when the path is unknown."""
        path = self.path.split("?")[0]
        if path.startswith("/p/"):
            rest = path[3:]
            profile, _, tail = rest.partition("/")
            if profile not in ("default", "mark"):
                return ("__unknown__", "/" + tail)
            return (profile, "/" + tail)
        return ("", path)

    def authed(self, profile):
        return self.headers.get("Authorization", "") == "Bearer " + KEYS[profile]

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/_test/state":
            with LOCK:
                return self.send_json(200, json.dumps(COUNTS).encode())
        if path == "/dashboard/v1/models":
            body = b"<html><body>Login</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/big/v1/models":
            body = b'{"data":[{"id":"mark"}],"pad":"' + b"x" * 100_000 + b'"}'
            return self.send_json(200, body)
        if path == "/sso/v1/models":
            self.send_response(302)
            self.send_header("Location", "/login")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        profile, tail = self.route()
        if profile == "__unknown__":
            return self.send_json(404, envelope("no such profile", "not_found", "profile_not_found"))
        if tail == "/v1/models":
            with LOCK:
                COUNTS["models_hits"] += 1
            if take("models_drop"):
                self.close_connection = True
                return
            if take("models_stall_count"):
                with LOCK:
                    hold = CONFIG["models_stall"]
                time.sleep(hold)
        if tail != "/v1/models":
            return self.send_json(404, envelope("not found", "not_found", "not_found"))
        if not self.authed(profile):
            return self.send_json(401, envelope("Invalid API key", "invalid_request_error", "gateway_auth_failed"))
        self.send_json(200, json.dumps({"object": "list", "data": [{"id": MODEL_IDS[profile]}]}).encode())

    def do_POST(self):
        if self.path.split("?")[0] in ("/_test/reset", "/_test/config"):
            n = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(n) if n else b""
            if self.path.endswith("reset"):
                reset()
            else:
                with LOCK:
                    CONFIG.update(json.loads(raw or b"{}"))
            return self.send_json(200, b"{}")
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw)
        except Exception:
            req = {}
        profile, tail = self.route()
        if profile == "__unknown__":
            return self.send_json(404, envelope("no such profile", "not_found", "profile_not_found"))
        if tail != "/v1/chat/completions":
            return self.send_json(404, envelope("not found", "not_found", "not_found"))
        with LOCK:
            COUNTS["chat_hits"] += 1
            status = CONFIG["chat_status"]
        if take("chat_drop"):
            self.close_connection = True
            return
        if take("chat_stall_count"):
            with LOCK:
                hold = CONFIG["chat_stall"]
            time.sleep(hold)
        if status:
            return self.send_json(status, envelope("injected", "server_error", "injected"))
        if not self.authed(profile):
            return self.send_json(401, envelope("Invalid API key", "invalid_request_error", "gateway_auth_failed"))

        msgs = req.get("messages", [])
        has_system = any(m.get("role") == "system" for m in msgs)
        last_user = ""
        for m in reversed(msgs):
            if m.get("role") == "user":
                c = m.get("content")
                last_user = c if isinstance(c, str) else json.dumps(c)
                break
        extra = {"X-Test-Model": str(req.get("model", "")), "X-Test-System": "1" if has_system else "0"}

        if last_user == "busy":
            return self.send_json(429, envelope("Too many requests", "rate_limit_error", "busy"), extra)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        self.close_connection = True

        class Gone(Exception):
            pass

        def emit(raw_text):
            try:
                self.wfile.write(raw_text.encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                raise Gone()
            time.sleep(0.005)

        def chunk(delta, finish=None, **more):
            c = {"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            c.update(more)
            return "data: " + json.dumps(c) + "\n\n"

        def reset_connection():
            self.wfile.flush()
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.close()

        try:
            emit(chunk({"role": "assistant"}))
            emit(": keepalive\n\n")
            emit("event: hermes.tool.progress\ndata: " + json.dumps({"tool": "terminal", "status": "running"}) + "\n\n")
            emit(chunk({"reasoning_content": "thinking about it"}))
            if last_user == "fail":
                emit(chunk({}, "error", error={"message": "boom"}))
            elif last_user == "content_error":
                emit(chunk({"content": "Partial "}))
                emit(chunk({"content": "answer."}))
                emit(chunk({}, "error", error={"message": "tool crashed"}))
            elif last_user == "content_closed":
                emit(chunk({"content": "Partial answer."}))
                return
            elif last_user == "content_reset":
                emit(chunk({"content": "Partial answer."}))
                time.sleep(0.2)
                reset_connection()
                return
            elif last_user == "longline":
                emit("data: " + "x" * 5000)
                time.sleep(0.5)
                return
            elif last_user == "bigtext":
                emit(chunk({"content": "Start. "}))
                for _ in range(30):
                    emit(chunk({"content": "y" * 100}))
                emit(chunk({}, "stop"))
            elif last_user == "slow":
                emit(chunk({"content": "Slow start."}))
                for _ in range(160):
                    emit(": keepalive\n\n")
                    time.sleep(0.05)
            else:
                for piece in CONTENT:
                    emit(chunk({"content": piece}))
                emit(chunk({}, "stop", usage={"total_tokens": 3}))
            emit("data: [DONE]\n\n")
        except Gone:
            pass


class FastBindHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


if __name__ == "__main__":
    port = find_free_port()
    server = FastBindHTTPServer(("127.0.0.1", port), Handler)
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as f:
            f.write(str(port))
            f.flush()
    server.serve_forever()
