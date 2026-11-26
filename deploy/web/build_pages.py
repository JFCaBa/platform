#!/usr/bin/env python3
"""Builds the website's crawlable pages from the station list.

    python3 deploy/web/build_pages.py [--stations FILE] [--site DIR] [--out DIR]

Writes, for nginx (deploy/nginx/whatplatform.uk.conf):
  station/{CRS}.html  site/index.html with that station's title, canonical, JSON-LD, heading and
                      nearby stations (the live board still comes from site/js/app.js)
  stations.html       every station A–Z
  sitemap.xml         home, A–Z, privacy and every station

--out is a symlink to the current build (current-<time>/ next to it). A new build is written in full
and then swapped in with one rename, so nginx never sees a half-written set; on any failure the
published pages stay. The previous build is kept, older ones removed.
"""
from __future__ import annotations

import argparse
import fcntl
import heapq
import html
import json
import math
import os
import re
import shutil
import sys
import time
from pathlib import Path

ORIGIN = "https://whatplatform.uk"
APP_STORE = "https://apps.apple.com/gb/app/what-platform/id6835503942"
NEARBY = 6
CRS_RE = re.compile(r"^[A-Z]{3}$")
MARKERS = ("head", "body", "extra")

e = html.escape  # quote=True: also ' and "


def ld(data: dict) -> str:
    """JSON for a <script type="application/ld+json">: nothing in it can close the tag."""
    s = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def haversine_m(a: dict, b: dict) -> float:
    r = 6371000.0
    p1, p2 = math.radians(a["lat"]), math.radians(b["lat"])
    dp, dl = p2 - p1, math.radians(b["lon"] - a["lon"])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def nearest(st: dict, all_st: list[dict], n: int = NEARBY) -> list[tuple[dict, float]]:
    others = ((o, haversine_m(st, o)) for o in all_st if o["crs"] != st["crs"])
    return heapq.nsmallest(n, others, key=lambda x: (x[1], x[0]["crs"]))


def fmt_distance(m: float) -> str:
    """Same as formatDistance in site/js/stations.js."""
    if m < 1000:
        return f"{round(m / 10) * 10} m"
    return f"{m / 1000:.1f} km" if m < 100000 else f"{round(m / 1000)} km"


def validate(stations: list[dict], min_count: int) -> None:
    if len(stations) < min_count:
        raise ValueError(f"only {len(stations)} stations (< {min_count})")
    seen = set()
    for s in stations:
        if not CRS_RE.match(str(s.get("crs", ""))) or s["crs"] in seen:
            raise ValueError(f"bad or repeated code: {s.get('crs')!r}")
        seen.add(s["crs"])
        if not str(s.get("name", "")).strip():
            raise ValueError(f"{s['crs']}: no name")
        if not all(isinstance(s.get(k), (int, float)) for k in ("lat", "lon")):
            raise ValueError(f"{s['crs']}: no position")


def fill(template: str, parts: dict[str, str]) -> str:
    out = template
    for k in MARKERS:
        pat = re.compile(rf"<!--seo:{k}-->.*?<!--/seo:{k}-->", re.S)
        if len(pat.findall(out)) != 1:
            raise ValueError(f"template needs exactly one <!--seo:{k}--> block")
        out = pat.sub(lambda _m, v=parts[k]: v, out)
    return out


def station_page(template: str, st: dict, all_st: list[dict]) -> str:
    name, crs = st["name"], st["crs"]
    url = f"{ORIGIN}/station/{crs}"
    title = f"{name} ({crs}) — live departures and platforms | What Platform"
    desc = (f"Live departures from {name} ({crs}): which platform, delays and cancellations, "
            "updated every 30 seconds. Free, no sign-up.")
    data = {"@context": "https://schema.org", "@type": "TrainStation", "name": name, "identifier": crs,
            "url": url, "geo": {"@type": "GeoCoordinates", "latitude": st["lat"], "longitude": st["lon"]}}
    head = "\n".join([
        f"<title>{e(title)}</title>",
        f'<meta name="description" content="{e(desc)}">',
        f'<link rel="canonical" href="{url}">',
        '<meta property="og:type" content="website">',
        '<meta property="og:site_name" content="What Platform">',
        f'<meta property="og:title" content="{e(title)}">',
        f'<meta property="og:description" content="{e(desc)}">',
        f'<meta property="og:url" content="{url}">',
        f'<meta property="og:image" content="{ORIGIN}/apple-touch-icon.png">',
        f'<script type="application/ld+json">{ld(data)}</script>',
    ])
    body = "\n".join([
        '  <div class="top"><a class="logo" href="/">← What Platform</a>'
        f'<a class="badge small" href="{APP_STORE}" rel="noopener"><img src="/app-store-badge.svg" '
        'alt="Download on the App Store" width="102" height="34"></a></div>',
        f'  <h1 class="station">{e(name)}</h1>',
        f'  <p class="tag">Which platform does my train leave from at {e(name)}? Live departures from '
        f'{e(name)} ({crs}) with the platform, delays and cancellations from National Rail, refreshed '
        'every 30 seconds.</p>',
    ])
    near = "\n".join(
        f'    <li><a href="/station/{o["crs"]}">{e(o["name"])}</a> <span class="crs">{fmt_distance(m)}</span></li>'
        for o, m in nearest(st, all_st))
    extra = "\n".join([
        f'<aside id="extra" class="extra" data-path="/station/{crs}">',
        f"  <h2>Stations near {e(name)}</h2>",
        f'  <ul class="nearby">\n{near}\n  </ul>',
        '  <p><a href="/stations">All stations A–Z</a></p>',
        "</aside>",
    ])
    return fill(template, {"head": head, "body": body, "extra": extra})


