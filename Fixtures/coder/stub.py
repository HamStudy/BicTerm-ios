#!/usr/bin/env python3
"""BicTerm fixture: Coder REST API stub (TEST-ONLY, loopback 127.0.0.1:18080).

Endpoints:
  GET  /api/v2/workspaces?q=owner:me[&limit=&offset=]   (auth required)
  POST /api/v2/users/me/keys/tokens                      (token issuance)
  GET  /api/v2/workspaceagents/{id}/connection           (DERPMap stub)
  GET  /_control/mode   POST /_control/mode {"mode":...} (runtime modes)

Auth: header `Coder-Session-Token: fixture-token`. `expired-token`, missing,
or wrong token -> 401 {"message":"invalid api key"}.
Modes: ok (default), unauthorized (401 everything authed),
       ratelimited (429 + Retry-After: 1 on the NEXT request, then ok).
Requests are appended to Fixtures/run/coder_stub.log.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "127.0.0.1"
PORT = 18080
VALID_TOKEN = "fixture-token"

LOG_PATH = os.environ.get(
    "BICTERM_STUB_LOG",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "run", "coder_stub.log"),
)

STATE = {"mode": "ok", "ratelimit_pending": False}
STATE_LOCK = threading.Lock()

WORKSPACES = [
    {
        "id": "11111111-1111-4111-8111-111111111111",
        "name": "dev-main",
        "owner_name": "fixture-user",
        "latest_build": {"status": "running"},
    },
    {
        "id": "22222222-2222-4222-8222-222222222222",
        "name": "dev-api",
        "owner_name": "fixture-user",
        "latest_build": {"status": "running"},
    },
    {
        "id": "33333333-3333-4333-8333-333333333333",
        "name": "batch-gpu",
        "owner_name": "fixture-user",
        "latest_build": {"status": "stopped"},
    },
]


def log_request(method, path, code):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write("%s %s %s -> %d\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), method, path, code))
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, obj, extra_headers=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
        log_request(self.command, self.path, code)

    def _unauthorized(self):
        self._send(401, {"message": "invalid api key"})

    def _mode_gate(self):
        """Returns True if the request was already answered by a mode."""
        with STATE_LOCK:
            if STATE["mode"] == "unauthorized":
                self._unauthorized()
                return True
            if STATE["mode"] == "ratelimited" or STATE["ratelimit_pending"]:
                STATE["ratelimit_pending"] = False
                if STATE["mode"] == "ratelimited":
                    STATE["mode"] = "ok"
                self._send(429, {"message": "rate limited"}, {"Retry-After": "1"})
                return True
        return False

    def _authorized(self):
        token = self.headers.get("Coder-Session-Token")
        return token == VALID_TOKEN

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/_control/mode":
            with STATE_LOCK:
                self._send(200, {"mode": STATE["mode"]})
            return

        if path == "/api/v2/workspaces":
            if self._mode_gate():
                return
            if not self._authorized():
                self._unauthorized()
                return
            qs = parse_qs(parsed.query)
            try:
                limit = int(qs.get("limit", ["100"])[0])
                offset = int(qs.get("offset", ["0"])[0])
            except ValueError:
                self._send(400, {"message": "invalid limit/offset"})
                return
            limit = max(0, limit)
            offset = max(0, offset)
            page = WORKSPACES[offset:offset + limit]
            self._send(200, {"workspaces": page, "count": len(WORKSPACES)})
            return

        if path.startswith("/api/v2/workspaceagents/") and path.endswith("/connection"):
            if self._mode_gate():
                return
            if not self._authorized():
                self._unauthorized()
                return
            self._send(200, {
                "derp_map": {"Regions": []},
                "derp_force_websockets": False,
                "disable_direct_connections": False,
            })
            return

        self._send(404, {"message": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/_control/mode":
            length = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                self._send(400, {"message": "invalid json"})
                return
            mode = body.get("mode")
            if mode not in ("ok", "unauthorized", "ratelimited"):
                self._send(400, {"message": "mode must be ok|unauthorized|ratelimited"})
                return
            with STATE_LOCK:
                STATE["mode"] = mode
                STATE["ratelimit_pending"] = (mode == "ratelimited")
            self._send(200, {"mode": mode})
            return

        if path == "/api/v2/users/me/keys/tokens":
            self._send(201, {
                "key": VALID_TOKEN,
                "generated_api_key_id": "fixture-api-key-id-0001",
            })
            return

        self._send(404, {"message": "not found"})


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("coder-stub listening on %s:%d" % (HOST, PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
