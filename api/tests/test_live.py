import sys
import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from platform_api.live import content_state, departs_epoch, where_text  # noqa: E402

LONDON = ZoneInfo("Europe/London")


def at(y, mo, d, h, mi):
    return datetime(y, mo, d, h, mi, tzinfo=LONDON).timestamp()


class WhereText(unittest.TestCase):
    def test_shapes(self):
        self.assertEqual(where_text({"lastStop": "Stevenage", "lastAt": "16:31", "stopsAway": 2}),
                         "2 stops away · left Stevenage 16:31")
        self.assertEqual(where_text({"lastStop": "Hitchin", "lastAt": "16:38", "stopsAway": 1}),
                         "Next stop: here · left Hitchin 16:38")
        self.assertEqual(where_text({"notStarted": "London Kings Cross"}), "Not yet left London Kings Cross")
        self.assertEqual(where_text({"startsHere": True}), "Starts here")
        self.assertIsNone(where_text(None))
        self.assertIsNone(where_text({"lastStop": None, "stopsAway": 2}))


class DepartsEpoch(unittest.TestCase):
    NOW = at(2026, 11, 21, 16, 30)

    def test_on_time_uses_std(self):
        self.assertEqual(departs_epoch({"std": "16:42", "etd": "On time"}, self.NOW), int(at(2026, 11, 21, 16, 42)))
        self.assertEqual(departs_epoch({"std": "16:42"}, self.NOW), int(at(2026, 11, 21, 16, 42)))

    def test_expected_time(self):
        self.assertEqual(departs_epoch({"std": "16:42", "etd": "16:48"}, self.NOW), int(at(2026, 11, 21, 16, 48)))

    def test_unknown(self):
        self.assertIsNone(departs_epoch({"std": "16:42", "etd": "Delayed"}, self.NOW))
        self.assertIsNone(departs_epoch({"std": "16:42", "etd": "Cancelled"}, self.NOW))
        self.assertIsNone(departs_epoch({"std": "bad"}, self.NOW))

    def test_after_midnight_is_tomorrow(self):
        now = at(2026, 11, 21, 23, 58)
        self.assertEqual(departs_epoch({"std": "00:05"}, now), int(at(2026, 11, 22, 0, 5)))

    def test_just_left_stays_today(self):
        now = at(2026, 11, 22, 0, 3)
        self.assertEqual(departs_epoch({"std": "23:59"}, now), int(at(2026, 11, 21, 23, 59)))

    def test_bst(self):
        now = at(2026, 7, 1, 8, 0)
        self.assertEqual(departs_epoch({"std": "08:15"}, now), int(at(2026, 7, 1, 8, 15)))


class ContentState(unittest.TestCase):
    NOW = at(2026, 11, 21, 16, 30)

    def test_running(self):
        d = {"std": "16:42", "etd": "16:48", "platform": "10", "destination": "Peterborough"}
        pos = {"lastStop": "Stevenage", "lastAt": "16:31", "stopsAway": 2}
        self.assertEqual(content_state(d, pos, self.NOW), {
            "departs": int(at(2026, 11, 21, 16, 48)), "status": "Exp 16:48", "platform": "10",
            "where": "2 stops away · left Stevenage 16:31", "cancelled": False})

    def test_statuses(self):
        self.assertEqual(content_state({"std": "16:42", "etd": "On time"}, None, self.NOW)["status"], "On time")
        self.assertEqual(content_state({"std": "16:42", "etd": "Delayed"}, None, self.NOW)["status"], "Delayed")
        self.assertEqual(content_state({"std": "16:42"}, None, self.NOW)["status"], "")

    def test_cancelled(self):
        s = content_state({"std": "16:42", "etd": "Cancelled", "cancelled": True, "platform": "3"}, None, self.NOW)
        self.assertEqual(s, {"departs": None, "status": "Cancelled", "platform": "3", "where": None, "cancelled": True})


if __name__ == "__main__":
    unittest.main()
