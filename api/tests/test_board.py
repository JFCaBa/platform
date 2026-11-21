import copy
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api.board import strip_html, to_board, to_stops, train_position  # noqa: E402

FIX = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 11, 16, 14, 34, tzinfo=timezone.utc)
ATTR = "Data: National Rail"
KEYS = {"std", "etd", "platform", "destination", "via", "operator", "cancelled", "delayReason", "cancelReason", "serviceId"}


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

    def test_complete_when_fewer_rows_than_asked(self):
        raw = board_with(svc(), svc())
        b = to_board(raw, "KGX", ATTR, NOW)
        self.assertEqual((b["timeOffset"], b["complete"]), (0, True))
        b = to_board(raw, "KGX", ATTR, NOW, offset=30, rows=2)
        self.assertEqual((b["timeOffset"], b["complete"]), (30, False))

    def test_window_is_what_darwin_lists(self):
        raw = board_with(svc())
        self.assertEqual([to_board(raw, "KGX", ATTR, NOW, offset=o)["window"] for o in (0, 1, 45, 118, 119)],
                         [120, 119, 75, 2, 120])

    def test_buses_and_ferries_count_towards_the_rows(self):
        raw = board_with(svc())
        raw["busServices"] = [{"std": "10:00"}]
        raw["ferryServices"] = [{"std": "10:05"}]
        self.assertFalse(to_board(raw, "KGX", ATTR, NOW, offset=30, rows=3)["complete"])
        self.assertTrue(to_board(raw, "KGX", ATTR, NOW, offset=30, rows=4)["complete"])

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

    def test_replacement_buses_get_a_notice(self):
        raw = board_with()
        del raw["trainServices"]
        raw["busServices"] = [svc(serviceType="bus")]
        b = to_board(raw, "KGX", ATTR, NOW)
        self.assertEqual(b["services"], [])
        self.assertEqual(b["nrccMessages"][0], "Replacement buses are running from this station.")
        self.assertNotIn("Replacement buses are running from this station.",
                         to_board(board_with(svc()), "KGX", ATTR, NOW)["nrccMessages"])

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

    def test_service_id_mapped(self):
        board = to_board(load("darwin_kgx.json"), "KGX", "x", NOW)
        self.assertEqual(board["services"][0]["serviceId"], "10749482KNGX____")

    def test_stops_from_service_details(self):
        svc = to_stops(load("darwin_service.json"), "x", NOW)
        self.assertEqual(svc["generatedAt"], "2026-11-17T14:25:19Z")
        self.assertEqual(len(svc["portions"]), 1)
        self.assertEqual([s["name"] for s in svc["portions"][0]][:2], ["Finsbury Park", "Alexandra Palace"])

    def test_stops_status_values(self):
        raw = {"generatedAt": "2026-11-17T14:25:19+00:00", "subsequentCallingPoints": [{"callingPoint": [
            {"locationName": "A", "crs": "AAA", "st": "10:00", "et": "10:04"},
            {"locationName": "B", "crs": "BBB", "st": "10:10", "et": "Cancelled", "isCancelled": True},
            {"locationName": "C", "crs": "CCC", "st": "10:20", "et": "Delayed"},
            {"locationName": "D", "crs": "DDD", "st": "10:30", "et": "nonsense"},
        ]}, {"callingPoint": [{"locationName": "Other portion", "crs": "OOO", "st": "11:00"}]}]}
        portions = to_stops(raw, "x", NOW)["portions"]
        self.assertEqual([(s["name"], s["et"], s["cancelled"]) for s in portions[0]],
                         [("A", "10:04", False), ("B", "Cancelled", True), ("C", "Delayed", False), ("D", None, False)])
        # a train that splits: the other portion's stops are kept, in their own list
        self.assertEqual([s["name"] for s in portions[1]], ["Other portion"])

    def test_stops_none_when_no_calling_points(self):
        self.assertEqual(to_stops({"generatedAt": None}, "x", NOW)["portions"], [])
        self.assertEqual(to_stops({"subsequentCallingPoints": [None, {"callingPoint": []}]}, "x", NOW)["portions"], [])

    @staticmethod
    def _prev(*points):
        return {"previousCallingPoints": [{"callingPoint": list(points)}]}

    def test_position_last_passed_stop(self):
        raw = self._prev({"locationName": "A", "st": "16:00", "at": "On time"},
                         {"locationName": "B", "st": "16:10", "at": "16:12"},
                         {"locationName": "C", "st": "16:20", "et": "On time"})
        self.assertEqual(train_position(raw), {"lastStop": "B", "lastAt": "16:12", "stopsAway": 2})

    def test_position_on_time_uses_st(self):
        raw = self._prev({"locationName": "A", "st": "16:00", "at": "On time"})
        self.assertEqual(train_position(raw), {"lastStop": "A", "lastAt": "16:00", "stopsAway": 1})

    def test_position_not_started(self):
        raw = self._prev({"locationName": "A", "st": "16:00", "et": "On time"},
                         {"locationName": "B", "st": "16:10", "et": "16:12"})
        self.assertEqual(train_position(raw), {"notStarted": "A"})

    def test_position_no_report_is_not_passed(self):
        raw = self._prev({"locationName": "A", "st": "16:00", "at": "16:01"},
                         {"locationName": "B", "st": "16:10", "at": "No report"},
                         {"locationName": "C", "st": "16:20", "at": "Cancelled"})
        self.assertEqual(train_position(raw), {"lastStop": "A", "lastAt": "16:01", "stopsAway": 3})

    def test_position_starts_here(self):
        self.assertEqual(train_position({}), {"startsHere": True})
        self.assertEqual(train_position({"previousCallingPoints": [None]}), {"startsHere": True})

    def test_position_uses_first_portion_only(self):
        raw = {"previousCallingPoints": [
            {"callingPoint": [{"locationName": "A", "st": "16:00", "at": "On time"}]},
            {"callingPoint": [{"locationName": "Joining", "st": "16:05", "at": "On time"},
                              {"locationName": "J2", "st": "16:06", "et": "On time"}]}]}
        self.assertEqual(train_position(raw), {"lastStop": "A", "lastAt": "16:00", "stopsAway": 1})

    def test_to_stops_has_position(self):
        self.assertEqual(to_stops({}, "x", NOW)["position"], {"startsHere": True})

    def test_input_not_mutated(self):
        raw = load("darwin_clj.json")
        before = copy.deepcopy(raw)
        to_board(raw, "CLJ", ATTR, NOW)
        self.assertEqual(raw, before)


if __name__ == "__main__":
    unittest.main()
