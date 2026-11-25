import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api.stats import Hit, Tally, london_day, london_hour, parse_line  # noqa: E402

FIX = Path(__file__).parent / "fixtures"


def utc(*a) -> float:
    return datetime(*a, tzinfo=timezone.utc).timestamp()


def line(ts="1763900000.123", method="GET", uri="/departures/KGX", status="200", cache="HIT",
         ip="1.2.3.4", ua="WhatPlatform/1.5", end="|E") -> bytes:
    return f"<190>Nov 23 16:22:36 platform: {ts}|{method}|{uri}|{status}|{cache}|{ip}|{ua}{end}".encode()


# 23 Nov 2026 is GMT: London time == UTC.
D = (2026, 11, 23)
D1 = (2026, 11, 24)


def hit(ts, crs="KGX", ip="1.2.3.4", ua="WhatPlatform/1.5", kind="departures"):
    return Hit(ts, kind, crs, ip, ua)


class Keys:
    def __init__(self):
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return bytes([self.calls]) * 32


class ParseTest(unittest.TestCase):
    def test_parse_departures(self):
        self.assertEqual(parse_line(line()),
                         Hit(1763900000.123, "departures", "KGX", "1.2.3.4", "WhatPlatform/1.5"))

    def test_parse_later_page(self):
        h = parse_line(line(uri="/departures/KGX/45"))
        self.assertEqual((h.kind, h.crs), ("departures", "KGX"))

    def test_parse_service_and_follow(self):
        h = parse_line(line(uri="/service/10741504KNGX____"))
        self.assertEqual((h.kind, h.crs), ("service", None))
        h = parse_line(line(method="POST", uri="/follow", cache=""))
        self.assertEqual((h.kind, h.crs), ("follow", None))

    def test_parse_rejects(self):
        bad = [
            line(status="404"), line(status="429"), line(status="502"),
            line(method="DELETE", uri="/follow", status="204"),
            line(uri="/health"), line(method="POST", uri="/anden/follow"), line(uri="/admin"),
            b"", b"1763900000.123|GET|/departures/KGX|200|HIT|1.2.3.4|WhatPlatform/1.5|E",
            b"<190>Nov 23 16:22:36 platform: 1763900000.123|GET|/departures/KGX|200|E",
            line(ua="WhatPl", end=""),
            line(ts="abc"),
            b"<190>Nov 23 16:22:36 platform: \xff\xfe|GET|/departures/KGX|200|HIT|1.2.3.4|x|E",
        ]
        for b in bad:
            with self.subTest(b=b):
                self.assertIsNone(parse_line(b))

    def test_parse_ua_with_pipes(self):
        self.assertEqual(parse_line(line(ua="a|b c")).ua, "a|b c")

    def test_parse_real_nginx_datagram(self):
        # Built by hand from nginx's syslog header with `nohostname` ("<PRI>Mmm dd hh:mm:ss TAG: ",
        # day space-padded; src/core/ngx_syslog.c) and the Task 5 log_format (no local nginx).
        h = parse_line((FIX / "nginx_syslog.bin").read_bytes())
        self.assertEqual(h, Hit(1762160701.042, "departures", "EUS", "203.0.113.9",
                                'WhatPlatform/1.5 (iPhone; \\x22x\\x22)'))


