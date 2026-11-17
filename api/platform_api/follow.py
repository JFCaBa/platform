"""Change rules for a followed train; a Python port of the app's follow_logic.dart `changes()`."""
from __future__ import annotations

import dataclasses
import sys
import threading
import time
from dataclasses import dataclass
from typing import Callable, TextIO

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


MAX_DURATION = 3 * 3600
CANCELLED_LINGER = 120
RATE_LIMIT_PAUSE = 300

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
    A same-train upsert keeps the follow's state; it gets a new `gen` only when `env` changes,
    so a send already in flight to the old env's host can't update or remove it.

    Each token also has an epoch, bumped by every upsert and by user removals (DELETE, no gen),
    so a POST that read the board meanwhile can tell a DELETE (or another POST) happened and back
    off. Poller removals don't bump it: a POST racing a poller cleanup is not a conflict."""

    MAX_EPOCHS = 10_000

    def __init__(self, max_follows: int = 500, max_stations: int = 50) -> None:
        self._max_follows = max_follows
        self._max_stations = max_stations
        self._lock = threading.Lock()
        self._follows: dict[str, Follow] = {}
        self._gen = 0
        self._epochs: dict[str, int] = {}  # insertion-ordered: oldest bump first
        self._epoch_ctr = 0
        self._floor = 0  # value of the last pruned entry; tokens not in the map read this

    def epoch(self, token: str) -> int:
        with self._lock:
            return self._epochs.get(token, self._floor)

    def _bump(self, token: str) -> None:
        """Caller holds the lock. Values come from one store-wide counter, so they never repeat.
        Pruning drops the oldest entry and raises `_floor` to its value; every token not in the
        map then reads the floor. A pruned token's epoch never goes back to a value read before
        its last bump (the floor is at least that bump), so a pruned DELETE still wins. A
        rising floor can only make an in-flight POST of an unlisted token stale (safe side)."""
        self._epoch_ctr += 1
        self._epochs.pop(token, None)
        self._epochs[token] = self._epoch_ctr
        while len(self._epochs) > self.MAX_EPOCHS:
            oldest = next(iter(self._epochs))
            self._floor = self._epochs.pop(oldest)

    def upsert(self, token: str, env: str, train: dict, baseline: dict, started: float,
               expect_epoch: int | None = None) -> str:
        """"ok", "busy" (caps), or "stale" when `expect_epoch` is given and the token's epoch
        has changed since (nothing is written then)."""
        crs = train.get("crs")
        if not isinstance(crs, str) or not crs:
            raise ValueError("train needs a non-empty crs")
        with self._lock:
            if expect_epoch is not None and self._epochs.get(token, self._floor) != expect_epoch:
                return "stale"
            cur = self._follows.get(token)
            if cur is not None and _same_train(cur.train, train):
                if cur.env != env:
                    self._gen += 1
                    cur.gen = self._gen
                    cur.env = env
                self._bump(token)
                return "ok"
            if cur is None and len(self._follows) >= self._max_follows:
                return "busy"
            stations = {f.train.get("crs") for t, f in self._follows.items() if t != token}
            if train.get("crs") not in stations and len(stations) >= self._max_stations:
                return "busy"
            self._gen += 1
            self._follows[token] = Follow(token, env, dict(train), started, dict(baseline), None, 0, self._gen)
            self._bump(token)
            return "ok"

    def is_same(self, token: str, train: dict, env: str | None = None) -> bool:
        """Same train followed by this token (and same env, when given)."""
        with self._lock:
            cur = self._follows.get(token)
            return (cur is not None and _same_train(cur.train, train)
                    and (env is None or cur.env == env))

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

    def is_current(self, token: str, gen: int) -> bool:
        with self._lock:
            cur = self._follows.get(token)
            return cur is not None and cur.gen == gen

    def remove(self, token: str, gen: int | None = None) -> None:
        with self._lock:
            cur = self._follows.get(token)
            if cur is not None and (gen is None or cur.gen == gen):
                del self._follows[token]
            if gen is None:  # a DELETE wins over a POST in flight even if nothing is stored yet
                self._bump(token)

    def stations(self) -> set[str]:
        with self._lock:
            return {f.train.get("crs") for f in self._follows.values()}

    def for_station(self, crs: str) -> list[Follow]:
        with self._lock:
            return [_copy(f) for f in self._follows.values() if f.train.get("crs") == crs]

    def __len__(self) -> int:
        with self._lock:
            return len(self._follows)


