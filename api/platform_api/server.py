"""Platform API: GET /departures/{CRS} → next departures (Darwin, reshaped),
GET /departures/{CRS}/{OFFSET} → the trains from OFFSET (1..119) minutes ahead, GET /health,
POST/DELETE /follow → push alerts (APNs) for one followed train per device.

Privacy: requests are not logged. Logged: Darwin failures (station code + reason; a board
read in slices after a 500 logs its station and the minutes dropped),
`apns <status> <reason>` / `apns network <Class>`, `follow poller: <Class>`, `unhandled <Class>`,
and one startup line `follow: on|off`. Never device tokens, trains or client addresses.
Follows live in memory only.
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

from .apns import Apns
from .board import BASE_ROWS, HHMM, darwin_window, to_board, to_stops, train_position
from .follow import MAX_DURATION, FollowStore, Poller, find_followed
from .slices import NoSlice, board_in_slices

DARWIN_URL = ("https://api1.raildata.org.uk/1010-live-departure-board-dep1_2"
              "/LDBWS/api/20220120/GetDepartureBoard")
SERVICE_URL = ("https://api1.raildata.org.uk/1010-service-details1_2"
               "/LDBWS/api/20220120/GetServiceDetails")
STATIONS_URL = "https://jfcaba.github.io/platform/stations.json"
BUNDLED_STATIONS = Path(__file__).parent / "stations.json"
ATTRIBUTION = "Data: National Rail"
QUERY = f"?numRows={BASE_ROWS}&timeWindow=120"  # 20 rows cover only ~15 min at the busiest stations
# Later pages: Darwin's maximum rows, so even the busiest station's page covers well over 15 min.
LATER_ROWS = 150
LATER_PATH = re.compile(r"^/departures/([^/]*)/([^/]*)$")
OFFSET_RE = re.compile(r"^(?:[1-9]|[1-9][0-9]|1[01][0-9])$")  # 1..119, Darwin's timeOffset range
MAX_BODY = 1 << 20
CRS_PATH = re.compile(r"^/departures/(.+)$")
CRS_RE = re.compile(r"^[A-Z]{3}$")
SERVICE_PATH = re.compile(r"^/service/(.*)$")
SERVICE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,40}$")  # e.g. 10741504KNGX____
USER_AGENT = "platform-api/1.0"
TOKEN_RE = re.compile(r"[0-9a-fA-F]{64,200}")
# Live Activity push tokens are longer than device tokens (256 hex chars seen on iOS 26).
ACTIVITY_TOKEN_RE = re.compile(r"[0-9a-fA-F]{64,512}")
ENVS = ("production", "sandbox")
MAX_FOLLOW_BODY = 4096
MAX_DESTINATION = 100
MAX_STARTED_MS = 10 ** 15  # far beyond any real epoch ms; keeps the float division safe


class Busy(Exception):
    """No poll slot became free in time."""


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


class ServiceCache:
    """Darwin Service Details answers, kept `ttl` seconds per service id: shared by /service/{id}
    and the follow poller's position lookups. Errors are not kept."""

    def __init__(self, ttl: float = 30.0, clock=time.time, max_entries: int = 2000) -> None:
        self._ttl = ttl
        self._clock = clock
        self._max = max_entries
        self._lock = threading.Lock()
        self._items: dict[str, tuple[float, dict]] = {}

    def peek(self, sid: str) -> dict | None:
        now = self._clock()
        with self._lock:
            hit = self._items.get(sid)
            return hit[1] if hit is not None and 0 <= now - hit[0] < self._ttl else None

    def get(self, sid: str, load) -> dict:
        now = self._clock()
        with self._lock:
            hit = self._items.get(sid)
            if hit is not None and 0 <= now - hit[0] < self._ttl:
                return hit[1]
        value = load()
        with self._lock:
            if len(self._items) >= self._max:
                self._items = {k: v for k, v in self._items.items() if 0 <= now - v[0] < self._ttl}
                if len(self._items) >= self._max:
                    self._items.clear()
            self._items[sid] = (now, value)
        return value


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128  # default 5 resets bursts of connections
    log: TextIO = sys.stderr

    def handle_error(self, request, client_address):
        """The base class prints the client address and a traceback; log the class name only,
        and nothing for a client that went away."""
        e = sys.exc_info()[1]
        if isinstance(e, OSError):
            return
        try:
            self.log.write(f"unhandled {type(e).__name__}\n")
        except Exception:
            pass


