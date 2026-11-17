"""Change rules for a followed train; a Python port of the app's follow_logic.dart `changes()`."""
from __future__ import annotations

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
