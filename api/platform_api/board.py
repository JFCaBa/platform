"""Darwin Live Departure Board response → Platform API contract."""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser

ETD_WORDS = {"On time", "Delayed", "Cancelled"}
HHMM = re.compile(r"^\d{2}:\d{2}$")
ISO = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})?$")


class _Text(HTMLParser):
    BLOCK = {"p", "br", "div", "li"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.href: str | None = None

    def handle_starttag(self, tag, attrs):
        if tag in self.BLOCK:
            self.parts.append("\n")
        elif tag == "a":
            href = dict(attrs).get("href") or ""
            self.href = href if href.startswith(("http://", "https://")) else None

    def handle_endtag(self, tag):
        if tag == "a" and self.href:
            self.parts.append(f" ({self.href})")
            self.href = None
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        self.parts.append(data)


def strip_html(s: str) -> str:
    """Plain text: tags removed, entities decoded, http(s) links kept as "text (URL)",
    paragraphs on their own lines."""
    p = _Text()
    p.feed(s or "")
    p.close()
    text = "".join(p.parts).replace("\xa0", " ")
    lines = (" ".join(line.split()) for line in text.split("\n"))
    return "\n".join(line for line in lines if line)


def _utc_iso(value: str | None, now: datetime) -> str:
    m = ISO.match(value or "")
    if m:
        dt = datetime.fromisoformat(m.group(1))
        off = m.group(2)
        if off and off != "Z":
            sign = 1 if off[0] == "+" else -1
            dt -= sign * timedelta(hours=int(off[1:3]), minutes=int(off[4:6]))
    else:
        dt = now.astimezone(timezone.utc).replace(tzinfo=None)
    return dt.replace(microsecond=0).isoformat() + "Z"


def _etd(raw: dict) -> str | None:
    etd = raw.get("etd")
    if etd in ETD_WORDS or (isinstance(etd, str) and HHMM.match(etd)):
        return etd
    return "Cancelled" if raw.get("isCancelled") else None


def _service(raw: dict) -> dict:
    dests = raw.get("destination") or []
    vias: list[str] = []
    for d in dests:
        if d.get("via") and d["via"] not in vias:
            vias.append(d["via"])
    return {
        "std": raw.get("std"),
        "etd": _etd(raw),
        "platform": raw.get("platform"),
        "destination": " & ".join(d.get("locationName", "") for d in dests if d.get("locationName")),
        "via": " & ".join(vias) or None,
        "operator": raw.get("operator"),
        "cancelled": bool(raw.get("isCancelled")),
        "delayReason": raw.get("delayReason"),
        "cancelReason": raw.get("cancelReason"),
        "serviceId": raw.get("serviceID"),
    }


BUS_NOTICE = "Replacement buses are running from this station."


BASE_ROWS = 50  # rows asked for the base board (offset 0)


def darwin_window(offset: int) -> int:
    """Minutes Darwin actually lists from `offset` (measured 18-11-2026): for offsets 1..118 the
    board stops at now + 120 min whatever timeWindow says; offsets 0 and 119 get the full 120."""
    return 120 - offset if 0 < offset < 119 else 120


def to_board(darwin: dict, crs: str, attribution: str, now: datetime, *, offset: int = 0,
             rows: int = BASE_ROWS) -> dict:
    """`complete`: fewer than `rows` came back, so the whole `window` (minutes from `timeOffset`)
    is listed."""
    messages = [strip_html(m.get("Value", "")) for m in darwin.get("nrccMessages") or []]
    if darwin.get("busServices"):
        messages.insert(0, BUS_NOTICE)
    services = [_service(s) for s in darwin.get("trainServices") or []]
    return {
        "crs": crs,
        "name": darwin.get("locationName") or crs,
        "generatedAt": _utc_iso(darwin.get("generatedAt"), now),
        "nrccMessages": [m for m in messages if m],
        "attribution": attribution,
        "timeOffset": offset,
        "window": darwin_window(offset),
        # numRows counts every service on the board, buses and ferries included.
        "complete": len(services) + len(darwin.get("busServices") or []) + len(darwin.get("ferryServices") or []) < rows,
        "services": services,
    }


def _stop(raw: dict) -> dict:
    cancelled = bool(raw.get("isCancelled")) or raw.get("et") == "Cancelled"
    et = raw.get("et")
    return {
        "name": raw.get("locationName"),
        "crs": raw.get("crs"),
        "st": raw.get("st"),
        "et": "Cancelled" if cancelled else (et if et in ETD_WORDS or (isinstance(et, str) and HHMM.match(et)) else None),
        "cancelled": cancelled,
    }


def to_stops(darwin: dict, attribution: str, now: datetime) -> dict:
    """Service Details → the stops still ahead, one list per portion: a train that splits lists
    the main portion first and each portion that leaves it after, from the split onwards."""
    portions = []
    for portion in darwin.get("subsequentCallingPoints") or []:
        stops = [_stop(p) for p in (portion or {}).get("callingPoint") or []]
        if stops:
            portions.append(stops)
    return {
        "generatedAt": _utc_iso(darwin.get("generatedAt"), now),
        "attribution": attribution,
        "portions": portions,
    }
