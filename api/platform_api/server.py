"""Platform API: GET /departures/{CRS} → next departures (Darwin, reshaped), GET /health.

Privacy: logs only method, path and status (never client addresses).
Load: at most `max_inflight` concurrent Darwin calls (more → 503); nginx caches 30 s
per CRS in front of this.
"""
from __future__ import annotations

import http.client
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Collection, TextIO

from .board import to_board

DARWIN_URL = ("https://api1.raildata.org.uk/1010-live-departure-board-dep1_2"
              "/LDBWS/api/20220120/GetDepartureBoard")
STATIONS_URL = "https://jfcaba.github.io/platform/stations.json"
BUNDLED_STATIONS = Path(__file__).parent / "stations.json"
ATTRIBUTION = "Data: National Rail"
QUERY = "?numRows=20&timeWindow=120"
MAX_BODY = 1 << 20
CRS_PATH = re.compile(r"^/departures/(.+)$")
CRS_RE = re.compile(r"^[A-Z]{3}$")
USER_AGENT = "platform-api/1.0"


class Upstream(Exception):
    def __init__(self, status: int | str):
        super().__init__(status)
        self.status = status  # HTTP status from Darwin, or a short reason


def fetch_darwin(url: str, api_key: str, deadline_s: float) -> dict:
    """GET Darwin JSON within a total deadline (connect + headers + body), body ≤ 1 MB.

    A watchdog shuts the socket down when the deadline passes, so a slow trickle of
    headers or body cannot hold the request (and a Darwin slot) any longer.
    """
    u = urllib.parse.urlsplit(url)
    conn_cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(u.netloc, timeout=deadline_s)
    expired = threading.Event()

    def kill():
        expired.set()
        sock = conn.sock
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    watchdog = threading.Timer(deadline_s, kill)
    watchdog.daemon = True
    watchdog.start()
    try:
        path = u.path + ("?" + u.query if u.query else "")
        conn.request("GET", path, headers={"x-apikey": api_key, "Accept": "application/json",
                                           "User-Agent": USER_AGENT})
        resp = conn.getresponse()
        if resp.status != 200:
            raise Upstream(resp.status)
        chunks, size = [], 0
        while chunk := resp.read1(1 << 16):
            if expired.is_set():
                raise Upstream("timeout")
            size += len(chunk)
            if size > MAX_BODY:
                raise Upstream("too big")
            chunks.append(chunk)
        if expired.is_set():
            raise Upstream("timeout")
        data = json.loads(b"".join(chunks))
        if not isinstance(data, dict):
            raise Upstream("not an object")
        return data
    except (OSError, ValueError, http.client.HTTPException):
        raise Upstream("timeout" if expired.is_set() else "network") from None
    finally:
        watchdog.cancel()
        conn.close()


def load_stations(url: str, fallback: Path) -> set[str]:
    """Known CRS codes from stations.json (URL first, bundled copy if that fails)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read(8 << 20))
        known = {s["crs"] for s in data["stations"]}
        if len(known) >= 2400:
            return known
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {s["crs"] for s in json.loads(fallback.read_text())["stations"]}


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128  # default 5 resets bursts of connections


def make_server(host: str, port: int, *, darwin_url: str, api_key: str, stations: Collection[str],
                attribution: str, deadline_s: float = 8.0, max_inflight: int = 8,
                log: TextIO = sys.stderr) -> ThreadingHTTPServer:
    slots = threading.BoundedSemaphore(max_inflight)

    class Handler(BaseHTTPRequestHandler):
        server_version = "platform-api"
        timeout = 10  # idle client connections are dropped
        sys_version = ""

        def log_message(self, fmt, *args):  # base class would log the client address
            pass

        def log_request(self, code="-", size="-"):
            log.write(f"{self.command} {self.path} {code}\n")
            log.flush()

        def send_json(self, status: int, body: dict, cache: str = "no-store"):
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", cache)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/health":
                return self.send_json(200, {"ok": True})
            m = CRS_PATH.match(self.path)
            if not m:
                return self.send_json(404, {"error": "not found"})
            crs = m.group(1)
            if not CRS_RE.match(crs):
                return self.send_json(400, {"error": "bad crs"})
            if crs not in self.server.stations:
                return self.send_json(404, {"error": "unknown station"})
            if not slots.acquire(blocking=False):
                return self.send_json(503, {"error": "busy"})
            try:
                raw = fetch_darwin(f"{darwin_url}/{crs}{QUERY}", api_key, deadline_s)
                board = to_board(raw, crs, attribution, datetime.now(timezone.utc))
            except Upstream as e:
                log.write(f"upstream {crs} {e.status}\n")
                if e.status == 400:
                    return self.send_json(404, {"error": "unknown station"})
                return self.send_json(502, {"error": "upstream"})
            except (AttributeError, TypeError, ValueError, KeyError) as e:
                log.write(f"upstream {crs} bad shape {type(e).__name__}\n")
                return self.send_json(502, {"error": "upstream"})
            finally:
                slots.release()
            self.send_json(200, board, cache="max-age=30")

    httpd = _Server((host, port), Handler)
    httpd.stations = stations
    return httpd


def main(env: dict | None = None) -> int:
    env = os.environ if env is None else env
    key = env.get("DARWIN_API_KEY", "").strip()
    if not key:
        print("DARWIN_API_KEY missing", file=sys.stderr)
        return 1
    stations_url = env.get("STATIONS_URL", STATIONS_URL)
    # Port fixed inside the container; PORT in .env only changes the host side (compose).
    httpd = make_server("0.0.0.0", 8510, darwin_url=env.get("DARWIN_URL", DARWIN_URL),
                        api_key=key, stations=load_stations(stations_url, BUNDLED_STATIONS),
                        attribution=ATTRIBUTION)

    def refresh():
        while True:
            time.sleep(24 * 3600)
            httpd.stations = load_stations(stations_url, BUNDLED_STATIONS)

    threading.Thread(target=refresh, daemon=True).start()
    print(f"listening on :{httpd.server_address[1]} ({len(httpd.stations)} stations)", file=sys.stderr)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
