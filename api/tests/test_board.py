import copy
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api.board import strip_html, to_board  # noqa: E402

FIX = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 11, 16, 14, 34, tzinfo=timezone.utc)
ATTR = "Data: National Rail"
KEYS = {"std", "etd", "platform", "destination", "via", "operator", "cancelled", "delayReason", "cancelReason"}


def load(name):
    return json.loads((FIX / name).read_text())


def svc(**kw):
    s = {"std": "10:15", "etd": "On time", "destination": [{"locationName": "Cambridge", "crs": "CBG"}],
         "operator": "Great Northern", "isCancelled": False}
    s.update(kw)
    return s


def board_with(*services):
    return {"crs": "KGX", "locationName": "London Kings Cross",
            "generatedAt": "2026-11-16T14:33:37.6541608+00:00", "trainServices": list(services)}


class BoardTest(unittest.TestCase):
    def test_maps_kgx_fixture(self):
        raw = load("darwin_kgx.json")
        b = to_board(raw, "KGX", ATTR, NOW)
        self.assertEqual(b["crs"], "KGX")
        self.assertEqual(b["name"], "London Kings Cross")
        self.assertEqual(b["generatedAt"], raw["generatedAt"][:19] + "Z")  # Darwin sends +00:00
        self.assertEqual(b["attribution"], ATTR)
        self.assertEqual(len(b["services"]), len(raw["trainServices"]))
        for s in b["services"]:
            self.assertEqual(set(s), KEYS)
        first = raw["trainServices"][0]
        self.assertEqual(b["services"][0]["std"], first["std"])
        self.assertEqual(b["services"][0]["platform"], first.get("platform"))
        self.assertEqual(b["services"][0]["destination"], first["destination"][0]["locationName"])
        self.assertTrue(all("<" not in m for m in b["nrccMessages"]))

    def test_generated_at_with_other_offset_is_utc(self):
        raw = board_with()
        raw["generatedAt"] = "2026-07-01T10:00:05.1+01:00"
        self.assertEqual(to_board(raw, "KGX", ATTR, NOW)["generatedAt"], "2026-07-01T09:00:05Z")

    def test_missing_generated_at_uses_now(self):
        raw = board_with()
        del raw["generatedAt"]
        self.assertEqual(to_board(raw, "KGX", ATTR, NOW)["generatedAt"], "2026-11-16T14:34:00Z")

    def test_cancelled_service(self):
        b = to_board(board_with(svc(isCancelled=True, etd="Cancelled")), "KGX", ATTR, NOW)
        self.assertTrue(b["services"][0]["cancelled"])
        self.assertEqual(b["services"][0]["etd"], "Cancelled")
        raw = load("darwin_kgx.json")
        cancelled = [s for s in to_board(raw, "KGX", ATTR, NOW)["services"] if s["cancelled"]]
        self.assertTrue(cancelled and all(s["etd"] == "Cancelled" for s in cancelled))

    def test_etd_values(self):
        for etd, want in [("On time", "On time"), ("10:22", "10:22"), ("Delayed", "Delayed"),
                          ("Cancelled", "Cancelled"), ("No report", None), (None, None)]:
            s = svc(etd=etd) if etd is not None else {k: v for k, v in svc().items() if k != "etd"}
            self.assertEqual(to_board(board_with(s), "KGX", ATTR, NOW)["services"][0]["etd"], want, etd)

    def test_missing_platform_is_null(self):
        b = to_board(board_with(svc()), "KGX", ATTR, NOW)
        self.assertIsNone(b["services"][0]["platform"])
        b = to_board(board_with(svc(platform="9")), "KGX", ATTR, NOW)
        self.assertEqual(b["services"][0]["platform"], "9")

    def test_empty_board_has_no_services(self):
        b = to_board(load("darwin_empty.json"), "BKM", ATTR, NOW)
        self.assertEqual(b["services"], [])
        self.assertEqual(b["nrccMessages"], [])
        self.assertEqual(b["name"], "Berkhamsted")

    def test_nrcc_html_is_stripped(self):
        self.assertEqual(strip_html('<p>Delays <a href="x">here</a> &amp; there</p>'), "Delays here & there")
        self.assertEqual(strip_html("up to&nbsp;45 minutes"), "up to 45 minutes")

    def test_nrcc_links_kept(self):
        self.assertEqual(strip_html('<p>See <a href="https://x.uk/a">here</a></p><p>Next</p>'),
                         "See here (https://x.uk/a)\nNext")

    def test_multiple_destinations_joined(self):
        s = svc(destination=[{"locationName": "Reading"}, {"locationName": "Oxford"}])
        self.assertEqual(to_board(board_with(s), "KGX", ATTR, NOW)["services"][0]["destination"], "Reading & Oxford")

    def test_via_and_cancel_reason_mapped(self):
        raw = load("darwin_clj.json")
        b = to_board(raw, "CLJ", ATTR, NOW)
        vias = [s["via"] for s in b["services"] if s["via"]]
        self.assertIn("via Wimbledon", vias)
        split = next(s for s in b["services"] if " & " in s["destination"])
        self.assertEqual(split["destination"], "Portsmouth Harbour & Bognor Regis")
        self.assertEqual(split["via"], "via Horsham")
        s = svc(isCancelled=True, etd="Cancelled", cancelReason="Points failure", delayReason="Late crew")
        out = to_board(board_with(s), "KGX", ATTR, NOW)["services"][0]
        self.assertEqual((out["cancelReason"], out["delayReason"]), ("Points failure", "Late crew"))

    def test_input_not_mutated(self):
        raw = load("darwin_clj.json")
        before = copy.deepcopy(raw)
        to_board(raw, "CLJ", ATTR, NOW)
        self.assertEqual(raw, before)


if __name__ == "__main__":
    unittest.main()
