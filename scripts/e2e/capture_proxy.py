#!/usr/bin/env python3
"""Test-only request-body capture between Claude Code and the E2E proxy.

ModelProxy never logs bodies (project policy), so when a diagnosis needs to see exactly what Claude Code
sent, put this in front of it:

    python3 capture_proxy.py <out-dir> [listen-port=19091] [upstream-port=19090]
    MP_E2E_BASE_URL=http://127.0.0.1:19091 ./cc.sh -p ...

Each POST /v1/messages body is written to <out-dir>/req-NNN.json. Bodies contain the full prompt and
system prompt: keep them in $E2E_ROOT/capture (down.sh deletes it) and never commit them.
"""
import http.client
import http.server
import itertools
import os
import sys
import threading

out_dir = sys.argv[1]
listen_port = int(sys.argv[2]) if len(sys.argv) > 2 else 19091
upstream_port = int(sys.argv[3]) if len(sys.argv) > 3 else 19090
os.makedirs(out_dir, exist_ok=True)
counter = itertools.count(1)
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.command == "POST" and self.path.startswith("/v1/messages") and "count_tokens" not in self.path:
            with lock:
                n = next(counter)
            with open(os.path.join(out_dir, f"req-{n:03d}.json"), "wb") as f:
                f.write(body)
        conn = http.client.HTTPConnection("127.0.0.1", upstream_port, timeout=600)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection")}
        conn.request(self.command, self.path, body=body or None, headers=headers)
        resp = conn.getresponse()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        # Relay as it arrives so SSE streams keep their timing.
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()
        self.close_connection = True

    do_POST = _forward
    do_GET = _forward
    do_HEAD = _forward

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", listen_port), Handler).serve_forever()
