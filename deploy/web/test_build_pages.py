"""Tests for build_pages.py:  python3 -m unittest discover -s deploy/web -p 'test_*.py'"""
import json
import os
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_pages  # noqa: E402
from build_pages import build, main, nearest, publish  # noqa: E402

SITE = Path(__file__).resolve().parents[2] / "site"
NS = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}


def stations(n=5):
    base = [
        {"crs": "EUS", "name": "London Euston", "lat": 51.5282, "lon": -0.1337},
        {"crs": "KGX", "name": "London Kings Cross", "lat": 51.5309, "lon": -0.1229},
        {"crs": "STP", "name": "London St Pancras International", "lat": 51.5320, "lon": -0.1260},
        {"crs": "EPH", "name": "Elephant & Castle", "lat": 51.4940, "lon": -0.0986},
        {"crs": "XSC", "name": "Bad</script><b>'\"", "lat": 55.0, "lon": -3.0},
    ]
    return base[:n]


def ld_json(page: str) -> dict:
    m = re.search(r'<script type="application/ld\+json">(.*?)</script>', page, re.S)
    return json.loads(m.group(1))


class NearestTest(unittest.TestCase):
    def test_nearest_excludes_itself_sorted_by_distance(self):
        st = stations()
        out = nearest(st[0], st, 3)
        self.assertEqual([s["crs"] for s, _ in out], ["STP", "KGX", "EPH"])
        self.assertTrue(all(a <= b for (_, a), (_, b) in zip(out, out[1:])))


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "build"
        self.st = stations()
        build({"generated": "2026-11-24", "stations": self.st}, SITE / "index.html", self.out, min_count=1)

    def tearDown(self):
        self.tmp.cleanup()

    def page(self, crs):
        return (self.out / "station" / f"{crs}.html").read_text(encoding="utf-8")

    def test_one_page_per_station_with_title_canonical_and_heading(self):
        self.assertEqual(sorted(p.stem for p in (self.out / "station").iterdir()), sorted(s["crs"] for s in self.st))
        p = self.page("EUS")
        self.assertIn("<title>London Euston (EUS) — live departures and platforms | What Platform</title>", p)
        self.assertIn('<link rel="canonical" href="https://whatplatform.uk/station/EUS">', p)
        self.assertIn('<h1 class="station">London Euston</h1>', p)
        self.assertIn('<aside id="extra" class="extra" data-path="/station/EUS">', p)
        self.assertEqual(p.count("<title>"), 1)
        self.assertNotIn("<!--seo:", p)
        self.assertIn('<script type="module" src="/js/app.js"></script>', p)  # the board still runs

    def test_names_are_escaped_in_html_and_json_ld(self):
        p = self.page("XSC")
        self.assertNotIn("Bad</script>", p)
        self.assertIn("Bad&lt;/script&gt;&lt;b&gt;&#x27;&quot;", p)
        self.assertEqual(ld_json(p)["name"], "Bad</script><b>'\"")
        e = self.page("EPH")
        self.assertIn("Elephant &amp; Castle", e)
        self.assertEqual(ld_json(e)["name"], "Elephant & Castle")

    def test_json_ld_is_a_train_station_with_geo(self):
        d = ld_json(self.page("KGX"))
        self.assertEqual(d["@type"], "TrainStation")
        self.assertEqual(d["identifier"], "KGX")
        self.assertEqual(d["url"], "https://whatplatform.uk/station/KGX")
        self.assertEqual(d["geo"], {"@type": "GeoCoordinates", "latitude": 51.5309, "longitude": -0.1229})

    def test_nearby_links_and_a_to_z_link(self):
        p = self.page("EUS")
        extra = p[p.index('<aside id="extra"'):]
        links = re.findall(r'href="/station/([A-Z]{3})"', extra)
        self.assertEqual(links[:2], ["STP", "KGX"])
        self.assertNotIn("EUS", links)
        self.assertIn('href="/stations"', extra)
        self.assertRegex(extra, r"\d+(\.\d)? (m|km)")

    def test_a_to_z_lists_every_station_grouped_by_letter(self):
        p = (self.out / "stations.html").read_text(encoding="utf-8")
        self.assertEqual(sorted(re.findall(r'href="/station/([A-Z]{3})"', p)), sorted(s["crs"] for s in self.st))
        self.assertIn('<link rel="canonical" href="https://whatplatform.uk/stations">', p)
        self.assertIn('<h2 id="L">L</h2>', p)
        self.assertIn("Elephant &amp; Castle", p)

    def test_sitemap_lists_home_pages_and_every_station(self):
        root = ET.parse(self.out / "sitemap.xml").getroot()
        locs = [u.find("s:loc", NS).text for u in root.findall("s:url", NS)]
        self.assertEqual(locs[:3], ["https://whatplatform.uk/", "https://whatplatform.uk/stations",
                                    "https://whatplatform.uk/privacy"])
        self.assertEqual(len(locs), 3 + len(self.st))
        self.assertIn("https://whatplatform.uk/station/EPH", locs)
        lastmods = {u.find("s:loc", NS).text: getattr(u.find("s:lastmod", NS), "text", None)
                    for u in root.findall("s:url", NS)}
        self.assertEqual(lastmods["https://whatplatform.uk/station/EUS"], "2026-11-24")
        self.assertIsNone(lastmods["https://whatplatform.uk/"])


