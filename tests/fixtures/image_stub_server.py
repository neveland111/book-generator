#!/usr/bin/env python3
"""Offline stub for the image providers used by scripts/image_gen.sh.

Emulates, on one port:
  GET  /prompt/<...>            Pollinations.ai  → PNG bytes
  GET  /sdapi/v1/sd-models      AUTOMATIC1111 API probe
  POST /sdapi/v1/txt2img        AUTOMATIC1111   → {"images": [base64 png]}
  POST /images/generations      OpenAI-compatible → {"data": [{"b64_json": ...}]}

Behaviour switches (for failure-path tests):
  prompt/path containing FAILME  → returns an HTML error page / empty list
Logs every request as JSON to $IMAGE_STUB_LOG (default /tmp/image_stub_requests.log).

Usage: image_stub_server.py <port> <png file>
"""
import base64
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
PNG_PATH = sys.argv[2]
LOG = os.environ.get("IMAGE_STUB_LOG", "/tmp/image_stub_requests.log")


def png_bytes():
    with open(PNG_PATH, "rb") as fh:
        return fh.read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _record(self, extra):
        with open(LOG, "a") as fh:
            fh.write(json.dumps({"method": self.command, "path": self.path, "extra": extra}) + "\n")

    def _send(self, body, content_type="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._record(None)
        if self.path.startswith("/sdapi/v1/sd-models"):
            self._send(json.dumps([{"title": "stub-model.safetensors"}]).encode())
        elif self.path.startswith("/prompt/"):
            if "FAILME" in self.path:
                self._send(b"<html><body>404 not found</body></html>",
                           "text/html", status=404)
            else:
                self._send(png_bytes(), "image/png")
        else:
            self._send(b"not found", "text/plain", status=404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8", "replace")
        try:
            parsed = json.loads(raw or "{}")
        except Exception:
            parsed = {"_raw": raw[:200]}
        self._record(parsed)

        prompt = str(parsed.get("prompt", ""))
        failing = "FAILME" in prompt

        if self.path.startswith("/sdapi/v1/txt2img"):
            if failing:
                self._send(json.dumps({"images": []}).encode())
            else:
                self._send(json.dumps({
                    "images": [base64.b64encode(png_bytes()).decode()] }).encode())
        elif "/images/generations" in self.path:
            if failing:
                self._send(json.dumps({"error": {"message": "stub failure"}}).encode(), status=400)
            else:
                self._send(json.dumps({
                    "data": [{"b64_json": base64.b64encode(png_bytes()).decode()}]}).encode())
        else:
            self._send(b"not found", "text/plain", status=404)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
