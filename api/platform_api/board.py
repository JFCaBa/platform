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
    }


def to_board(darwin: dict, crs: str, attribution: str, now: datetime) -> dict:
    messages = [strip_html(m.get("Value", "")) for m in darwin.get("nrccMessages") or []]
    return {
        "crs": crs,
        "name": darwin.get("locationName") or crs,
        "generatedAt": _utc_iso(darwin.get("generatedAt"), now),
        "nrccMessages": [m for m in messages if m],
        "attribution": attribution,
        "services": [_service(s) for s in darwin.get("trainServices") or []],
    }
