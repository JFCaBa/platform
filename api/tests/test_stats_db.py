import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api.stats import Delta  # noqa: E402
from platform_api.stats_db import StatsDB  # noqa: E402


def delta(day="2026-11-23", visitors=0, closed=False, requests=0, follows=0, hours=None,
          stations=None, versions=None):
    return Delta(day, visitors, closed, requests, follows, hours or {}, stations or {}, versions or {})


class StatsDBTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "stats.db"
        self.db = StatsDB(self.path)

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def test_apply_sums(self):
        self.db.apply([delta(requests=3, hours={8: 3}, stations={"KGX": 3}, versions={"1.5": 3})])
        self.db.apply([delta(requests=2, hours={8: 1, 9: 1}, stations={"KGX": 1, "EUS": 1},
                             versions={"1.5": 2}, follows=1)])
        [d] = self.db.days(None)
        self.assertEqual((d["requests"], d["follows"]), (5, 1))
        self.assertEqual(self.db.hours(None), {8: 4, 9: 1})
        self.assertEqual(self.db.top_stations(None), [("KGX", 4), ("EUS", 1)])
        self.assertEqual(self.db.versions(None), {"1.5": 5})

    def test_visitors_not_summed(self):
        self.db.apply([delta(visitors=4)])
        self.db.apply([delta(visitors=6)])
        self.assertEqual(self.db.days(None)[0]["visitors"], 6)

    def test_restart_keeps_visitors(self):
        self.db.apply([delta(visitors=10)])
        self.db.close()
        self.db = StatsDB(self.path)
        self.db.apply([delta(visitors=3)])
        self.assertEqual(self.db.days(None)[0]["visitors"], 13)

    def test_base_frozen(self):
        self.db.apply([delta(visitors=4)])
        self.assertEqual(self.db.visitors_base("2026-11-23"), 0)

    def test_base_after_restart(self):
        self.db.apply([delta(visitors=4)])
        self.db.close()
        self.db = StatsDB(self.path)
        self.assertEqual(self.db.visitors_base("2026-11-23"), 4)

    def test_stations_count(self):
        self.db.apply([delta(stations={"KGX": 2, "EUS": 1}), delta(day="2026-11-22", stations={"PAD": 1})])
        self.assertEqual(self.db.stations_count("2026-11-23"), 2)

    def test_closed_day_without_traffic(self):
        self.db.apply([delta(closed=True, visitors=7)])
        self.assertEqual(self.db.days(None), [{"day": "2026-11-23", "visitors": 7, "requests": 0, "follows": 0}])

    def test_queries_since(self):
        for day, n in (("2026-11-21", 1), ("2026-11-22", 2), ("2026-11-23", 3)):
            self.db.apply([delta(day=day, requests=n, stations={"KGX": n, "EUS": 1, f"A{n}A": 5})])
        self.assertEqual([d["day"] for d in self.db.days("2026-11-22")], ["2026-11-22", "2026-11-23"])
        self.assertEqual(self.db.top_stations("2026-11-22", limit=2), [("A2A", 5), ("A3A", 5)])
        self.assertEqual(self.db.top_stations("2026-11-22")[2], ("KGX", 5))

    def test_backup_keeps_7(self):
        dest = Path(self.tmp.name) / "backups" / "nested"
        self.db.apply([delta(requests=1)])
        for i in range(1, 10):
            self.db.backup(dest, f"2026-11-{i:02d}")
        files = sorted(p.name for p in dest.iterdir())
        self.assertEqual(files, [f"stats-2026-11-{i:02d}.db" for i in range(3, 10)])
        with sqlite3.connect(dest / files[-1]) as c:
            self.assertEqual(c.execute("SELECT requests FROM days").fetchone(), (1,))

    def test_no_sensitive_columns(self):
        allowed = {"day", "visitors", "requests", "follows", "hour", "crs", "version"}
        with sqlite3.connect(self.path) as c:
            tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")]
            for t in tables:
                cols = {r[1] for r in c.execute(f"PRAGMA table_info({t})")}
                self.assertTrue(cols <= allowed, (t, cols))


if __name__ == "__main__":
    unittest.main()