def _follow_request(body: object, stations: Collection[str]) -> tuple[str, str, dict, int, str | None] | None:
    """(token lowercased, env, train, startedAt ms, Live Activity token lowercased or None) from a
    POST /follow body, or None if invalid."""
    if not isinstance(body, dict):
        return None
    token, env = body.get("token"), body.get("env")
    crs, std, dest = body.get("crs"), body.get("std"), body.get("destination")
    sid, started = body.get("serviceId"), body.get("startedAt")
    activity = body.get("activityToken")
    if not (isinstance(token, str) and TOKEN_RE.fullmatch(token) and env in ENVS
            and isinstance(crs, str) and CRS_RE.fullmatch(crs) and crs in stations
            and isinstance(std, str) and HHMM.fullmatch(std)
            and isinstance(dest, str) and 0 < len(dest) <= MAX_DESTINATION
            and (sid is None or (isinstance(sid, str) and SERVICE_ID_RE.fullmatch(sid)))
            and isinstance(started, int) and not isinstance(started, bool)
            and 0 <= started < MAX_STARTED_MS
            and (activity is None or (isinstance(activity, str) and ACTIVITY_TOKEN_RE.fullmatch(activity)))):
        return None
    train = {"crs": crs, "std": std, "destination": dest}
    if sid is not None:
        train["serviceId"] = sid
    return token.lower(), env, train, started, activity.lower() if activity else None


