from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api.follow import changes, find_followed, matches  # noqa: E402

FIX = Path(__file__).parent / "fixtures"


def dep(std="08:12", dest="Cardiff Central", etd=None, platform=None, cancelled=False, cancel_reason=None, sid=None):
    return {"std": std, "etd": etd, "platform": platform, "destination": dest, "via": None, "operator": None,
            "cancelled": cancelled, "delayReason": None, "cancelReason": cancel_reason, "serviceId": sid}


def full(d):
    return dep(etd=d.get("etd"), platform=d.get("platform"), cancelled=d.get("cancelled", False),
               cancel_reason=d.get("cancelReason"))


class FollowTest(unittest.TestCase):
    def test_changes_fixture(self):
        cases = json.loads((FIX / "follow_changes.json").read_text(encoding="utf-8"))
        self.assertGreater(len(cases), 0)
        for c in cases:
            with self.subTest(c=c):
                self.assertEqual(changes(full(c["before"]), full(c["after"])), c["alerts"])

    def test_matches_by_id_when_both_have_one(self):
        t = {"crs": "CDF", "std": "08:12", "destination": "Cardiff Central", "serviceId": "A1"}
        self.assertTrue(matches(t, dep(sid="A1", std="09:00")))
        self.assertFalse(matches(t, dep(sid="B2")))

    def test_matches_by_std_and_destination_otherwise(self):
        t = {"crs": "CDF", "std": "08:12", "destination": "Cardiff Central", "serviceId": "A1"}
        self.assertTrue(matches(t, dep()))  # board lost ids
        self.assertFalse(matches(t, dep(std="08:13")))
        self.assertFalse(matches(t, dep(dest="Swansea")))
        u = {"crs": "CDF", "std": "08:12", "destination": "Cardiff Central"}
        self.assertTrue(matches(u, dep(sid="B2")))

    def test_find_followed_wrong_crs_is_none(self):
        t = {"crs": "CDF", "std": "08:12", "destination": "Cardiff Central"}
        services = [dep(std="08:00"), dep(platform="3")]
        self.assertEqual(find_followed({"crs": "CDF", "services": services}, t)["platform"], "3")
        self.assertIsNone(find_followed({"crs": "NWP", "services": services}, t))
        self.assertIsNone(find_followed({"crs": "CDF", "services": [dep(std="08:00")]}, t))


if __name__ == "__main__":
    unittest.main()
