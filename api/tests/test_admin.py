import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api.admin import render_page, summary  # noqa: E402
from platform_api.stats import Delta  # noqa: E402
from platform_api.stats_db import StatsDB  # noqa: E402

TODAY = "2026-11-23"
NAMES = {"KGX": "London Kings Cross", "EUS": "London Euston", "BAD": "<script>alert(1)</script>"}


def delta(day, visitors=0, requests=0, stations=None, versions=None, follows=0, hours=None):
    return Delta(day, visitors, False, requests, follows, hours or {}, stations or {}, versions or {})


class AdminTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = StatsDB(Path(self.tmp.name) / "s.db")
        self.db.apply([
            delta(TODAY, visitors=5, requests=4, stations={"KGX": 4}, versions={"1.5": 3, "otro": 1},
                  follows=2, hours={8: 4}),
            delta("2026-11-13", visitors=9, requests=7, stations={"EUS": 7}, versions={"1.4": 7}),
        ])

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def s(self, rng="7d", live=6, active=1):
        return summary(self.db, TODAY, rng, live, active, NAMES)

    def test_summary_ranges(self):
        self.assertEqual([t["crs"] for t in self.s("7d")["top"]], ["KGX"])
        self.assertEqual([t["crs"] for t in self.s("all")["top"]], ["EUS", "KGX"])
        self.assertEqual(self.s("today")["top"][0], {"crs": "KGX", "name": "London Kings Cross", "requests": 4})
        self.assertEqual(self.s("x")["range"], "7d")

    def test_summary_cards(self):
        s = self.s()
        self.assertEqual((s["visitors_today"], s["stations_today"], s["follows_today"], s["active_follows"]),
                         (6, 1, 2, 1))

    def test_summary_today_uses_live(self):
        s = self.s(live=42)
        self.assertEqual(s["visitors_today"], 42)
        self.assertEqual(s["daily"][-1], {"day": TODAY, "visitors": 42})

    def test_daily_fills_gaps(self):
        daily = self.s()["daily"]
        self.assertEqual(len(daily), 30)
        self.assertEqual(daily[0]["day"], "2026-10-25")
        self.assertEqual({d["day"]: d["visitors"] for d in daily}["2026-11-13"], 9)
        self.assertEqual({d["day"]: d["visitors"] for d in daily}["2026-11-14"], 0)

    def test_hours_24(self):
        h = self.s()["hours"]
        self.assertEqual(len(h), 24)
        self.assertEqual((h[8], sum(h)), (4, 4))

    def test_versions_pct(self):
        self.assertEqual(self.s("today")["versions"], [{"version": "1.5", "requests": 3, "pct": 75},
                                                       {"version": "otro", "requests": 1, "pct": 25}])

    def test_unknown_station_name(self):
        self.db.apply([delta(TODAY, stations={"ZZZ": 9})])
        self.assertEqual(self.s("today")["top"][0], {"crs": "ZZZ", "name": "ZZZ", "requests": 9})

    def test_empty_db(self):
        db = StatsDB(Path(self.tmp.name) / "empty.db")
        s = summary(db, TODAY, "7d", 0, 0, NAMES)
        self.assertIn("No data yet", render_page(s))
        db.close()

    def test_range_nav_above_filtered_sections_only(self):
        page = render_page(self.s())
        nav = page.index('href="?range=today"')
        self.assertLess(page.index("People today"), nav)
        self.assertLess(page.index("People per day"), nav)
        self.assertLess(nav, page.index("Top stations"))

    def test_links_to_anden_admin(self):
        self.assertIn('href="/anden/admin"', render_page(self.s()))

    def test_render_escapes(self):
        self.db.apply([delta(TODAY, stations={"BAD": 99})])
        page = render_page(self.s("today"))
        self.assertNotIn("<script>", page)
        self.assertIn("&lt;script&gt;", page)

    def test_render_has_sections(self):
        page = render_page(self.s())
        for text in ("People per day", "Top stations", "Busiest hours", "App versions", "London Kings Cross"):
            self.assertIn(text, page)
        for text in ("<script", "http://", "https://"):
            self.assertNotIn(text, page)
        self.assertIn('href="?range=30d"', page)


if __name__ == "__main__":
    unittest.main()
