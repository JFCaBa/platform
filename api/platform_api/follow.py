"""Change rules for a followed train; a Python port of the app's follow_logic.dart `changes()`."""
from __future__ import annotations

import dataclasses
import threading
from dataclasses import dataclass

from .board import HHMM


def is_cancelled(d: dict) -> bool:
    return bool(d.get("cancelled")) or d.get("etd") == "Cancelled"


def matches(train: dict, d: dict) -> bool:
    """Same train on its board, whatever its platform or expected time: by id when both sides
    have one, else by scheduled time and destination."""
    tid, other = train.get("serviceId"), d.get("serviceId")
    if tid and other:
        return tid == other
    return d.get("std") == train.get("std") and d.get("destination") == train.get("destination")


def find_followed(board: dict, train: dict) -> dict | None:
    if board.get("crs") != train.get("crs"):
        return None
    for d in board.get("services", []):
        if matches(train, d):
            return d
    return None


def changes(before: dict, after: dict) -> list[str]:
    """Alert texts for what changed between two readings: platform first, then time.
    A newly cancelled train gives only the cancellation."""
    if is_cancelled(after):
        if is_cancelled(before):
            return []
        reason = after.get("cancelReason")
        return [f"Cancelled: {reason}" if reason else "Cancelled"]
    out: list[str] = []
    p0, p1 = before.get("platform"), after.get("platform")
    if p1 is not None and p1 != p0:
        out.append(f"Platform {p1}" if p0 is None else f"Platform changed: {p0} → {p1}")
    e0, e1 = before.get("etd"), after.get("etd")
    if e1 is not None and e1 != e0:
        if HHMM.match(e1):
            out.append(f"Now expected {e1}")
        elif e1 == "On time" and e0 is not None:
            out.append("Now on time")
        elif e1 == "Delayed":
            out.append("Delayed")
    return out


_UPDATABLE = {"last", "cancelled_at", "missing"}
_SAME_KEYS = ("crs", "std", "destination", "serviceId")


def _same_train(a: dict, b: dict) -> bool:
    return all(a.get(k) == b.get(k) for k in _SAME_KEYS)


def _copy(f: "Follow") -> "Follow":
    return dataclasses.replace(f, train=dict(f.train), last=dict(f.last) if f.last is not None else None)


@dataclass
class Follow:
    token: str
    env: str
    train: dict
    started: float
    last: dict | None
    cancelled_at: float | None
    missing: int
    gen: int


class FollowStore:
    """Follows kept in memory only, keyed by device token. Thread-safe. Every new or replaced
    follow gets a fresh generation so the poller can tell when it was changed under it.
    A same-train upsert refreshes `env` without bumping `gen`."""

    def __init__(self, max_follows: int = 500, max_stations: int = 50) -> None:
        self._max_follows = max_follows
        self._max_stations = max_stations
        self._lock = threading.Lock()
        self._follows: dict[str, Follow] = {}
        self._gen = 0

    def upsert(self, token: str, env: str, train: dict, baseline: dict, started: float) -> str:
        crs = train.get("crs")
        if not isinstance(crs, str) or not crs:
            raise ValueError("train needs a non-empty crs")
        with self._lock:
            cur = self._follows.get(token)
            if cur is not None and _same_train(cur.train, train):
                cur.env = env
                return "ok"
            if cur is None and len(self._follows) >= self._max_follows:
                return "busy"
            stations = {f.train.get("crs") for t, f in self._follows.items() if t != token}
            if train.get("crs") not in stations and len(stations) >= self._max_stations:
                return "busy"
            self._gen += 1
            self._follows[token] = Follow(token, env, dict(train), started, dict(baseline), None, 0, self._gen)
            return "ok"

    def is_same(self, token: str, train: dict) -> bool:
        with self._lock:
            cur = self._follows.get(token)
            return cur is not None and _same_train(cur.train, train)

    def update(self, token: str, gen: int, **fields) -> bool:
        bad = set(fields) - _UPDATABLE
        if bad:
            raise TypeError(f"cannot update fields: {sorted(bad)}")
        with self._lock:
            cur = self._follows.get(token)
            if cur is None or cur.gen != gen:
                return False
            for k, v in fields.items():
                setattr(cur, k, dict(v) if k == "last" and v is not None else v)
            return True

    def remove(self, token: str, gen: int | None = None) -> None:
        with self._lock:
            cur = self._follows.get(token)
            if cur is not None and (gen is None or cur.gen == gen):
                del self._follows[token]

    def stations(self) -> set[str]:
        with self._lock:
            return {f.train.get("crs") for f in self._follows.values()}

    def for_station(self, crs: str) -> list[Follow]:
        with self._lock:
            return [_copy(f) for f in self._follows.values() if f.train.get("crs") == crs]

    def __len__(self) -> int:
        with self._lock:
            return len(self._follows)
