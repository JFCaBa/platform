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
        self.assertEqual(s.upsert("aa", "production", train(), {"platform": "9"}, 960.0), "ok")
        (f,) = s.for_station("CDF")
        self.assertEqual(f.last, {"platform": "1"})
        self.assertEqual(f.started, 900.0)
        self.assertEqual(f.gen, gen)
        self.assertEqual(len(s), 1)

    def test_upsert_same_train_new_env_keeps_state_with_new_gen(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {"platform": "1"}, 900.0)
        gen = s.for_station("CDF")[0].gen
        s.update("aa", gen, missing=1, cancelled_at=950.0)
        self.assertEqual(s.upsert("aa", "sandbox", train(), {"platform": "9"}, 960.0), "ok")
        (f,) = s.for_station("CDF")
        self.assertEqual((f.env, f.last, f.started, f.missing, f.cancelled_at),
                         ("sandbox", {"platform": "1"}, 900.0, 1, 950.0))
        self.assertNotEqual(f.gen, gen)
        # a poller send to the old env host can no longer touch or remove it
        self.assertFalse(s.update("aa", gen, missing=0))
        s.remove("aa", gen)
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

    def test_epoch_unknown_token_is_zero(self):
        self.assertEqual(FollowStore().epoch("aa"), 0)

    def test_stale_upsert_after_remove(self):
        s = FollowStore()
        e = s.epoch("aa")
        s.remove("aa")  # DELETE of a follow that did not exist yet still wins
        self.assertNotEqual(s.epoch("aa"), e)
        self.assertEqual(s.upsert("aa", "production", train(), {}, 1.0, expect_epoch=e), "stale")
        self.assertEqual(len(s), 0)

    def test_stale_upsert_after_other_upsert(self):
        s = FollowStore()
        e = s.epoch("aa")
        self.assertEqual(s.upsert("aa", "production", train(), {"platform": "1"}, 1.0, expect_epoch=e), "ok")
        self.assertEqual(s.upsert("aa", "production", train(std="09:00"), {}, 2.0, expect_epoch=e), "stale")
        (f,) = s.for_station("CDF")
        self.assertEqual(f.train, train())
        e2 = s.epoch("aa")
        self.assertNotEqual(e2, e)
        self.assertEqual(s.upsert("aa", "production", train(std="09:00"), {}, 2.0, expect_epoch=e2), "ok")

    def test_epoch_untouched_by_other_tokens(self):
        s = FollowStore()
        e = s.epoch("aa")
        s.upsert("bb", "production", train(), {}, 1.0)
        s.remove("bb")
        self.assertEqual(s.upsert("aa", "production", train(), {}, 1.0, expect_epoch=e), "ok")

    def test_epoch_map_is_bounded(self):
        s = FollowStore()
        for i in range(FollowStore.MAX_EPOCHS + 50):
            s.remove(f"t{i}")
        self.assertLessEqual(len(s._epochs), FollowStore.MAX_EPOCHS)
        self.assertNotEqual(s.epoch(f"t{FollowStore.MAX_EPOCHS + 49}"), 0)

    def test_pruned_delete_still_wins(self):
        s = FollowStore()
        e = s.epoch("aa")  # a first-follow POST reads the epoch of an unknown token
        s.remove("aa")     # DELETE meanwhile
        for i in range(FollowStore.MAX_EPOCHS + 1):  # "aa" is pruned from the map
            s.remove(f"t{i}")
        self.assertNotIn("aa", s._epochs)
        self.assertEqual(s.upsert("aa", "production", train(), {}, 1.0, expect_epoch=e), "stale")
        self.assertEqual(len(s), 0)

    def test_is_same_checks_env_when_given(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {}, 1.0)
        self.assertTrue(s.is_same("aa", train(), "production"))
        self.assertFalse(s.is_same("aa", train(), "sandbox"))
        self.assertTrue(s.is_same("aa", train()))

    def test_remove_without_gen(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {}, 1.0)
        s.remove("aa")
        self.assertEqual(len(s), 0)

    def test_poller_remove_does_not_bump_epoch(self):
        s = FollowStore()
        s.upsert("aa", "production", train(), {}, 1.0)
        gen = s.for_station("CDF")[0].gen
        e = s.epoch("aa")  # a POST reads the epoch, then the poller cleans the follow up
        s.remove("aa", gen)
        self.assertEqual(len(s), 0)
        self.assertEqual(s.epoch("aa"), e)
        self.assertEqual(s.upsert("aa", "production", train(std="09:00"), {}, 2.0, expect_epoch=e), "ok")


TOKEN = "ab" * 32
TOKEN2 = "cd" * 32
T0 = 1_000_000.0


class Clock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t


