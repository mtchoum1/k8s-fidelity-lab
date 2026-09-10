#!/usr/bin/env python3
"""Minimal inference server for the fidelity lab demo workload."""

import http.server
import json
import sys

# INTENTIONAL: torch is not installed in Dockerfile.inference
import torch  # noqa: F401 — fails at runtime on kind (Tier 3)

PORT = 8080


class InferenceHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"prediction": "iris-setosa", "input": body.decode()}).encode())


if __name__ == "__main__":
    print(f"Starting inference server on :{PORT}", file=sys.stderr)
    http.server.HTTPServer(("0.0.0.0", PORT), InferenceHandler).serve_forever()