def make_server(host: str, port: int, *, darwin_url: str, api_key: str, stations: Collection[str],
                attribution: str, service_url: str | None = None, service_key: str | None = None, deadline_s: float = 8.0, max_inflight: int = 8,
                log: TextIO = sys.stderr, follows: FollowStore | None = None, push=None,
                follow_wait_s: float = 5.0, poll_wait_s: float = 10.0, slice_budget_s: float = 10.0,
                clock=time.time) -> ThreadingHTTPServer:
    slots = threading.BoundedSemaphore(max_inflight)
    # Stop lookups have their own, smaller pool: they must never leave the boards without a slot.
    service_slots = threading.BoundedSemaphore(max(1, max_inflight // 2))
    # Follow POSTs and the poller share their own pool: following never takes a board's slot.
    poll_slots = threading.BoundedSemaphore(2)
    services = ServiceCache(clock=clock)
    # Slice calls after a 500 (slices.py), across all boards: a station with a broken train must
    # not multiply the load on a Darwin that is already failing.
    slice_slots = threading.BoundedSemaphore(4)

    def service_details(sid: str) -> dict:
        return services.get(sid, lambda: fetch_darwin(f"{service_url}/{sid}", service_key, deadline_s))

    def fetch_position(sid: str) -> dict:
        """Where a followed train is, for the poller: from the shared cache, else one Service
        Details call in the poll pool (Busy when no slot within `poll_wait_s`)."""
        if not SERVICE_ID_RE.match(sid):
            raise ValueError("bad service id")
        cached = services.peek(sid)
        if cached is not None:
            return train_position(cached)
        # A short wait: a slow lookup must not hold up the alerts of the rest of the tick.
        if not poll_slots.acquire(timeout=min(1.0, poll_wait_s)):
            raise Busy()
        try:
            return train_position(service_details(sid))
        finally:
            poll_slots.release()

    def board_raw(crs: str, query: str, offset: int, rows: int) -> tuple[dict, int]:
        """Darwin's board and how many minutes of its window are missing. On a 500 (one train
        with broken data fails the whole board, see slices.py) the same window again in slices,
        without the ones that keep failing, within `slice_budget_s` of the first call."""
        started = time.monotonic()
        try:
            return fetch_darwin(f"{darwin_url}/{crs}{query}", api_key, deadline_s), 0
        except Upstream as e:
            if e.status != 500:
                raise
            first = e

        def get(o: int, w: int, left: float) -> dict:
            if not slice_slots.acquire(timeout=left):
                raise Upstream("busy")
            try:
                return fetch_darwin(f"{darwin_url}/{crs}?numRows={rows}&timeWindow={w}&timeOffset={o}",
                                    api_key, min(deadline_s, left))
            finally:
                slice_slots.release()

        budget = slice_budget_s - (time.monotonic() - started)
        try:
            raw, dropped = board_in_slices(get, offset, darwin_window(offset), rows, budget,
                                           lambda e: isinstance(e, Upstream) and e.status == 500)
        except NoSlice:
            raise first from None
        log.write(f"upstream {crs} 500, sliced: {dropped} min dropped\n")
        return raw, dropped

    def fetch_board(crs: str, wait: float | None = None) -> dict:
        """One board reading for /follow and the poller. Waits for a poll slot up to `wait`
        seconds (the poller's `poll_wait_s` when not given), else Busy: the poller then skips
        that station for this tick. Raises Upstream or a shape error; never logs."""
        if not poll_slots.acquire(timeout=poll_wait_s if wait is None else wait):
            raise Busy()
        try:
            raw, _ = board_raw(crs, QUERY, 0, BASE_ROWS)
            return to_board(raw, crs, attribution, datetime.now(timezone.utc))
        finally:
            poll_slots.release()

    class Handler(BaseHTTPRequestHandler):
        server_version = "platform-api"
        timeout = 10  # idle client connections are dropped
        sys_version = ""

        def log_message(self, fmt, *args):  # base class would log the client address
            pass

        def log_request(self, code="-", size="-"):  # requests are not logged (privacy policy)
            pass

        def send_json(self, status: int, body: dict, cache: str = "no-store"):
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", cache)
            self.end_headers()
            self.wfile.write(data)

        def service(self, sid: str):
            if not SERVICE_ID_RE.match(sid):
                return self.send_json(400, {"error": "bad service id"})
            if not (service_url and service_key):
                return self.send_json(503, {"error": "unavailable"})
            if not service_slots.acquire(blocking=False):
                return self.send_json(502, {"error": "busy"})
            try:
                raw = service_details(sid)
                body = to_stops(raw, attribution, datetime.now(timezone.utc))
            except Upstream as e:
                log.write(f"upstream service {e.status}\n")
                if e.status == 429:
                    return self.send_json(429, {"error": "rate limited"})
                if e.status in (400, 404):
                    return self.send_json(404, {"error": "unknown service"})
                return self.send_json(502, {"error": "upstream"})
            except (AttributeError, TypeError, ValueError, KeyError) as e:
                log.write(f"upstream service bad shape {type(e).__name__}\n")
                return self.send_json(502, {"error": "upstream"})
            finally:
                service_slots.release()
            self.send_json(200, body, cache="max-age=30")

        def do_GET(self):
            if self.path == "/health":
                return self.send_json(200, {"ok": True})
            sm = SERVICE_PATH.match(self.path)
            if sm:
                return self.service(sm.group(1))
            offset, rows, query, cache = 0, BASE_ROWS, QUERY, "max-age=30"
            lm = LATER_PATH.match(self.path)
            if lm:
                crs = lm.group(1)
                if CRS_RE.match(crs) and not OFFSET_RE.match(lm.group(2)):
                    return self.send_json(400, {"error": "bad offset"})
                if CRS_RE.match(crs):
                    offset, rows = int(lm.group(2)), LATER_ROWS
                    query = f"?numRows={rows}&timeWindow=120&timeOffset={offset}"
                    cache = "max-age=60"  # snapshots of later trains; nginx keeps them 60 s
            else:
                m = CRS_PATH.match(self.path)
                if not m:
                    return self.send_json(404, {"error": "not found"})
                crs = m.group(1)
            if not CRS_RE.match(crs):
                return self.send_json(400, {"error": "bad crs"})
            if crs not in self.server.stations:
                return self.send_json(404, {"error": "unknown station"})
            if not slots.acquire(blocking=False):
                # 502, not 503: nginx caches it 5 s or serves the stale board; the app only
                # backs off for minutes on a real Darwin 429.
                return self.send_json(502, {"error": "busy"})
            try:
                raw, dropped = board_raw(crs, query, offset, rows)
                board = to_board(raw, crs, attribution, datetime.now(timezone.utc), offset=offset, rows=rows)
                if dropped:
                    board["complete"] = False  # minutes missing: the window is not all listed
            except Upstream as e:
                log.write(f"upstream {crs} {e.status}\n")
                if e.status == 429:
                    return self.send_json(429, {"error": "rate limited"})
                if e.status == 400:
                    return self.send_json(404, {"error": "unknown station"})
                return self.send_json(502, {"error": "upstream"})
            except (AttributeError, TypeError, ValueError, KeyError) as e:
                log.write(f"upstream {crs} bad shape {type(e).__name__}\n")
                return self.send_json(502, {"error": "upstream"})
            finally:
                slots.release()
            self.send_json(200, board, cache=cache)

        def read_json(self) -> tuple[bool, object]:
            """(ok, value) for a JSON body of exactly Content-Length bytes, at most 4 KB. On any
            rejection the connection is closed after the reply, so unread bytes are never parsed
            as another request."""
            ok, value = False, None
            try:
                n = int(self.headers.get("Content-Length", ""))
                if 0 <= n <= MAX_FOLLOW_BODY:  # a bigger body is not read
                    data = self.rfile.read(n)
                    if len(data) == n:
                        ok, value = True, json.loads(data)
            except (ValueError, RecursionError, OSError):
                ok, value = False, None
            if not ok:
                self.close_connection = True
            return ok, value

        def follow_unavailable(self) -> bool:
            if follows is None or push is None:
                self.send_json(503, {"error": "unavailable"})
                return True
            return False

        def do_POST(self):
            if self.path != "/follow":
                return self.send_json(404, {"error": "not found"})
            if self.follow_unavailable():
                return
            ok, body = self.read_json()
            req = _follow_request(body, self.server.stations) if ok else None
            if req is None:
                return self.send_json(400, {"error": "bad request"})
            token, env, train, started_ms, activity = req
            now = clock()
            if now - started_ms / 1000 >= MAX_DURATION:
                return self.send_json(410, {"error": "gone"})
            if follows.is_same(token, train, env):  # app re-sync: keep baseline and original start
                if activity:
                    follows.set_activity(token, train, activity)
                return self.send_json(200, {"ok": True})
            epoch = follows.epoch(token)  # a DELETE (or another POST) while we read Darwin wins
            try:
                board = fetch_board(train["crs"], wait=follow_wait_s)
            except Busy:
                return self.send_json(503, {"error": "busy"})
            except Upstream as e:
                if e.status == 429:
                    return self.send_json(429, {"error": "rate limited"})
                return self.send_json(502, {"error": "upstream"})
            except (AttributeError, TypeError, ValueError, KeyError):
                return self.send_json(502, {"error": "upstream"})
            found = find_followed(board, train)
            if found is None:
                return self.send_json(410, {"error": "gone"})
            started = min(max(started_ms / 1000, now - MAX_DURATION), now)
            result = follows.upsert(token, env, train, found, started, expect_epoch=epoch, activity=activity)
            if result == "stale":
                return self.send_json(409, {"error": "conflict"})
            if result != "ok":
                return self.send_json(503, {"error": "busy"})
            self.send_json(200, {"ok": True})

        def do_DELETE(self):
            if self.path != "/follow":
                return self.send_json(404, {"error": "not found"})
            if self.follow_unavailable():
                return
            ok, body = self.read_json()
            token = body.get("token") if ok and isinstance(body, dict) else None
            if not (isinstance(token, str) and TOKEN_RE.fullmatch(token)):
                return self.send_json(400, {"error": "bad request"})
            follows.remove(token.lower())
            self.send_response(204)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

    httpd = _Server((host, port), Handler)
    httpd.log = log
    httpd.stations = stations
    httpd.slots = slots
    httpd.poll_slots = poll_slots
    httpd.fetch_board = fetch_board
    httpd.fetch_position = fetch_position if service_url and service_key else None
    return httpd


def main(env: dict | None = None) -> int:
    env = os.environ if env is None else env
    key = env.get("DARWIN_API_KEY", "").strip()
    if not key:
        print("DARWIN_API_KEY missing", file=sys.stderr)
        return 1
    stations_url = env.get("STATIONS_URL", STATIONS_URL)
    push = Apns.from_env(env)  # None without APNs secrets: /follow answers 503
    follows = FollowStore() if push is not None else None
    print("follow: on" if push is not None else "follow: off (APNS_* missing or invalid)",
          file=sys.stderr)
    # Port fixed inside the container; PORT in .env only changes the host side (compose).
    httpd = make_server("0.0.0.0", 8510, darwin_url=env.get("DARWIN_URL", DARWIN_URL),
                        api_key=key, stations=load_stations(stations_url, BUNDLED_STATIONS),
                        service_url=env.get("SERVICE_URL", SERVICE_URL),
                        service_key=env.get("DARWIN_SERVICE_KEY", "").strip() or None,
                        attribution=ATTRIBUTION, follows=follows, push=push)
    if push is not None:
        stop = threading.Event()
        poller = Poller(follows, httpd.fetch_board, push, fetch_position=httpd.fetch_position)
        threading.Thread(target=poller.run, args=(stop,), daemon=True).start()

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