class Boards:
    """Fake fetch_board: returns the board set for a CRS, or raises the exception set for it."""

    def __init__(self):
        self.boards: dict[str, object] = {}
        self.calls: list[str] = []

    def set(self, crs, *services):
        self.boards[crs] = {"crs": crs, "services": list(services)}

    def __call__(self, crs):
        self.calls.append(crs)
        b = self.boards.get(crs)
        if isinstance(b, BaseException):
            raise b
        if b is None:
            raise RuntimeError("no board")
        return b


class Push:
    def __init__(self, result="ok", hook=None):
        self.result = result
        self.hook = hook
        self.sent: list[tuple] = []

    def send(self, token, env, title, body):
        self.sent.append((token, env, title, body))
        if self.hook:
            self.hook()
        return self.result


class RateLimited(Exception):
    status = 429


class Upstream(Exception):
    status = 502


class PollerTest(unittest.TestCase):
    def setUp(self):
        from platform_api.follow import Poller
        self.store = FollowStore()
        self.boards = Boards()
        self.push = Push()
        self.clock = Clock()
        self.poller = Poller(self.store, self.boards, self.push, clock=self.clock)

    def follow(self, token=TOKEN, t=None, baseline=None, started=None):
        t = t or train()
        base = baseline if baseline is not None else dep(std=t["std"], dest=t["destination"], platform="3", etd="On time")
        self.store.upsert(token, "production", t, base, self.clock.t if started is None else started)

    def only(self, crs="CDF"):
        (f,) = self.store.for_station(crs)
        return f

    def test_alert_on_platform_change(self):
        self.follow()
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        self.assertEqual(self.push.sent, [(TOKEN, "production", "08:12 to Cardiff Central",
                                           "Platform changed: 3 → 5")])
        self.assertEqual(self.only().last["platform"], "5")

    def test_two_changes_one_push_joined_by_newline(self):
        self.follow()
        self.boards.set("CDF", dep(platform="5", etd="08:19"))
        self.poller.tick()
        self.assertEqual(len(self.push.sent), 1)
        self.assertEqual(self.push.sent[0][3], "Platform changed: 3 → 5\nNow expected 08:19")
        self.boards.set("CDF", dep(platform="6", etd="08:19"))
        self.poller.tick()
        self.assertEqual(len(self.push.sent), 2)  # a later change is its own push, none replaced

    def test_no_alert_when_unchanged(self):
        self.follow()
        self.boards.set("CDF", dep(platform="3", etd="On time"))
        self.poller.tick()
        self.poller.tick()
        self.assertEqual(self.push.sent, [])
        self.assertEqual(len(self.store), 1)

    def test_one_fetch_per_station(self):
        self.follow(TOKEN)
        self.follow(TOKEN2)
        self.follow("ef" * 32, t=train(crs="NWP"))
        self.boards.set("CDF", dep(platform="3", etd="On time"))
        self.boards.set("NWP", dep(platform="3", etd="On time"))
        self.poller.tick()
        self.assertEqual(sorted(self.boards.calls), ["CDF", "NWP"])

    def test_missing_once_keeps_twice_ends(self):
        self.follow()
        self.boards.set("CDF", dep(std="09:00"))
        self.poller.tick()
        self.assertEqual(self.only().missing, 1)
        self.boards.set("CDF", dep(platform="3", etd="On time"))
        self.poller.tick()
        self.assertEqual(self.only().missing, 0)  # a reading with the train resets the count
        self.boards.set("CDF", dep(std="09:00"))
        self.poller.tick()
        self.assertEqual(len(self.store), 1)
        self.poller.tick()
        self.assertEqual(len(self.store), 0)
        self.assertEqual(self.push.sent, [])

    def test_cancelled_ends_after_two_minutes(self):
        self.follow()
        self.boards.set("CDF", dep(platform="3", etd="Cancelled", cancelled=True, cancel_reason="a fault"))
        self.poller.tick()
        self.assertEqual([s[3] for s in self.push.sent], ["Cancelled: a fault"])
        self.assertEqual(self.only().cancelled_at, T0)
        self.clock.t = T0 + 60
        self.poller.tick()
        self.assertEqual(self.only().cancelled_at, T0)  # earliest kept
        self.clock.t = T0 + 119
        self.poller.tick()
        self.assertEqual(len(self.store), 1)
        self.clock.t = T0 + 120
        self.poller.tick()
        self.assertEqual(len(self.store), 0)
        self.assertEqual(len(self.push.sent), 1)

    def test_cancellation_taken_back_clears_linger(self):
        self.follow()
        self.boards.set("CDF", dep(platform="3", etd="Cancelled", cancelled=True))
        self.poller.tick()
        self.clock.t = T0 + 30
        self.boards.set("CDF", dep(platform="3", etd="08:20"))
        self.poller.tick()
        self.assertIsNone(self.only().cancelled_at)
        self.clock.t = T0 + 600
        self.poller.tick()
        self.assertEqual(len(self.store), 1)

    def test_three_hours_ends(self):
        self.follow()
        self.boards.set("CDF", dep(platform="3", etd="On time"))
        self.clock.t = T0 + 3 * 3600 - 1
        self.poller.tick()
        self.assertEqual(len(self.store), 1)
        self.clock.t = T0 + 3 * 3600
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        self.assertEqual(len(self.store), 0)
        self.assertEqual(self.push.sent, [])

    def test_expiry_runs_during_429_pause(self):
        self.follow(started=T0 - 3 * 3600 + 100)
        self.boards.boards["CDF"] = RateLimited()
        self.poller.tick()
        self.assertEqual(len(self.store), 1)
        self.clock.t = T0 + 100
        self.poller.tick()
        self.assertEqual(len(self.store), 0)
        self.assertEqual(self.boards.calls, ["CDF"])

    def test_expiry_runs_during_upstream_errors(self):
        self.follow()
        self.boards.set("CDF", dep(platform="3", etd="Cancelled", cancelled=True))
        self.poller.tick()
        self.boards.boards["CDF"] = Upstream()
        self.clock.t = T0 + 120
        self.poller.tick()
        self.assertEqual(len(self.store), 0)
        self.follow()
        self.clock.t += 3 * 3600
        self.poller.tick()
        self.assertEqual(len(self.store), 0)

    def test_gone_token_removed(self):
        self.push.result = "gone"
        self.follow()
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        self.assertEqual(len(self.store), 0)

    def test_push_error_keeps_follow_and_advances_last(self):
        self.push.result = "error"
        self.follow()
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        self.assertEqual(self.only().last["platform"], "5")
        self.poller.tick()
        self.assertEqual(len(self.push.sent), 1)  # not resent

    def test_replaced_during_send_survives(self):
        other = train(crs="NWP", std="09:00", dest="Swansea")
        self.push.hook = lambda: self.store.upsert(TOKEN, "sandbox", other, {"platform": "1"}, T0 + 5)
        self.push.result = "gone"
        self.follow()
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        f = self.only("NWP")
        self.assertEqual((f.env, f.train, f.last, f.started, f.missing, f.cancelled_at),
                         ("sandbox", other, {"platform": "1"}, T0 + 5, 0, None))

    def test_deleted_during_send_not_recreated(self):
        self.push.hook = lambda: self.store.remove(TOKEN)
        self.follow()
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        self.assertEqual(len(self.store), 0)

    def test_upstream_error_silent(self):
        self.follow()
        self.boards.boards["CDF"] = Upstream()
        self.poller.tick()
        self.poller.tick()
        self.boards.boards["CDF"] = OSError("network")
        self.poller.tick()
        f = self.only()
        self.assertEqual((f.missing, f.last["platform"]), (0, "3"))
        self.assertEqual(self.push.sent, [])

    def test_429_pauses_five_minutes(self):
        self.follow()
        self.follow("ef" * 32, t=train(crs="NWP"))
        self.boards.boards["CDF"] = RateLimited()
        self.boards.boards["NWP"] = RateLimited()
        self.poller.tick()
        self.assertEqual(len(self.boards.calls), 1)  # stops at the first 429
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.boards.set("NWP", dep(platform="5", etd="On time"))
        self.clock.t = T0 + 299
        self.poller.tick()
        self.assertEqual(len(self.boards.calls), 1)
        self.clock.t = T0 + 300
        self.poller.tick()
        self.assertEqual(len(self.boards.calls), 3)
        self.assertEqual(len(self.push.sent), 2)

    def test_is_current(self):
        self.follow()
        gen = self.only().gen
        self.assertTrue(self.store.is_current(TOKEN, gen))
        self.assertFalse(self.store.is_current(TOKEN, gen + 1))
        self.assertFalse(self.store.is_current(TOKEN2, gen))

    def test_other_follow_deleted_during_send_not_pushed(self):
        self.follow(TOKEN)
        self.follow(TOKEN2)
        self.push.hook = lambda: self.store.remove(TOKEN2)
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        self.assertEqual([s[0] for s in self.push.sent], [TOKEN])
        self.assertEqual([f.token for f in self.store.for_station("CDF")], [TOKEN])

    def test_other_follow_replaced_during_send_not_pushed(self):
        same_board = train(std="08:12", dest="Cardiff Central", sid="NEW")
        self.follow(TOKEN)
        self.follow(TOKEN2)
        self.push.hook = lambda: self.store.upsert(TOKEN2, "sandbox", same_board, {"platform": "1"}, T0 + 5)
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        self.poller.tick()
        self.assertEqual([s[0] for s in self.push.sent], [TOKEN])
        f = next(f for f in self.store.for_station("CDF") if f.token == TOKEN2)
        self.assertEqual((f.env, f.train, f.last, f.missing), ("sandbox", same_board, {"platform": "1"}, 0))

    def test_replaced_during_ok_send_untouched(self):
        other = train(crs="NWP", std="09:00", dest="Swansea")
        self.push.hook = lambda: self.store.upsert(TOKEN, "sandbox", other, {"platform": "1"}, T0 + 5)
        self.follow()
        self.boards.set("CDF", dep(platform="5", etd="Cancelled", cancelled=True))
        self.poller.tick()
        self.assertEqual(len(self.push.sent), 1)
        f = self.only("NWP")
        self.assertEqual((f.env, f.train, f.last, f.started, f.missing, f.cancelled_at),
                         ("sandbox", other, {"platform": "1"}, T0 + 5, 0, None))

    def test_push_raises_counts_as_error_and_others_continue(self):
        import io
        from platform_api.follow import Poller

        class Flaky(Push):
            def send(self, token, *a):
                super().send(token, *a)
                if token == TOKEN:
                    raise RuntimeError("secret " + token)
                return "ok"

        log = io.StringIO()
        push = Flaky()
        p = Poller(self.store, self.boards, push, clock=self.clock, log=log)
        self.follow(TOKEN)
        self.follow(TOKEN2)
        self.boards.set("CDF", dep(platform="5", etd="On time"))
        p.tick()
        self.assertEqual([s[0] for s in push.sent], [TOKEN, TOKEN2])
        self.assertEqual({f.token: f.last["platform"] for f in self.store.for_station("CDF")},
                         {TOKEN: "5", TOKEN2: "5"})
        self.assertNotIn(TOKEN, log.getvalue())

    def test_malformed_board_does_not_stop_other_station(self):
        import io
        from platform_api.follow import Poller
        log = io.StringIO()
        p = Poller(self.store, self.boards, self.push, clock=self.clock, log=log)
        self.follow(TOKEN)
        self.follow(TOKEN2, t=train(crs="NWP"))
        self.boards.boards["CDF"] = {"crs": "CDF", "services": [None, 7]}
        self.boards.set("NWP", dep(platform="5", etd="On time"))
        p.tick()
        self.assertEqual([s[0] for s in self.push.sent], [TOKEN2])
        self.assertEqual(len(self.store), 2)
        self.assertEqual(log.getvalue(), "follow poller: AttributeError\n")
        self.assertNotIn(TOKEN, log.getvalue())

    def test_follow_posted_during_fetch_waits_for_next_tick(self):
        # The POST read a newer board (platform 5) than the one being fetched (platform 3).
        self.follow(TOKEN)
        old_fetch = self.boards.__call__

        def fetch(crs):
            self.follow(TOKEN2, baseline=dep(platform="5", etd="On time"))
            return old_fetch(crs)

        from platform_api.follow import Poller
        p = Poller(self.store, fetch, self.push, clock=self.clock)
        self.boards.set("CDF", dep(platform="3", etd="On time"))
        p.tick()
        self.assertEqual(self.push.sent, [])
        f = next(f for f in self.store.for_station("CDF") if f.token == TOKEN2)
        self.assertEqual(f.last["platform"], "5")

    def test_run_keeps_cadence_when_tick_is_slow(self):
        from platform_api.follow import Poller
        waits = []

        class FakeStop:
            def is_set(self):
                return len(waits) >= 3

            def wait(self, t):
                waits.append(t)
                clock.t += t

        clock = Clock()
        p = Poller(self.store, self.boards, self.push, clock=clock)
        durations = iter([12.0, 0.0, 45.0])

        def slow_tick():
            clock.t += next(durations)

        p.tick = slow_tick
        p.run(FakeStop(), every=30.0)
        self.assertEqual(waits, [18.0, 30.0, 0.0])

    def test_run_survives_tick_errors_and_stops(self):
        import threading
        stop = threading.Event()
        calls = []

        def bad_tick():
            calls.append(1)
            if len(calls) >= 3:
                stop.set()
            raise ValueError("boom")

        import io
        from platform_api.follow import Poller
        log = io.StringIO()
        p = Poller(self.store, self.boards, self.push, clock=self.clock, log=log)
        p.tick = bad_tick
        p.run(stop, every=0.001)
        self.assertEqual(len(calls), 3)
        self.assertEqual(log.getvalue(), "follow poller: ValueError\n" * 3)


if __name__ == "__main__":
    unittest.main()