def a_to_z_page(all_st: list[dict]) -> str:
    groups: dict[str, list[dict]] = {}
    for s in sorted(all_st, key=lambda s: (s["name"].casefold(), s["crs"])):
        first = s["name"][0].upper()
        groups.setdefault(first if "A" <= first <= "Z" else "#", []).append(s)
    letters = sorted(groups)
    index = " ".join(f'<a href="#{k}">{k}</a>' for k in letters)
    sections = "\n".join(
        f'<h2 id="{k}">{k}</h2>\n<ul class="az">\n'
        + "\n".join(f'  <li><a href="/station/{s["crs"]}">{e(s["name"])}</a> <span class="crs">{s["crs"]}</span></li>'
                    for s in groups[k])
        + "\n</ul>"
        for k in letters)
    title = "All stations A–Z — live departures and platforms | What Platform"
    desc = f"Live departures, platforms and delays for all {len(all_st):,} stations in Great Britain."
    return f"""<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<link rel="canonical" href="{ORIGIN}/stations">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="/favicon.png" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
<div class="top"><a class="logo" href="/">← What Platform</a><a class="badge small" href="{APP_STORE}" rel="noopener"><img src="/app-store-badge.svg" alt="Download on the App Store" width="102" height="34"></a></div>
<h1>All stations A–Z</h1>
<p class="tag">{e(desc)} Pick one for its next trains.</p>
<nav class="letters">{index}</nav>
{sections}
<footer>Data: National Rail · <a href="/privacy">Privacy</a></footer>
</main>
</body>
</html>
"""


def sitemap(all_st: list[dict], generated: str) -> str:
    def url(path: str, lastmod: str | None) -> str:
        lm = f"<lastmod>{e(lastmod)}</lastmod>" if lastmod else ""
        return f"<url><loc>{ORIGIN}{path}</loc>{lm}</url>"

    lastmod = generated if re.match(r"^\d{4}-\d{2}-\d{2}$", generated or "") else None
    urls = [url("/", None), url("/stations", lastmod), url("/privacy", None)]
    urls += [url(f"/station/{s['crs']}", lastmod) for s in sorted(all_st, key=lambda s: s["crs"])]
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "\n".join(urls) + "\n</urlset>\n")


def build(data: dict, template_path: Path, out: Path, min_count: int = 2000) -> None:
    """Writes every page into the new directory `out` (must not exist)."""
    all_st = data.get("stations") or []
    validate(all_st, min_count)
    template = template_path.read_text(encoding="utf-8")
    fill(template, {k: "" for k in MARKERS})  # markers present before writing anything
    (out / "station").mkdir(parents=True)
    for st in all_st:
        (out / "station" / f"{st['crs']}.html").write_text(station_page(template, st, all_st), encoding="utf-8")
    (out / "stations.html").write_text(a_to_z_page(all_st), encoding="utf-8")
    (out / "sitemap.xml").write_text(sitemap(all_st, str(data.get("generated", ""))), encoding="utf-8")


def publish(build_dir: Path, link: Path) -> None:
    """Points `link` at `build_dir` in one rename, keeps the previous build, removes older ones."""
    if link.exists() and not link.is_symlink():
        raise ValueError(f"{link} is a real directory; move it away once, then run again")
    previous = os.readlink(link) if link.is_symlink() else None
    tmp = link.with_name(f".{link.name}.tmp-{os.getpid()}")
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    os.symlink(build_dir.name, tmp)
    os.replace(tmp, link)
    # Published from here on: a failed cleanup only leaves an old build behind.
    keep = {build_dir.name, previous}
    for p in link.parent.glob(f"{link.name}-*"):
        if p.name not in keep and p.is_dir() and not p.is_symlink():
            try:
                shutil.rmtree(p)
            except OSError as err:
                print(f"build_pages: could not remove old build {p.name}: {err}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stations", default="/opt/platform/stations/stations.json")
    ap.add_argument("--site", default=str(Path(__file__).resolve().parents[2] / "site"))
    ap.add_argument("--out", default="/opt/platform/pages/current")
    ap.add_argument("--min-count", type=int, default=2000)
    args = ap.parse_args(argv)

    link = Path(args.out)
    with open(link.parent / f".{link.name}.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # a manual run and the monthly refresh never overlap
        build_dir = link.with_name(f"{link.name}-{time.strftime('%Y%m%d%H%M%S', time.gmtime())}-{time.time_ns() % 10**9}")
        try:
            data = json.loads(Path(args.stations).read_text(encoding="utf-8"))
            build(data, Path(args.site) / "index.html", build_dir, args.min_count)
            publish(build_dir, link)
        except (OSError, ValueError, KeyError, TypeError) as err:
            shutil.rmtree(build_dir, ignore_errors=True)
            print(f"build_pages: failed, published pages unchanged: {err}", file=sys.stderr)
            return 1
    print(f"build_pages: {len(data['stations'])} stations -> {link} ({build_dir.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
