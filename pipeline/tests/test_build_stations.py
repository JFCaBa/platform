import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import build_stations  # noqa: E402
from build_stations import group_by_crs, load_rows, main, validate  # noqa: E402

FIXTURE = Path(__file__).parent / "fixtures" / "naptan_sample.xml"


def st(crs, lat=51.5, lon=-0.1, name="X"):
    return {"crs": crs, "name": name, "lat": lat, "lon": lon}


class LoadTest(unittest.TestCase):
    def test_load_rows_keeps_active_rail_stations_only(self):
        rows = load_rows(FIXTURE)
        names = {r["name"] for r in rows}
        self.assertIn("London Kings Cross", names)  # " Rail Station" suffix removed
        self.assertNotIn("Albany Park - Footscray Lane", names)  # BCQ, not a station
        self.assertFalse(any(r["name"].startswith("Abercynon North") for r in rows))  # inactive
        kgx = next(r for r in rows if r["crs"] == "KGX")
        self.assertAlmostEqual(kgx["lat"], 51.53088, places=4)
        self.assertAlmostEqual(kgx["lon"], -0.12293, places=4)


class GroupTest(unittest.TestCase):
    def test_group_by_crs_merges_duplicates(self):
        out = group_by_crs([st("BHM", 52.0, -1.0, "Birmingham New Street"),
                            st("BHM", 53.0, -2.0, "Birmingham New Street")])
        self.assertEqual(out, [{"crs": "BHM", "name": "Birmingham New Street", "lat": 52.5, "lon": -1.5}])

    def test_group_by_crs_most_common_name_and_sorted(self):
        out = group_by_crs([st("LPY", name="Liverpool South Parkway"), st("KGX", name="London Kings Cross"),
                            st("LPY", name="Liverpool South Parkway"), st("LPY", name="Allerton")])
        self.assertEqual([s["crs"] for s in out], ["KGX", "LPY"])
        self.assertEqual(out[1]["name"], "Liverpool South Parkway")

    def test_group_by_crs_name_ignores_blanks_and_ties_are_deterministic(self):
        out = group_by_crs([st("ABC", name=""), st("ABC", name=""), st("ABC", name="Zed"), st("ABC", name="Ayr")])
        self.assertEqual(out[0]["name"], "Ayr")

    def test_download_retries_transient_errors(self):
        calls = []

        def flaky(req, timeout):
            calls.append(1)
            raise OSError("boom")

        orig, orig_sleep = build_stations.urllib.request.urlopen, build_stations.time.sleep
        build_stations.urllib.request.urlopen, build_stations.time.sleep = flaky, lambda s: None
        try:
            with self.assertRaises(OSError):
                build_stations.download("http://x", Path(tempfile.mkdtemp()) / "f", "ua")
        finally:
            build_stations.urllib.request.urlopen, build_stations.time.sleep = orig, orig_sleep
        self.assertEqual(len(calls), 3)

    def test_rows_without_crs_are_dropped(self):
        out = group_by_crs([st(None), st(""), st("KGX")])
        self.assertEqual([s["crs"] for s in out], ["KGX"])

    def test_fixture_groups_clapham_into_one(self):
        out = group_by_crs(load_rows(FIXTURE))
        crs = [s["crs"] for s in out]
        self.assertEqual(crs.count("CLJ"), 1)
        self.assertEqual(sorted(crs), crs)
        self.assertEqual(set(crs), {"BHM", "CLJ", "EDB", "KGX", "LPY", "MAN"})


class ValidateTest(unittest.TestCase):
    def test_validate(self):
        self.assertTrue(validate([st("KGX")]))  # below default min_count 2400
        self.assertTrue(validate([st("kgx")], min_count=1))
        self.assertTrue(validate([st("KG")], min_count=1))
        self.assertTrue(validate([st("KGX"), st("KGX")], min_count=1))
        self.assertTrue(validate([st("KGX", lat=48.0)], min_count=1))
        self.assertTrue(validate([st("KGX", lat=61.0)], min_count=1))
        self.assertTrue(validate([st("KGX", lon=-9.0)], min_count=1))
        self.assertTrue(validate([st("KGX", lon=2.0)], min_count=1))
        self.assertEqual(validate(group_by_crs(load_rows(FIXTURE)), min_count=1), [])


class MainTest(unittest.TestCase):
    def test_main_writes_sorted_json(self):
        out = Path(tempfile.mkdtemp()) / "site" / "stations.json"
        code = main(["--source", str(FIXTURE), "--out", str(out), "--min-count", "1"])
        self.assertEqual(code, 0)
        data = json.loads(out.read_text())
        self.assertEqual(data["version"], 1)
        self.assertRegex(data["generated"], r"^\d{4}-\d{2}-\d{2}$")
        crs = [s["crs"] for s in data["stations"]]
        self.assertEqual(crs, sorted(crs))
        kgx = next(s for s in data["stations"] if s["crs"] == "KGX")
        self.assertEqual(set(kgx), {"crs", "name", "lat", "lon"})
        self.assertEqual(kgx["lat"], round(kgx["lat"], 5))

    def test_main_refuses_invalid(self):
        out = Path(tempfile.mkdtemp()) / "stations.json"
        code = main(["--source", str(FIXTURE), "--out", str(out)])  # default min_count 2400
        self.assertEqual(code, 1)
        self.assertFalse(out.exists())

    def test_main_download_uses_user_agent(self):
        seen = {}

        def fake_download(url, dest, user_agent):
            seen["ua"] = user_agent
            Path(dest).write_bytes(FIXTURE.read_bytes())

        out = Path(tempfile.mkdtemp()) / "stations.json"
        orig = build_stations.download
        build_stations.download = fake_download
        try:
            self.assertEqual(main(["--out", str(out), "--min-count", "1"]), 0)
        finally:
            build_stations.download = orig
        self.assertEqual(seen["ua"], "platform-pipeline/1.0")


if __name__ == "__main__":
    unittest.main()
