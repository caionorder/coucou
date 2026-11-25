#!/usr/bin/env python3
"""Fake local OpenAI-compatible server that REQUIRES an API key (like oMLX).

Usage: python3 fake_local_llm_auth.py <port-file>

Routes (both need "Authorization: Bearer <LOCAL_TEST_KEY>"):
  GET  /v1/models            -> one chat model
  POST /v1/chat/completions  -> short SSE stream
Without the header: 401 "API key required". With another key: 401 "Invalid API key".
With the key FORBIDDEN_TEST_KEY: 403.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOCAL_TEST_KEY = "sk-local-test-key"
FORBIDDEN_TEST_KEY = "sk-forbidden"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _authorized(self):
        auth = self.headers.get("Authorization")
        if auth == "Bearer " + LOCAL_TEST_KEY:
            return True
        if auth == "Bearer " + FORBIDDEN_TEST_KEY:
            body = json.dumps({"error": {"message": "Forbidden", "type": "permission_error"}}).encode()
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return False
        if auth is None:
            msg = {"detail": "API key required"}
        else:
            msg = {"error": {"message": "Invalid API key", "type": "authentication_error"}}
        body = json.dumps(msg).encode()
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return False

    def do_GET(self):
        if self.path != "/v1/models":
            self.send_response(404)
            self.end_headers()
            return
        if not self._authorized():
            return
        body = json.dumps({"data": [{"id": "omlx-model", "object": "model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return
        if not self._authorized():
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for piece in ("hel", "lo"):
            ev = json.dumps({"choices": [{"delta": {"content": piece}}]})
            self.wfile.write(f"data: {ev}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
