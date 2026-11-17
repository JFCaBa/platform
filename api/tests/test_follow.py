from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api.follow import FollowStore, changes, find_followed, matches  # noqa: E402

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


def train(crs="CDF", std="08:12", dest="Cardiff Central", sid=None):
    return {"crs": crs, "std": std, "destination": dest, "serviceId": sid}


class FollowStoreTest(unittest.TestCase):
    def test_upsert_same_train_keeps_baseline_and_start(self):
        s = FollowStore()
        self.assertEqual(s.upsert("aa", "production", train(), {"platform": "1"}, 900.0), "ok")
        gen = s.for_station("CDF")[0].gen
        self.assertEqual(s.upsert("aa", "sandbox", train(), {"platform": "9"}, 960.0), "ok")
        (f,) = s.for_station("CDF")
        self.assertEqual(f.last, {"platform": "1"})
        self.assertEqual(f.started, 900.0)
        self.assertEqual(f.gen, gen)
        self.assertEqual(len(s), 1)

    def test_new_train_replaces(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {"platform": "1"}, 900.0)
        gen = s.for_station("CDF")[0].gen
        self.assertTrue(s.is_same("aa", train()))
        self.assertFalse(s.is_same("aa", train(std="09:00")))
        self.assertFalse(s.is_same("bb", train()))
        s.upsert("aa", "production", train(crs="NWP", std="09:00"), {"platform": "2"}, 950.0)
        self.assertEqual(s.for_station("CDF"), [])
        (f,) = s.for_station("NWP")
        self.assertEqual((f.started, f.last, f.missing), (950.0, {"platform": "2"}, 0))
        self.assertNotEqual(f.gen, gen)
        self.assertEqual(s.stations(), {"NWP"})

    def test_same_train_includes_service_id(self):
        s = FollowStore()
        s.upsert("aa", "production", train(sid="A1"), {}, 1.0)
        self.assertTrue(s.is_same("aa", train(sid="A1")))
        self.assertFalse(s.is_same("aa", train(sid="B2")))
        self.assertFalse(s.is_same("aa", train()))

    def test_cap_follows(self):
        s = FollowStore(max_follows=3)
        for i in range(3):
            self.assertEqual(s.upsert(f"t{i}", "production", train(), {}, 1.0), "ok")
        self.assertEqual(s.upsert("t3", "production", train(), {}, 1.0), "busy")
        self.assertEqual(s.upsert("t0", "production", train(), {}, 1.0), "ok")
        self.assertEqual(s.upsert("t0", "production", train(std="10:00"), {}, 1.0), "ok")
        self.assertEqual(len(s), 3)

    def test_cap_stations(self):
        s = FollowStore(max_stations=2)
        self.assertEqual(s.upsert("a", "production", train(crs="AAA"), {}, 1.0), "ok")
        self.assertEqual(s.upsert("b", "production", train(crs="BBB"), {}, 1.0), "ok")
        self.assertEqual(s.upsert("c", "production", train(crs="CCC"), {}, 1.0), "busy")
        self.assertEqual(s.upsert("c", "production", train(crs="AAA"), {}, 1.0), "ok")
        # moving the only follow at a station to another frees that station
        self.assertEqual(s.upsert("b", "production", train(crs="AAA"), {}, 1.0), "ok")
        self.assertEqual(s.upsert("d", "production", train(crs="CCC"), {}, 1.0), "ok")
        self.assertEqual(s.stations(), {"AAA", "CCC"})

    def test_remove_unknown_is_noop(self):
        s = FollowStore()
        s.remove("nope")
        s.remove("nope", 3)
        self.assertEqual(len(s), 0)

    def test_update_and_remove_with_stale_gen_are_noops(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {"platform": "1"}, 1.0)
        gen = s.for_station("CDF")[0].gen
        self.assertTrue(s.update("aa", gen, missing=1, cancelled_at=5.0))
        (f,) = s.for_station("CDF")
        self.assertEqual((f.missing, f.cancelled_at), (1, 5.0))
        self.assertFalse(s.update("aa", gen + 1, missing=2))
        self.assertFalse(s.update("zz", gen, missing=2))
        s.remove("aa", gen + 1)
        self.assertEqual(len(s), 1)
        self.assertEqual(s.for_station("CDF")[0].missing, 1)
        s.remove("aa", gen)
        self.assertEqual(len(s), 0)
        self.assertEqual(s.stations(), set())

    def test_for_station_returns_copies(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {}, 1.0)
        s.for_station("CDF")[0].missing = 9
        self.assertEqual(s.for_station("CDF")[0].missing, 0)

    def test_store_isolated_from_callers_dicts(self):
        s = FollowStore()
        base, tr = {"platform": "1"}, train()
        s.upsert("aa", "production", tr, base, 1.0)
        base["platform"] = "X"
        tr["std"] = "99:99"
        (f,) = s.for_station("CDF")
        self.assertEqual((f.last, f.train["std"]), ({"platform": "1"}, "08:12"))
        f.train["std"] = "00:00"
        f.last["platform"] = "Y"
        (g,) = s.for_station("CDF")
        self.assertEqual((g.last, g.train["std"]), ({"platform": "1"}, "08:12"))
        new = {"platform": "2"}
        s.update("aa", g.gen, last=new)
        new["platform"] = "Z"
        self.assertEqual(s.for_station("CDF")[0].last, {"platform": "2"})

    def test_update_rejects_unknown_fields(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {}, 1.0)
        gen = s.for_station("CDF")[0].gen
        for k in ("gen", "token", "train", "started", "bogus"):
            with self.assertRaises(TypeError):
                s.update("aa", gen, **{k: 1})

    def test_upsert_requires_crs(self):
        s = FollowStore()
        for bad in ({}, {"crs": ""}, {"crs": None}, {"crs": 5}):
            with self.assertRaises(ValueError):
                s.upsert("aa", "production", {**train(), **bad} if bad else {"std": "08:12"}, {}, 1.0)
        self.assertEqual(len(s), 0)

    def test_remove_without_gen(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {}, 1.0)
        s.remove("aa")
        self.assertEqual(len(s), 0)


if __name__ == "__main__":
    unittest.main()