class Poller:
    """Polls each followed station's board once per tick and pushes what changed. Follows are read
    as copies, boards fetched and pushes sent outside the store lock, and results written back by
    generation, so a DELETE or replacement made meanwhile wins."""

    def __init__(self, store: FollowStore, fetch_board: Callable[[str], dict], push,
                 clock: Callable[[], float] = time.time, log: TextIO = sys.stderr) -> None:
        self._store = store
        self._log = log
        self._fetch = fetch_board
        self._push = push
        self._clock = clock
        self._paused_until = 0.0

    def tick(self) -> None:
        now = self._clock()
        self._expire(now)
        if now < self._paused_until:
            return
        for crs in sorted(self._store.stations()):
            # Copies taken before the fetch: a follow POSTed meanwhile has a baseline newer than
            # this board, so it waits for the next tick.
            follows = self._store.for_station(crs)
            try:
                board = self._fetch(crs)
            except Exception as e:  # Darwin/network errors are silent; follows kept as they are
                if getattr(e, "status", None) == 429:
                    self._paused_until = now + RATE_LIMIT_PAUSE
                    return
                continue
            for f in follows:
                try:
                    self._check(f, board, now)
                except Exception as e:  # one bad follow or service entry never stops the tick
                    self._note(e)

    def _expire(self, now: float) -> None:
        for crs in self._store.stations():
            for f in self._store.for_station(crs):
                if now - f.started >= MAX_DURATION or (
                        f.cancelled_at is not None and now - f.cancelled_at >= CANCELLED_LINGER):
                    self._store.remove(f.token, f.gen)

    def _check(self, f: Follow, board: dict, now: float) -> None:
        # The copies were taken before the fetch and earlier sends at this station; skip a follow
        # deleted or replaced since then.
        if not self._store.is_current(f.token, f.gen):
            return
        d = find_followed(board, f.train)
        if d is None:
            if f.missing + 1 >= 2:
                self._store.remove(f.token, f.gen)
            else:
                self._store.update(f.token, f.gen, missing=f.missing + 1)
            return
        if is_cancelled(d):
            cancelled_at = f.cancelled_at if f.cancelled_at is not None else now
        else:
            cancelled_at = None
        texts = changes(f.last or {}, d)
        if texts:
            title = f"{f.train.get('std')} to {f.train.get('destination')}"
            try:
                result = self._push.send(f.token, f.env, title, "\n".join(texts))
            except Exception as e:
                self._note(e)
                result = "error"
            if result == "gone":
                self._store.remove(f.token, f.gen)
                return
        # Best effort: `last` advances even when the push failed, so an alert is never repeated.
        self._store.update(f.token, f.gen, last=d, cancelled_at=cancelled_at, missing=0)

    def run(self, stop: threading.Event, every: float = 30.0) -> None:
        while not stop.is_set():
            began = self._clock()
            try:
                self.tick()
            except Exception as e:  # keep the thread alive
                self._note(e)
            # Ticks start ~`every` apart even when one is slow (clamped against clock jumps).
            stop.wait(max(0.0, min(every, every - (self._clock() - began))))

    def _note(self, e: BaseException) -> None:
        """Logs the exception type only: messages may carry tokens."""
        try:
            self._log.write(f"follow poller: {type(e).__name__}\n")
        except Exception:
            pass
