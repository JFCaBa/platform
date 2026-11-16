"""Build stations.json (National Rail stations: CRS, name, lat, lon) from NaPTAN.

Source: NaPTAN (DfT, OGL), ATCO area 910 (National Rail), XML. Each rail station
is a StopPoint with StopType RLY and an AnnotatedRailRef/CrsRef. Some stations
have several StopPoints (e.g. Clapham Junction): they are merged by CRS.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

SOURCE_URL = "https://naptan.api.dft.gov.uk/v1/access-nodes?atcoAreaCodes=910&dataFormat=xml"
USER_AGENT = "platform-pipeline/1.0"
NS = {"n": "http://www.naptan.org.uk/"}
CRS_RE = re.compile(r"^[A-Z]{3}$")
SUFFIX = " Rail Station"


def load_rows(path: Path) -> list[dict]:
    """Active RLY StopPoints as {crs, name, lat, lon}; crs is None when missing."""
    rows = []
    for _, sp in ET.iterparse(str(path)):
        if sp.tag != "{%s}StopPoint" % NS["n"]:
            continue
        g = lambda p: sp.findtext(p, namespaces=NS)  # noqa: E731
        lat, lon = g("n:Place/n:Location/n:Translation/n:Latitude"), g("n:Place/n:Location/n:Translation/n:Longitude")
        if (sp.get("Status") == "active" and g("n:StopClassification/n:StopType") == "RLY"
                and lat and lon):
            name = (g("n:Descriptor/n:CommonName") or "").strip()
            if name.endswith(SUFFIX):
                name = name[: -len(SUFFIX)]
            crs = (g(".//n:AnnotatedRailRef/n:CrsRef") or "").strip() or None
            rows.append({"crs": crs, "name": name, "lat": float(lat), "lon": float(lon)})
        sp.clear()
    return rows


def group_by_crs(rows: list[dict]) -> list[dict]:
    """One station per CRS (centroid, most common name), sorted by CRS; rows without CRS dropped."""
    groups: dict[str, list[dict]] = {}
    for r in rows:
        if r.get("crs"):
            groups.setdefault(r["crs"], []).append(r)
    out = []
    for crs in sorted(groups):
        g = groups[crs]
        counts = Counter(r["name"] for r in g if r["name"])
        name = min(counts, key=lambda n: (-counts[n], n)) if counts else ""
        out.append({"crs": crs, "name": name,
                    "lat": round(sum(r["lat"] for r in g) / len(g), 5),
                    "lon": round(sum(r["lon"] for r in g) / len(g), 5)})
    return out


def validate(stations: list[dict], min_count: int = 2400) -> list[str]:
    errors = []
    if len(stations) < min_count:
        errors.append(f"only {len(stations)} stations (< {min_count})")
    seen = set()
    for s in stations:
        crs = s.get("crs") or ""
        if not CRS_RE.match(crs):
            errors.append(f"bad CRS {crs!r}")
        if crs in seen:
            errors.append(f"duplicate CRS {crs}")
        seen.add(crs)
        if not (49.8 <= s["lat"] <= 60.9 and -8.7 <= s["lon"] <= 1.8):
            errors.append(f"{crs} outside Great Britain ({s['lat']}, {s['lon']})")
        if not s.get("name"):
            errors.append(f"{crs} has no name")
    return errors


def download(url: str, dest: Path, user_agent: str, attempts: int = 3) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    for i in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as f:
                while chunk := resp.read(1 << 16):
                    f.write(chunk)
            return
        except OSError:
            if i == attempts - 1:
                raise
            time.sleep(30 * (i + 1))


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", help="NaPTAN XML file (default: download area 910)")
    ap.add_argument("--out", default="_site/stations.json")
    ap.add_argument("--min-count", type=int, default=2400)
    args = ap.parse_args(argv)

    with tempfile.TemporaryDirectory() as tmp:
        source = Path(args.source) if args.source else Path(tmp) / "naptan910.xml"
        if not args.source:
            download(SOURCE_URL, source, USER_AGENT)
        stations = group_by_crs(load_rows(source))

    errors = validate(stations, args.min_count)
    if errors:
        for e in errors[:50]:
            print(f"::error::{e}", file=sys.stderr)
        return 1
    doc = {"version": 1, "generated": datetime.now(timezone.utc).date().isoformat(), "stations": stations}
    write_atomic(Path(args.out), json.dumps(doc, ensure_ascii=False, separators=(",", ":")))
    print(f"{len(stations)} stations → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