class RefuseTest(unittest.TestCase):
    def test_refuses_too_few_stations(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                build({"generated": "x", "stations": stations()}, SITE / "index.html", Path(tmp) / "b", min_count=2000)

    def test_refuses_template_without_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp) / "index.html"
            t.write_text("<html><head></head><body></body></html>")
            with self.assertRaises(ValueError):
                build({"generated": "x", "stations": stations()}, t, Path(tmp) / "b", min_count=1)

    def test_refuses_invalid_station(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = stations() + [{"crs": "../x", "name": "N", "lat": 1, "lon": 1}]
            with self.assertRaises(ValueError):
                build({"generated": "x", "stations": bad}, SITE / "index.html", Path(tmp) / "b", min_count=1)


class PublishTest(unittest.TestCase):
    def run_main(self, tmp, data, min_count="1"):
        src = Path(tmp) / "stations.json"
        src.write_text(json.dumps(data))
        return main(["--stations", str(src), "--site", str(SITE), "--out", str(Path(tmp) / "web"),
                     "--min-count", min_count])

    def test_publish_swaps_a_symlink_and_keeps_one_previous_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            for _ in range(3):
                self.assertEqual(self.run_main(tmp, {"generated": "g", "stations": stations()}), 0)
            self.assertTrue(web.is_symlink())
            self.assertTrue((web / "station" / "EUS.html").exists())
            builds = [p for p in Path(tmp).iterdir() if p.name.startswith("web-")]
            self.assertEqual(len(builds), 2)  # current + previous
            self.assertIn(web.resolve(), [b.resolve() for b in builds])

    def test_failed_build_leaves_published_pages(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            self.assertEqual(self.run_main(tmp, {"generated": "g", "stations": stations()}), 0)
            before = os.readlink(web)
            self.assertEqual(self.run_main(tmp, {"generated": "g", "stations": stations()}, min_count="2000"), 1)
            self.assertEqual(os.readlink(web), before)
            self.assertTrue((web / "station" / "EUS.html").exists())
            self.assertEqual(len([p for p in Path(tmp).iterdir() if p.name.startswith("web-")]), 1)

    def test_cleanup_failure_keeps_the_new_build_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            for _ in range(2):
                self.assertEqual(self.run_main(tmp, {"generated": "g", "stations": stations()}), 0)
            real = build_pages.shutil.rmtree

            def broken(path, *a, **kw):
                if kw.get("ignore_errors"):
                    return real(path, *a, **kw)
                raise PermissionError("no")
            build_pages.shutil.rmtree = broken
            try:
                self.assertEqual(self.run_main(tmp, {"generated": "g", "stations": stations()}), 0)
            finally:
                build_pages.shutil.rmtree = real
            self.assertTrue((web / "station" / "EUS.html").exists())

    def test_publish_replaces_a_plain_directory_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            web.mkdir()
            with self.assertRaises(ValueError):
                publish(Path(tmp) / "web-x", web)


if __name__ == "__main__":
    unittest.main()
