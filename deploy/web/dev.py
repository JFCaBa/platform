#!/usr/bin/env python3
"""Local dev server for the website: serves site/ like nginx does and proxies the API.

    python3 deploy/web/dev.py [port]      # default 8000, then open http://localhost:8000/

The browser's API base is '' on localhost (site/js/api.js), so /departures/..., /service/... and
/stations.json come here and are fetched from https://api.whatplatform.uk. The User-Agent has
"preview", so the stats do not count it as a person.
"""
from __future__ import annotations

import re
import sys
import urllib.error
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SITE = Path(__file__).resolve().parents[2] / "site"
API = "https://api.whatplatform.uk"
UA = "Mozilla/5.0 (WhatPlatform dev; preview)"
PROXY = re.compile(r"^/(departures/[A-Z]{3}(/[0-9]{1,3})?|service/[A-Za-z0-9_-]{6,40}|stations\.json)$")
SHELL = re.compile(r"^/(station/[A-Za-z]{3}/?)?$")
PUBLIC = re.compile(r"^/(style\.css|js/[a-z]+\.js|app-store-badge\.svg|favicon\.png|apple-touch-icon\.png)$")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(SITE), **kw)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if PROXY.match(path):
            return self.proxy(path)
        if SHELL.match(path):
            self.path = "/index.html"
        elif re.match(r"^/privacy/?$", path):
            self.path = "/privacy.html"
        elif not PUBLIC.match(path):
            return self.send_error(404)
        return super().do_GET()

    def proxy(self, path: str):
        req = urllib.request.Request(API + path, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                status, body = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, body = e.code, e.read()
        except OSError:
            return self.send_error(502)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    print(f"http://localhost:{port}/")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
