"""Usage stats from nginx's syslog lines, aggregates only.

nginx sends one UDP line per What Platform request (deploy/nginx/whatplatform.uk.conf). Each
line's IP and User-Agent are combined, for an instant, with a random key that lives only in
memory and is replaced when a London day ends: `HMAC(key, ip + ua)` goes into that day's set so
a person is counted once a day. When the day ends the key and the set are dropped and only the
day's count remains. The IP, the User-Agent and the hashes never reach disk or a log.
"""
from __future__ import annotations

import dataclasses
import hmac
import re
import secrets
import threading
from collections import Counter
from datetime import datetime, timezone
from typing import NamedTuple
from zoneinfo import ZoneInfo

LONDON = ZoneInfo("Europe/London")
TAG = b"platform: "
END = "E"
FIELDS = 8  # msec|method|uri|status|cache|ip|ua...|E
APP_UA = "WhatPlatform/"
VERSION_RE = re.compile(r"^WhatPlatform/([0-9A-Za-z.+-]{1,16})(?:\s|$)")
DEPARTURES_RE = re.compile(r"^/departures/([A-Z]{3})(?:/[0-9]{1,3})?$")
SERVICE_RE = re.compile(r"^/service/[A-Za-z0-9_-]{6,40}$")
OTHER = "otro"


class Hit(NamedTuple):
    ts: float
    kind: str  # departures | service | follow
    crs: str | None
    ip: str
    ua: str


@dataclasses.dataclass
class Delta:
    day: str
    visitors: int  # size of that day's set so far (grows; not reset by drain)
    closed: bool  # the day is over: its key and set are gone
    requests: int = 0
    follows: int = 0
    hours: dict[int, int] = dataclasses.field(default_factory=dict)
    stations: dict[str, int] = dataclasses.field(default_factory=dict)
    versions: dict[str, int] = dataclasses.field(default_factory=dict)


def london_day(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).astimezone(LONDON).strftime("%Y-%m-%d")


def london_hour(ts: float) -> int:
    return datetime.fromtimestamp(ts, timezone.utc).astimezone(LONDON).hour


def parse_line(packet: bytes) -> Hit | None:
    """The request in one nginx syslog datagram, or None when it does not count (not a 2xx/3xx
    of GET /departures/..., GET /service/... or POST /follow) or is malformed or truncated."""
    i = packet.find(TAG)
    if i < 0:
        return None
    try:
        msg = packet[i + len(TAG):].decode("utf-8")
    except UnicodeDecodeError:
        return None
    parts = msg.split("|")
    if len(parts) < FIELDS or parts[-1] != END:
        return None
    ts_s, method, uri, status, _cache, ip = parts[:6]
    ua = "|".join(parts[6:-1])
    try:
        ts = float(ts_s)
    except ValueError:
        return None
    if not (len(status) == 3 and status[0] in "23" and status.isdigit()):
        return None
    if method == "GET":
        m = DEPARTURES_RE.match(uri)
        if m:
            return Hit(ts, "departures", m.group(1), ip, ua)
        if SERVICE_RE.match(uri):
            return Hit(ts, "service", None, ip, ua)
    elif method == "POST" and uri == "/follow":
        return Hit(ts, "follow", None, ip, ua)
    return None


def _version(ua: str) -> str:
    m = VERSION_RE.match(ua)
    return m.group(1) if m else OTHER


class _Day:
    def __init__(self) -> None:
        self.requests = 0
        self.follows = 0
        self.hours: Counter[int] = Counter()
        self.stations: Counter[str] = Counter()
        self.versions: Counter[str] = Counter()

    def empty(self) -> bool:
        return not (self.requests or self.follows)


class Tally:
    """In-memory counters of the current London day (and of days closed since the last drain)."""

    def __init__(self, key_factory=lambda: secrets.token_bytes(32)) -> None:
        self._key_factory = key_factory
        self._lock = threading.Lock()
        self._day: str | None = None
        self._key = b""
        self._seen: set[bytes] = set()
        self._counts: dict[str, _Day] = {}
        self._closed: dict[str, int] = {}  # day → its final visitor count, until drained

    def _roll(self, day: str) -> bool:
        """Make `day` current. False when `day` is before the current one (a late packet)."""
        if self._day is not None and day < self._day:
            return False
        if self._day is not None and day > self._day:
            self._closed[self._day] = len(self._seen)
            self._seen = set()
            self._key = b""
            self._day = None
        if self._day is None:
            self._day = day
            self._key = self._key_factory()
        return True

    def _today(self) -> _Day:
        return self._counts.setdefault(self._day, _Day())

    def add(self, hit: Hit) -> None:
        with self._lock:
            if not self._roll(london_day(hit.ts)):
                return
            c = self._today()
            c.requests += 1
            c.hours[london_hour(hit.ts)] += 1
            if hit.crs:
                c.stations[hit.crs] += 1
            c.versions[_version(hit.ua)] += 1
            if hit.ua.startswith(APP_UA):
                self._seen.add(hmac.new(self._key, f"{hit.ip}\n{hit.ua}".encode(), "sha256").digest()[:16])

    def add_follow(self, ts: float) -> None:
        with self._lock:
            if self._roll(london_day(ts)):
                self._today().follows += 1

    def visitors_today(self, now: float | None = None) -> int:
        """People counted so far today; 0 when `now` is already a later day than the set's."""
        with self._lock:
            if now is not None and self._day is not None and london_day(now) != self._day:
                return 0
            return len(self._seen)

    def drain(self, now: float) -> list[Delta]:
        """Counters since the last drain, one Delta per day, oldest first; resets them."""
        with self._lock:
            self._roll(london_day(now))
            out = []
            for day in sorted(set(self._counts) | set(self._closed) | {self._day}):
                c = self._counts.get(day) or _Day()
                closed = day in self._closed
                visitors = self._closed[day] if closed else len(self._seen)
                if not closed and c.empty() and not visitors:
                    continue
                out.append(Delta(day, visitors, closed, c.requests, c.follows,
                                 dict(c.hours), dict(c.stations), dict(c.versions)))
            self._counts = {}
            self._closed = {}
            return out