class TallyTest(unittest.TestCase):
    def test_visitors_dedupe_and_versions(self):
        t = Tally()
        ts = utc(*D, 10)
        for _ in range(3):
            t.add(hit(ts))
        t.add(hit(ts, ip="5.6.7.8", ua="WhatPlatform/1.4"))
        t.add(hit(ts, ip="9.9.9.9", ua="curl/8"))
        [d] = t.drain(ts + 1)
        self.assertEqual(d.visitors, 2)
        self.assertEqual(d.requests, 5)
        self.assertEqual(d.versions, {"1.5": 3, "1.4": 1, "otro": 1})
        self.assertFalse(d.closed)

    def test_browsers_count_as_web_people_bots_do_not(self):
        t = Tally()
        ts = utc(*D, 10)
        t.add(hit(ts, ip="1.1.1.1", ua="Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1"))
        t.add(hit(ts, ip="1.1.1.1", ua="Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1"))
        t.add(hit(ts, ip="2.2.2.2", ua="Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"))
        t.add(hit(ts, ip="3.3.3.3", ua="Mozilla/5.0 HeadlessChrome/120"))
        t.add(hit(ts, ip="4.4.4.4", ua="curl/8"))
        [d] = t.drain(ts + 1)
        self.assertEqual(d.visitors, 1)
        self.assertEqual(d.versions, {"web": 2, "otro": 3})

    def test_hours_and_stations(self):
        t = Tally()
        t.add(hit(utc(*D, 8, 10)))
        t.add(hit(utc(*D, 8, 50)))
        t.add(hit(utc(*D, 9, 0), crs="EUS"))
        [d] = t.drain(utc(*D, 9, 1))
        self.assertEqual(d.hours, {8: 2, 9: 1})
        self.assertEqual(d.stations, {"KGX": 2, "EUS": 1})

    def test_drain_resets_counters_but_not_visitors(self):
        t = Tally()
        ts = utc(*D, 10)
        t.add(hit(ts))
        t.drain(ts + 1)
        [d] = t.drain(ts + 2)
        self.assertEqual(d.requests, 0)
        self.assertEqual(d.visitors, 1)
        self.assertEqual(t.visitors_today(), 1)

    def test_visitors_today_after_midnight_without_traffic(self):
        t = Tally()
        t.add(hit(utc(*D, 23)))
        self.assertEqual(t.visitors_today(utc(*D, 23, 30)), 1)
        self.assertEqual(t.visitors_today(utc(*D1, 0, 0, 10)), 0)  # not rolled yet: still yesterday's set

    def test_follows(self):
        t = Tally()
        t.add_follow(utc(*D, 10))
        [d] = t.drain(utc(*D, 10, 1))
        self.assertEqual(d.follows, 1)

    def test_day_close_on_drain(self):
        keys = Keys()
        t = Tally(key_factory=keys)
        t.add(hit(utc(*D, 22)))
        t.add(hit(utc(*D, 23), ip="5.6.7.8"))
        [d] = t.drain(utc(*D1, 0, 0, 30))
        self.assertEqual((d.day, d.closed, d.visitors, d.requests), ("2026-11-23", True, 2, 2))
        self.assertEqual(t.visitors_today(), 0)
        self.assertEqual(keys.calls, 2)

    def test_day_close_on_hit(self):
        t = Tally()
        t.add(hit(utc(*D, 23)))
        t.add(hit(utc(*D1, 0, 1)))
        a, b = t.drain(utc(*D1, 0, 2))
        self.assertEqual((a.day, a.closed, a.requests, a.visitors), ("2026-11-23", True, 1, 1))
        self.assertEqual((b.day, b.closed, b.requests, b.visitors), ("2026-11-24", False, 1, 1))

    def test_late_hit_dropped(self):
        t = Tally()
        t.add(hit(utc(*D, 23)))
        t.drain(utc(*D1, 0, 1))
        t.add(hit(utc(*D, 23, 59), ip="5.6.7.8"))
        t.add_follow(utc(*D, 23, 59))
        self.assertEqual(t.drain(utc(*D1, 0, 2)), [])  # nothing for the new day, D not reopened

    def test_same_ip_new_day_new_hash(self):
        t = Tally()
        t.add(hit(utc(*D, 12)))
        t.add(hit(utc(*D1, 12)))
        a, b = t.drain(utc(*D1, 13))
        self.assertEqual((a.visitors, b.visitors), (1, 1))

    def test_nothing_sensitive_kept(self):
        t = Tally()
        t.add(hit(utc(*D, 12), ua="WhatPlatform/1.5 SecretUA"))
        t.drain(utc(*D1, 0, 1))
        dump = repr(vars(t))
        self.assertNotIn("1.2.3.4", dump)
        self.assertNotIn("SecretUA", dump)

    def test_london_dst(self):
        self.assertEqual((london_day(utc(2026, 3, 29, 0, 30)), london_hour(utc(2026, 3, 29, 0, 30))),
                         ("2026-03-29", 0))
        self.assertEqual((london_day(utc(2026, 6, 1, 23, 30)), london_hour(utc(2026, 6, 1, 23, 30))),
                         ("2026-06-02", 0))


if __name__ == "__main__":
    unittest.main()
