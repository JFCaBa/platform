import unittest

from platform_api.slices import NoSlice, board_in_slices


class Broken(Exception):
    pass


class Limited(Exception):
    pass


def darwin(trains, bad, calls=None):
    """Fake Darwin: `trains` = {minute: serviceID}; any window holding a minute in `bad` fails."""
    def get(o, w, left):
        if calls is not None:
            calls.append((o, w))
        if any(o <= m <= o + w for m in bad):
            raise Broken()
        ids = [sid for m, sid in sorted(trains.items()) if o <= m <= o + w]
        return {"locationName": "London Kings Cross", "generatedAt": "x",
                "trainServices": [{"serviceID": s} for s in ids]}
    return get


broken = lambda e: isinstance(e, Broken)


class SlicesTest(unittest.TestCase):
    def test_skips_only_the_broken_train(self):
        trains = {m: f"S{m}" for m in range(0, 120, 3)}
        raw, dropped = board_in_slices(darwin(trains, bad={6, 36}), 0, 120, 150, 9, broken)
        ids = [s["serviceID"] for s in raw["trainServices"]]
        self.assertNotIn("S6", ids)
        self.assertNotIn("S36", ids)
        self.assertEqual(len(ids), len(set(ids)), "edge trains once")
        self.assertEqual(ids, sorted(ids, key=lambda s: int(s[1:])), "time order")
        self.assertEqual(len(ids), len(trains) - 2)
        self.assertLessEqual(dropped, 8)
        self.assertEqual(raw["locationName"], "London Kings Cross")

    def test_rows_cap(self):
        trains = {m: f"S{m}" for m in range(120)}
        raw, _ = board_in_slices(darwin(trains, bad={50}), 0, 120, 50, 9, broken)
        self.assertEqual(len(raw["trainServices"]), 50)

    def test_later_page_stays_within_darwin_offsets(self):
        calls = []
        _, dropped = board_in_slices(darwin({}, bad=set(), calls=calls), 119, 120, 150, 9, broken)
        self.assertTrue(all(o <= 119 for o, _ in calls), calls)
        self.assertEqual(dropped, 110, "the minutes it cannot ask for count as dropped")

    def test_never_asks_under_two_minutes(self):
        calls = []
        board_in_slices(darwin({m: f"S{m}" for m in range(0, 120, 3)}, bad={6}, calls=calls), 0, 120, 150, 9, broken)
        self.assertTrue(all(w >= 2 for _, w in calls), calls)

    def test_nothing_answers(self):
        with self.assertRaises(NoSlice):
            board_in_slices(darwin({}, bad=set(range(200))), 0, 120, 50, 9, broken)

    def test_other_errors_raise(self):
        def get(o, w, left):
            raise Limited()
        with self.assertRaises(Limited):
            board_in_slices(get, 0, 120, 50, 9, broken)

    def test_budget(self):
        t = [0.0]
        def get(o, w, left):
            t[0] += 5
            raise Broken()
        with self.assertRaises(NoSlice):
            board_in_slices(get, 0, 120, 50, 9, broken, clock=lambda: t[0])
