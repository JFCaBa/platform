"""Live Activity content state for a followed train; texts match the app's position.dart."""
from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from .board import HHMM

LONDON = ZoneInfo("Europe/London")


def is_cancelled(d: dict) -> bool:
    return bool(d.get("cancelled")) or d.get("etd") == "Cancelled"


def where_text(position: dict | None) -> str | None:
    """"2 stops away · left Stevenage 16:31", "Next stop: here · left …", "Not yet left …",
    "Starts here"; None when unknown."""
    if not isinstance(position, dict):
        return None
    if position.get("startsHere"):
        return "Starts here"
    origin = position.get("notStarted")
    if isinstance(origin, str) and origin:
        return f"Not yet left {origin}"
    stop, when, away = position.get("lastStop"), position.get("lastAt"), position.get("stopsAway")
    if not (isinstance(stop, str) and stop and isinstance(away, int) and away >= 1):
        return None
    left = f"left {stop} {when}" if isinstance(when, str) and HHMM.match(when) else f"left {stop}"
    return f"Next stop: here · {left}" if away == 1 else f"{away} stops away · {left}"


def departs_epoch(d: dict, now: float) -> int | None:
    """Expected departure in epoch seconds: `etd` when HH:MM, else `std` when on time or unknown;
    None when delayed without a time or cancelled. The London date nearest to `now`."""
    etd, std = d.get("etd"), d.get("std")
    if is_cancelled(d):
        return None
    if isinstance(etd, str) and HHMM.match(etd):
        hhmm = etd
    elif etd in (None, "On time") and isinstance(std, str) and HHMM.match(std):
        hhmm = std
    else:
        return None
    h, m = int(hhmm[:2]), int(hhmm[3:5])
    today = datetime.fromtimestamp(now, LONDON).date()
    best = None
    for off in (-1, 0, 1):
        day = today + timedelta(days=off)
        t = datetime(day.year, day.month, day.day, h, m, tzinfo=LONDON).timestamp()
        if best is None or abs(t - now) < abs(best - now):
            best = t
    return int(best)


def _status(d: dict) -> str:
    if is_cancelled(d):
        return "Cancelled"
    etd = d.get("etd")
    if isinstance(etd, str) and HHMM.match(etd):
        return f"Exp {etd}"
    return etd if etd in ("On time", "Delayed") else ""


def content_state(d: dict, position: dict | None, now: float) -> dict:
    cancelled = is_cancelled(d)
    return {
        "departs": departs_epoch(d, now),
        "status": _status(d),
        "platform": d.get("platform"),
        "where": None if cancelled else where_text(position),
        "cancelled": cancelled,
    }
