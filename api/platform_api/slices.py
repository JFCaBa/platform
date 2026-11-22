"""A board read in time slices, for when Darwin answers 500 to the whole board.

Darwin answers 500 ("The service is currently unavailable") to every board whose window holds
one train with broken data: seen at London Kings Cross on 22-11-2026, every half hour (:24 and
:54), so its next-two-hours board failed all day. Asking for smaller windows skips that train and
gets the rest.
"""
from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from typing import Callable

SLICE_MIN = 10  # first cut: minutes per slice
SMALLEST_MIN = 2  # a slice this small that still fails is dropped
MAX_OFFSET = 119  # Darwin's largest timeOffset
WORKERS = 4  # per board; the server also caps slice calls across all boards


class NoSlice(Exception):
    """No slice answered."""


def _merge(pieces: list[dict], rows: int) -> dict:
    """Pieces in time order → one Darwin board: services once each (slices overlap at their
    edges), at most `rows` counting buses and ferries, header of the first piece."""
    out = dict(pieces[0])
    seen: set[str] = set()
    total = 0
    for kind in ("trainServices", "busServices", "ferryServices"):
        merged = []
        for p in pieces:
            for s in p.get(kind) or []:
                sid = s.get("serviceID") if isinstance(s, dict) else None
                if sid is not None and sid in seen:
                    continue
                if sid is not None:
                    seen.add(sid)
                merged.append(s)
        out[kind] = merged
        total += len(merged)
    # numRows counts every kind; trim trains first only if the sum is over (rare: small slices).
    extra = total - rows
    if extra > 0:
        out["trainServices"] = out["trainServices"][: max(0, len(out["trainServices"]) - extra)]
    return out


def board_in_slices(get: Callable[[int, int, float], dict], start: int, window: int, rows: int,
                    budget_s: float, is_broken: Callable[[Exception], bool],
                    clock: Callable[[], float] = time.monotonic) -> tuple[dict, int]:
    """The board from `start` for `window` minutes, read as slices: `get(offset, window,
    deadline_s)` returns one Darwin board or raises. A slice that fails with `is_broken` is
    halved down to SMALLEST_MIN; any other error is raised at once (429, timeout: the whole
    board fails as before). Stops asking when `budget_s` runs out. Returns the merged board and
    how many minutes were dropped; NoSlice if nothing answered."""
    end_at = clock() + budget_s

    def walk(o: int, w: int) -> tuple[list[dict], int]:
        """(pieces, minutes dropped) for the slice [o, o + w)."""
        left = end_at - clock()
        if left <= 0.5:
            return [], w
        try:
            return [get(o, w, left)], 0
        except Exception as e:  # noqa: BLE001 — sorted below
            if not is_broken(e):
                raise
        if w < 2 * SMALLEST_MIN:  # halves would be under SMALLEST_MIN: drop it
            return [], w
        h = w // 2
        (a, da), (b, db) = walk(o, h), walk(o + h, w - h)
        return a + b, da + db

    starts = [o for o in range(start, start + window, SLICE_MIN) if o <= MAX_OFFSET]
    # Minutes past Darwin's largest offset cannot be asked for in slices (only page 119 has them).
    unreachable = start + window - (starts[-1] + SLICE_MIN) if starts else window
    with ThreadPoolExecutor(WORKERS) as pool:
        results = list(pool.map(lambda o: walk(o, min(SLICE_MIN, start + window - o)), starts))
    pieces = [p for r, _ in results for p in r]
    if not pieces:
        raise NoSlice()
    return _merge(pieces, rows), sum(d for _, d in results) + max(0, unreachable)
