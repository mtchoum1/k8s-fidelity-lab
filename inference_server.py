#!/usr/bin/env python3
"""Minimal inference server for PR #104 GPU batch inference demo."""

import http.server
import json
import sys

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
        self.wfile.write(
            json.dumps({"prediction": "iris-setosa", "batch": True, "input": body.decode()}).encode()
        )


if __name__ == "__main__":
    print(f"Starting PR #104 inference server on :{PORT}", file=sys.stderr)
    http.server.HTTPServer(("0.0.0.0", PORT), InferenceHandler).serve_forever()
