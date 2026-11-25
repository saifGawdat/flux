#!/usr/bin/env python3
"""Small HTTP file server with Range/If-Range support, for testing Downpour.

    python3 scripts/range_server.py --root DIR [--port 0] [--no-range] [--throttle SECONDS]

Prints the bound port on the first line of stdout.
  /<file>                  serve a file (206 for Range requests unless --no-range)
  /<file>?cd=<name>        also send Content-Disposition: attachment; filename="<name>"
  /redirect/<file>         302 to /<file>
"""
import argparse
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    root = "."
    no_range = False
    throttle = 0.0

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve(head=True)

    def do_GET(self):
        self.serve(head=False)

    def serve(self, head):
        parts = urlsplit(self.path)
        path = unquote(parts.path)
        if path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("Location", "/" + quote(path[len("/redirect/"):]) + (("?" + parts.query) if parts.query else ""))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        local = os.path.join(self.root, os.path.basename(path))
        if not os.path.isfile(local):
            self.send_error(404)
            return
        size = os.path.getsize(local)
        st = os.stat(local)
        etag = '"%x-%x"' % (st.st_mtime_ns, size)
        start, end, status = 0, size - 1, 200

        rng = self.headers.get("Range")
        if_range = self.headers.get("If-Range")
        if rng and not self.no_range and (if_range is None or if_range == etag):
            m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
            if m:
                s, e = m.groups()
                if s == "":
                    start, end = max(0, size - int(e)), size - 1
                else:
                    start, end = int(s), (min(int(e), size - 1) if e else size - 1)
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206

        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("ETag", etag)
        if not self.no_range:
            self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        cd = parse_qs(parts.query).get("cd")
        if cd:
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % cd[0])
        self.end_headers()
        if head:
            return
        with open(local, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(65536, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)
                if self.throttle:
                    time.sleep(self.throttle)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--root", required=True)
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--no-range", action="store_true")
    p.add_argument("--throttle", type=float, default=0.0, help="sleep after each 64 KiB chunk")
    a = p.parse_args()
    Handler.root, Handler.no_range, Handler.throttle = a.root, a.no_range, a.throttle
    class QuietServer(ThreadingHTTPServer):
        def handle_error(self, request, client_address):
            pass  # clients cancelling connections mid-transfer is expected

    server = QuietServer(("127.0.0.1", a.port), Handler)
    server.daemon_threads = True
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
