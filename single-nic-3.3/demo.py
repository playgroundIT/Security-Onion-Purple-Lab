#!/usr/bin/env python3
"""Intentionally vulnerable command-injection exercise, for the isolated VM only."""
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == '/':
            status, body = 200, b'SO LAB Ubuntu victim: HTTP ready\n'
        elif url.path == '/run':
            cmd = parse_qs(url.query).get('cmd', [''])[0]
            try:
                # Deliberate vulnerability. A real application must never do this.
                result = subprocess.run(cmd, shell=True, capture_output=True, timeout=3)
                status, body = 200, (result.stdout + result.stderr)[:65536]
            except subprocess.TimeoutExpired:
                status, body = 408, b'Lab command timed out\n'
        else:
            status, body = 404, b'Not found\n'
        self.send_response(status)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == '__main__':
    ThreadingHTTPServer(('10.50.0.30', 8080), Handler).serve_forever()
