import contextlib
import http.client
import io
import json
import socket
import struct
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api import server as srv  # noqa: E402
from platform_api.follow import FollowStore, Poller  # noqa: E402

FIX = Path(__file__).parent / "fixtures"
KGX = (FIX / "darwin_kgx.json").read_bytes()
SERVICE = (FIX / "darwin_service.json").read_bytes()


class FakeDarwin:
    """Darwin stand-in. mode: ok | error | sleep | drip | headerdrip | slow | null | badservice."""

    def __init__(self):
        self.mode = "ok"
        self.board = KGX  # bytes served for GetDepartureBoard
        self.requests = 0
        self.inflight = 0
        self.max_inflight = 0
        self.keys = []
        self.paths = []
        self.lock = threading.Lock()
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                with fake.lock:
                    fake.requests += 1
                    fake.inflight += 1
                    fake.max_inflight = max(fake.max_inflight, fake.inflight)
                    fake.keys.append(self.headers.get("x-apikey"))
                    fake.paths.append(self.path)
                try:
                    if fake.mode == "429":
                        self.send_response(429)
                        self.end_headers()
                    elif fake.mode == "error":
                        self.send_response(500)
                        self.end_headers()
                    elif fake.mode == "sleep":
                        time.sleep(15)
                    elif fake.mode == "headerdrip":
                        self.wfile.write(b"HTTP/1.1 200 OK\r\n")
                        for i in range(30):
                            self.wfile.write(f"X-Pad-{i}: 1\r\n".encode())
                            self.wfile.flush()
                            time.sleep(0.5)
                    elif fake.mode in ("null", "badservice"):
                        body = b"null" if fake.mode == "null" else b'{"trainServices":[null]}'
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                    elif fake.mode == "drip":
                        self.send_response(200)
                        self.send_header("Content-Length", "100")
                        self.end_headers()
                        for _ in range(100):
                            self.wfile.write(b" ")
                            self.wfile.flush()
                            time.sleep(1)
                    else:
                        if fake.mode == "slow":
                            time.sleep(1.5)
                        if fake.mode == "badid" and "GetServiceDetails" in self.path:
                            self.send_response(400)
                            self.end_headers()
                            return
                        body = SERVICE if "GetServiceDetails" in self.path else fake.board
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                except OSError:
                    pass
                finally:
                    with fake.lock:
                        fake.inflight -= 1

        class S(ThreadingHTTPServer):
            daemon_threads = True
            request_queue_size = 64

        self.httpd = S(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{self.httpd.server_address[1]}/LDBWS/api/20220120"
        self.url = f"{base}/GetDepartureBoard"
        self.service_url = f"{base}/GetServiceDetails"


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.darwin = FakeDarwin()
        self.log = io.StringIO()
        self.api = srv.make_server("127.0.0.1", 0, darwin_url=self.darwin.url, api_key="test-key",
                                   service_url=self.darwin.service_url, service_key="service-key",
                                   stations={"KGX", "CLJ", "BHM"}, attribution="Data: National Rail",
                                   log=self.log)
        threading.Thread(target=self.api.serve_forever, daemon=True).start()
        self.port = self.api.server_address[1]

    def tearDown(self):
        self.api.shutdown()
        self.api.server_close()
        self.darwin.httpd.shutdown()
        self.darwin.httpd.server_close()

    def get(self, path, timeout=30):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        c.request("GET", path)
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, dict((k.lower(), v) for k, v in r.getheaders()), body

    def test_invalid_crs_400(self):
        for crs in ["kgx", "KG", "KGXX", "../x", "K%20X"]:
            status, _, body = self.get(f"/departures/{crs}")
            self.assertEqual(status, 400, crs)
            self.assertEqual(json.loads(body), {"error": "bad crs"})
        self.assertEqual(self.darwin.requests, 0)

    def test_ok_has_cache_control(self):
        status, headers, body = self.get("/departures/KGX")
        self.assertEqual(status, 200)
        self.assertEqual(headers["cache-control"], "max-age=30")
        self.assertTrue(headers["content-type"].startswith("application/json"))
        board = json.loads(body)
        self.assertEqual(board["crs"], "KGX")
        self.assertEqual(board["attribution"], "Data: National Rail")
        self.assertEqual(len(board["services"]), 20)
        self.assertEqual(self.darwin.keys, ["test-key"])

    def test_darwin_error_502(self):
        self.darwin.mode = "error"
        status, headers, body = self.get("/departures/KGX")
        self.assertEqual(status, 502)
        self.assertEqual(json.loads(body), {"error": "upstream"})
        self.assertNotIn("max-age=30", headers.get("cache-control", ""))

    def test_darwin_timeout_502_within_10s(self):
        for mode in ["sleep", "drip", "headerdrip"]:
            self.darwin.mode = mode
            t0 = time.monotonic()
            status, _, body = self.get("/departures/KGX")
            self.assertEqual(status, 502, mode)
            self.assertLess(time.monotonic() - t0, 10, mode)

    def test_malformed_darwin_body_502(self):
        for mode in ["null", "badservice"]:
            self.darwin.mode = mode
            status, _, body = self.get("/departures/KGX")
            self.assertEqual(status, 502, mode)
            self.assertEqual(json.loads(body), {"error": "upstream"})

    def test_upstream_failure_is_logged_without_ip(self):
        self.darwin.mode = "error"
        self.get("/departures/KGX")
        out = self.log.getvalue()
        self.assertIn("upstream KGX 500", out)
        self.assertNotIn("127.0.0.1", out)

    def test_unknown_crs_404_without_upstream_call(self):
        status, _, body = self.get("/departures/ZZZ")
        self.assertEqual(status, 404)
        self.assertEqual(json.loads(body), {"error": "unknown station"})
        self.assertEqual(self.darwin.requests, 0)

    def test_darwin_429_passed_through(self):
        self.darwin.mode = "429"
        status, _, body = self.get("/departures/KGX")
        self.assertEqual(status, 429)
        self.assertEqual(json.loads(body), {"error": "rate limited"})

    def test_asks_darwin_for_50_rows(self):
        self.get("/departures/KGX")
        self.assertIn("numRows=50", self.darwin.paths[0])

    def test_base_board_has_offset_0_and_complete(self):
        status, _, body = self.get("/departures/KGX")
        b = json.loads(body)
        self.assertEqual((b["timeOffset"], b["complete"]), (0, True))  # fixture has 20 < 50 rows

    def test_later_page_asks_darwin_with_offset_and_150_rows(self):
        status, headers, body = self.get("/departures/KGX/45")
        self.assertEqual(status, 200)
        self.assertEqual(headers["cache-control"], "max-age=60")
        path = self.darwin.paths[0]
        self.assertIn("/KGX?", path)
        self.assertIn("numRows=150", path)
        self.assertIn("timeWindow=120", path)
        self.assertIn("timeOffset=45", path)
        b = json.loads(body)
        self.assertEqual((b["timeOffset"], b["complete"], b["window"]), (45, True, 75))
        self.assertEqual(len(b["services"]), 20)

    def test_later_page_offsets_1_to_119(self):
        for off in ["1", "9", "15", "99", "119"]:
            self.assertEqual(self.get(f"/departures/KGX/{off}")[0], 200, off)

    def test_bad_offset_400(self):
        for off in ["0", "120", "07", "-5", "abc", "1.5", "", "200"]:
            status, _, body = self.get(f"/departures/KGX/{off}")
            self.assertEqual(status, 400, off)
            self.assertEqual(json.loads(body), {"error": "bad offset"}, off)
        self.assertEqual(self.get("/departures/KGX/30/1")[0], 400)
        self.assertEqual(self.darwin.requests, 0)

    def test_later_page_bad_or_unknown_crs(self):
        self.assertEqual(self.get("/departures/kgx/30")[0], 400)
        self.assertEqual(self.get("/departures/ZZZ/30")[0], 404)
        self.assertEqual(self.darwin.requests, 0)

    def test_later_page_429_passed_through(self):
        self.darwin.mode = "429"
        self.assertEqual(self.get("/departures/KGX/30")[0], 429)

    def test_concurrency_limit_502(self):
        self.darwin.mode = "slow"
        results = []

        def call():
            results.append(self.get("/departures/KGX")[0])

        threads = [threading.Thread(target=call) for _ in range(9)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertIn(502, results)  # busy: nginx caches 502 for 5 s / serves stale; never a 5-min client back-off
        self.assertEqual(results.count(200) + results.count(502), 9)
        self.assertLessEqual(self.darwin.max_inflight, 8)

    def test_successful_requests_are_not_logged(self):
        self.get("/departures/KGX")
        self.get("/health")
        self.get("/nope")
        self.assertEqual(self.log.getvalue(), "")

    def test_service_stops(self):
        status, headers, body = self.get("/service/10741504KNGX____")
        self.assertEqual(status, 200)
        self.assertEqual(headers["cache-control"], "max-age=30")
        self.assertEqual(self.darwin.keys, ["service-key"])
        self.assertTrue(self.darwin.paths[0].endswith("/GetServiceDetails/10741504KNGX____"))
        svc = json.loads(body)
        self.assertEqual(svc["attribution"], "Data: National Rail")
        stops = svc["portions"][0]
        self.assertEqual(len(stops), 17)
        self.assertEqual(stops[0], {"name": "Finsbury Park", "crs": "FPK", "st": "14:41", "et": "On time",
                                    "cancelled": False})
        self.assertEqual(stops[-1]["name"], "Cambridge")

    def test_service_has_position(self):
        svc = json.loads(self.get("/service/10741504KNGX____")[2])
        self.assertIn("position", svc)

    def test_service_details_cached_30s(self):
        self.assertEqual(self.get("/service/10741504KNGX____")[0], 200)
        self.assertEqual(self.get("/service/10741504KNGX____")[0], 200)
        self.assertEqual(self.darwin.requests, 1)
        self.assertEqual(self.api.fetch_position("10741504KNGX____"), json.loads(self.get("/service/10741504KNGX____")[2])["position"])
        self.assertEqual(self.darwin.requests, 1)  # the poller's lookup shares the cache

    def test_service_cache_expiry(self):
        now = [100.0]
        cache = srv.ServiceCache(ttl=30, clock=lambda: now[0])
        calls = []
        def load():
            calls.append(1)
            return {"n": len(calls)}
        self.assertEqual(cache.get("A", load), {"n": 1})
        now[0] += 29
        self.assertEqual(cache.get("A", load), {"n": 1})
        now[0] += 2
        self.assertEqual(cache.get("A", load), {"n": 2})
        self.assertEqual(cache.get("B", load), {"n": 3})

    def test_service_cache_does_not_keep_errors(self):
        cache = srv.ServiceCache(ttl=30, clock=lambda: 0.0)
        def boom():
            raise ValueError("x")
        with self.assertRaises(ValueError):
            cache.get("A", boom)
        self.assertEqual(cache.get("A", lambda: {"ok": 1}), {"ok": 1})

    def test_bad_service_id_400_without_upstream_call(self):
        for sid in ["x", "a/b", "../etc", "%2F", "A" * 41]:
            status, _, body = self.get(f"/service/{sid}")
            self.assertEqual(status, 400, sid)
            self.assertEqual(json.loads(body), {"error": "bad service id"})
        self.assertEqual(self.darwin.requests, 0)

    def test_unknown_service_404(self):
        self.darwin.mode = "badid"
        status, _, body = self.get("/service/10741504KNGX____")
        self.assertEqual(status, 404)
        self.assertEqual(json.loads(body), {"error": "unknown service"})

    def test_service_upstream_errors(self):
        self.darwin.mode = "429"
        self.assertEqual(self.get("/service/10741504KNGX____")[0], 429)
        self.darwin.mode = "error"
        self.assertEqual(self.get("/service/10741504KNGX____")[0], 502)
        self.assertIn("upstream service 500", self.log.getvalue())

    def test_stops_cannot_starve_the_boards(self):
        self.darwin.mode = "slow"
        results, boards = [], []

        def stops():
            results.append(self.get("/service/10741504KNGX____")[0])

        threads = [threading.Thread(target=stops) for _ in range(8)]
        for t in threads:
            t.start()
        time.sleep(0.3)  # the stop lookups now hold every slot they may have
        boards.append(self.get("/departures/KGX")[0])
        for t in threads:
            t.join()
        self.assertEqual(boards, [200])
        self.assertIn(502, results)

    def test_service_without_key_503(self):
        api = srv.make_server("127.0.0.1", 0, darwin_url=self.darwin.url, api_key="k", stations={"KGX"},
                              attribution="x", log=self.log)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", api.server_address[1], timeout=10)
            c.request("GET", "/service/10741504KNGX____")
            r = c.getresponse()
            self.assertEqual(r.status, 503)
            self.assertEqual(json.loads(r.read()), {"error": "unavailable"})
        finally:
            api.shutdown()
            api.server_close()
        self.assertEqual(self.darwin.requests, 0)

    def test_health_200(self):
        status, _, body = self.get("/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"ok": True})

    def test_other_paths_404(self):
        self.assertEqual(self.get("/")[0], 404)
        self.assertEqual(self.get("/departures/")[0], 404)


TOKEN = "ab" * 32
NCL = {"crs": "KGX", "std": "14:33", "destination": "Newcastle", "serviceId": "10740404KNGX____"}
HOUR_MS = 3600 * 1000


def kgx_with(service_id, **fields):
    """The KGX fixture with one raw Darwin service changed."""
    data = json.loads(KGX)
    for s in data["trainServices"]:
        if s["serviceID"] == service_id:
            s.update(fields)
    return json.dumps(data).encode()


class FakePush:
    def __init__(self, result="ok"):
        self.sent = []
        self.result = result

    def send(self, token, env, title, body):
        self.sent.append((token, env, title, body))
        return self.result


class FollowTest(unittest.TestCase):
    def setUp(self):
        self.darwin = FakeDarwin()
        self.log = io.StringIO()
        self.now = 1_800_000_000.0
        self.store = FollowStore()
        self.push = FakePush()
        self.api = self.serve(follows=self.store, push=self.push)

    def serve(self, **kw):
        api = srv.make_server("127.0.0.1", 0, darwin_url=self.darwin.url, api_key="test-key",
                              stations={"KGX", "CLJ", "BHM"}, attribution="Data: National Rail",
                              log=self.log, clock=lambda: self.now, **kw)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        self.addCleanup(api.server_close)
        self.addCleanup(api.shutdown)
        return api

    def tearDown(self):
        self.darwin.httpd.shutdown()
        self.darwin.httpd.server_close()

    def request(self, method, body, api=None, raw=None, headers=None):
        api = api or self.api
        data = raw if raw is not None else json.dumps(body).encode()
        c = http.client.HTTPConnection("127.0.0.1", api.server_address[1], timeout=30)
        c.request(method, "/follow", body=data, headers=headers or {})
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def body(self, **over):
        b = {"token": TOKEN, "env": "sandbox", **NCL, "startedAt": int(self.now * 1000)}
        b.update(over)
        return {k: v for k, v in b.items() if v is not None}

    def poller(self):
        return Poller(self.store, self.api.fetch_board, self.push, clock=lambda: self.now, log=self.log)

    def test_follow_ok_then_poll_alerts(self):
        self.assertEqual(self.request("POST", self.body()), (200, {"ok": True}))
        self.assertEqual(self.darwin.requests, 1)
        (f,) = self.store.for_station("KGX")
        self.assertEqual((f.token, f.env, f.train, f.started), (TOKEN, "sandbox", NCL, self.now))
        self.poller().tick()  # unchanged board: the POST reading is the baseline
        self.assertEqual(self.push.sent, [])
        self.darwin.board = kgx_with("10740404KNGX____", etd="14:40", platform="4")
        self.now += 30
        self.poller().tick()
        self.assertEqual(self.push.sent, [(TOKEN, "sandbox", "14:33 to Newcastle",
                                           "Platform 4\nNow expected 14:40")])

    def test_follow_with_activity_token(self):
        act = "EF" * 32
        self.assertEqual(self.request("POST", self.body(activityToken=act))[0], 200)
        (f,) = self.store.for_station("KGX")
        self.assertEqual(f.activity, act.lower())

    def test_late_activity_token_no_darwin_call_keeps_start(self):
        self.assertEqual(self.request("POST", self.body())[0], 200)
        self.now += 60
        self.assertEqual(self.request("POST", self.body(activityToken="ef" * 32)), (200, {"ok": True}))
        self.assertEqual(self.darwin.requests, 1)
        (f,) = self.store.for_station("KGX")
        self.assertEqual((f.activity, f.started), ("ef" * 32, self.now - 60))

    def test_follow_without_service_id_stores_no_service_id(self):
        self.assertEqual(self.request("POST", self.body(serviceId=None))[0], 200)
        (f,) = self.store.for_station("KGX")
        self.assertEqual(f.train, {"crs": "KGX", "std": "14:33", "destination": "Newcastle"})

    def test_follow_train_not_on_board_410(self):
        status, body = self.request("POST", self.body(std="09:00", serviceId=None))
        self.assertEqual((status, body), (410, {"error": "gone"}))
        self.assertEqual(len(self.store), 0)

    def test_follow_validation_400(self):
        cases = {
            "short token": self.body(token="ab" * 31),
            "non-hex": self.body(token="zz" * 32),
            "201 chars": self.body(token="a" * 201),
            "token not str": self.body(token=12),
            "bad env": self.body(env="prod"),
            "std 8:12": self.body(std="8:12"),
            "unknown CRS": self.body(crs="ZZZ"),
            "lowercase CRS": self.body(crs="kgx"),
            "long destination": self.body(destination="x" * 101),
            "empty destination": self.body(destination=""),
            "bad serviceId": self.body(serviceId="a/b"),
            "missing startedAt": {k: v for k, v in self.body().items() if k != "startedAt"},
            "float startedAt": self.body(startedAt=1.5),
            "bool startedAt": self.body(startedAt=True),
            "str startedAt": self.body(startedAt="1800000000000"),
            "huge startedAt": self.body(startedAt=10 ** 400),
            "not an object": [1, 2],
            "short activityToken": self.body(activityToken="ab" * 31),
            "activityToken not str": self.body(activityToken=5),
        }
        for name, body in cases.items():
            with self.subTest(name):
                self.assertEqual(self.request("POST", body), (400, {"error": "bad request"}))
        for name, raw in {"not JSON": b"{nope", "not UTF-8": b"\xff\xfe", "deep": b"[" * 4000,
                          "5 KB body": json.dumps(self.body(pad="x" * 5000)).encode()}.items():
            with self.subTest(name):
                self.assertEqual(self.request("POST", None, raw=raw), (400, {"error": "bad request"}))
        self.assertEqual(self.darwin.requests, 0)
        self.assertEqual(len(self.store), 0)

    def test_missing_or_bad_content_length_400(self):
        for value in [None, "abc", "-1"]:
            with self.subTest(value):
                c = http.client.HTTPConnection("127.0.0.1", self.api.server_address[1], timeout=30)
                c.putrequest("POST", "/follow")
                if value is not None:
                    c.putheader("Content-Length", value)
                c.endheaders()
                r = c.getresponse()
                self.assertEqual((r.status, json.loads(r.read())), (400, {"error": "bad request"}))
                c.close()

    def test_refollow_same_train_no_darwin_call(self):
        self.assertEqual(self.request("POST", self.body())[0], 200)
        self.now += 60
        self.assertEqual(self.request("POST", self.body(startedAt=int(self.now * 1000))),
                         (200, {"ok": True}))
        self.assertEqual(self.darwin.requests, 1)
        (f,) = self.store.for_station("KGX")
        self.assertEqual(f.started, self.now - 60)  # the original start is kept

    def test_refollow_after_restart_keeps_original_start(self):
        started_ms = int((self.now - (2 * 3600 + 50 * 60)) * 1000)
        self.assertEqual(self.request("POST", self.body(startedAt=started_ms))[0], 200)
        (f,) = self.store.for_station("KGX")
        self.assertEqual(f.started, started_ms / 1000)
        self.now += 9 * 60
        self.poller().tick()
        self.assertEqual(len(self.store), 1)
        self.now += 60
        self.poller().tick()
        self.assertEqual(len(self.store), 0)

    def test_started_in_future_is_clamped_to_now(self):
        self.assertEqual(self.request("POST", self.body(startedAt=int((self.now + 600) * 1000)))[0], 200)
        (f,) = self.store.for_station("KGX")
        self.assertEqual(f.started, self.now)

    def test_started_over_3h_ago_410(self):
        for ago_ms in [3 * HOUR_MS, 3 * HOUR_MS + 1, 10 * HOUR_MS]:
            with self.subTest(ago_ms):
                status, body = self.request("POST", self.body(startedAt=int(self.now * 1000) - ago_ms))
                self.assertEqual((status, body), (410, {"error": "gone"}))
        self.assertEqual(self.darwin.requests, 0)
        self.assertEqual(len(self.store), 0)

    def test_uppercase_token_is_same_follow(self):
        self.assertEqual(self.request("POST", self.body(token=TOKEN.upper()))[0], 200)
        (f,) = self.store.for_station("KGX")
        self.assertEqual(f.token, TOKEN)
        self.assertEqual(self.request("POST", self.body())[0], 200)
        self.assertEqual(self.darwin.requests, 1)  # same follow: no new reading
        self.assertEqual(self.request("DELETE", {"token": TOKEN})[0], 204)
        self.assertEqual(len(self.store), 0)

    def test_follow_without_apns_503(self):
        api = self.serve()
        for method in ["POST", "DELETE"]:
            with self.subTest(method):
                self.assertEqual(self.request(method, self.body(), api=api), (503, {"error": "unavailable"}))
        self.assertEqual(self.darwin.requests, 0)

    def test_delete_with_body_204(self):
        self.assertEqual(self.request("POST", self.body())[0], 200)
        self.assertEqual(self.request("DELETE", {"token": TOKEN.upper()}), (204, None))
        self.assertEqual(len(self.store), 0)
        self.assertEqual(self.request("DELETE", {"token": TOKEN}), (204, None))  # not there: still 204
        for bad in [{"token": "nope"}, {}, [TOKEN]]:
            with self.subTest(bad):
                self.assertEqual(self.request("DELETE", bad), (400, {"error": "bad request"}))
        self.assertEqual(self.request("DELETE", None, raw=b"{"), (400, {"error": "bad request"}))

    def test_other_methods_and_paths(self):
        c = http.client.HTTPConnection("127.0.0.1", self.api.server_address[1], timeout=30)
        c.request("POST", "/follow/x", body=b"{}")
        r = c.getresponse()
        self.assertEqual(r.status, 404)
        r.read()
        c.close()

    def test_follow_does_not_use_board_slots(self):
        held = 0
        while self.api.slots.acquire(blocking=False):
            held += 1
        try:
            self.assertEqual(self.request("POST", self.body())[0], 200)
        finally:
            for _ in range(held):
                self.api.slots.release()
        self.assertEqual(held, 8)

    def test_poll_slots_full_503_after_wait(self):
        api = self.serve(follows=FollowStore(), push=self.push, follow_wait_s=0.5)
        self.assertTrue(api.poll_slots.acquire(blocking=False))
        self.assertTrue(api.poll_slots.acquire(blocking=False))
        self.assertFalse(api.poll_slots.acquire(blocking=False))  # pool of 2
        try:
            t0 = time.monotonic()
            self.assertEqual(self.request("POST", self.body(), api=api), (503, {"error": "busy"}))
            self.assertGreaterEqual(time.monotonic() - t0, 0.5)
        finally:
            api.poll_slots.release()
            api.poll_slots.release()
        self.assertEqual(self.darwin.requests, 0)
        self.assertEqual(self.request("POST", self.body(), api=api)[0], 200)

    def test_poller_skips_station_when_poll_slots_stay_full(self):
        store = FollowStore()
        api = self.serve(follows=store, push=self.push, poll_wait_s=0.3)
        self.assertEqual(self.request("POST", self.body(), api=api)[0], 200)  # KGX
        store.upsert("cd" * 32, "sandbox", {"crs": "CLJ", "std": "09:00", "destination": "Brighton"},
                     {}, self.now)  # CLJ sorts first
        self.darwin.board = kgx_with("10740404KNGX____", etd="14:40", platform="4")
        requests = self.darwin.requests
        self.assertTrue(api.poll_slots.acquire(blocking=False))
        self.assertTrue(api.poll_slots.acquire(blocking=False))
        threading.Timer(0.45, api.poll_slots.release).start()  # frees one slot after CLJ gave up
        try:
            t0 = time.monotonic()
            Poller(store, api.fetch_board, self.push, clock=lambda: self.now, log=self.log).tick()
            elapsed = time.monotonic() - t0
        finally:
            api.poll_slots.release()
        self.assertGreaterEqual(elapsed, 0.3)
        self.assertLess(elapsed, 5)
        self.assertEqual(self.darwin.requests, requests + 1)  # KGX only
        self.assertEqual([s[0] for s in self.push.sent], [TOKEN])
        self.assertEqual(len(store), 2)
        self.assertEqual(self.log.getvalue(), "")

    def test_poller_poll_wait_defaults_to_ten_seconds(self):
        import inspect
        self.assertEqual(inspect.signature(srv.make_server).parameters["poll_wait_s"].default, 10.0)

    def test_follow_caps_503(self):
        api = self.serve(follows=FollowStore(max_follows=1), push=self.push)
        self.assertEqual(self.request("POST", self.body(), api=api)[0], 200)
        self.assertEqual(self.request("POST", self.body(token="cd" * 32), api=api), (503, {"error": "busy"}))

    def test_follow_upstream_errors(self):
        for mode, expected in [("error", (502, {"error": "upstream"})), ("null", (502, {"error": "upstream"})),
                               ("429", (429, {"error": "rate limited"}))]:
            with self.subTest(mode):
                self.darwin.mode = mode
                self.assertEqual(self.request("POST", self.body()), expected)
        self.assertEqual(len(self.store), 0)
        self.assertEqual(self.log.getvalue(), "")

    def test_delete_during_inflight_post_wins_409(self):
        self.darwin.mode = "slow"  # 1.5 s board reading
        result = []
        t = threading.Thread(target=lambda: result.append(self.request("POST", self.body())))
        t.start()
        deadline = time.monotonic() + 5
        while self.darwin.requests == 0 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.darwin.requests, 1)  # POST is now waiting on Darwin
        self.assertEqual(self.request("DELETE", {"token": TOKEN})[0], 204)
        t.join()
        self.assertEqual(result, [(409, {"error": "conflict"})])
        self.assertEqual(len(self.store), 0)

    def test_refollow_same_train_other_env_refreshes_env(self):
        self.assertEqual(self.request("POST", self.body())[0], 200)
        (before,) = self.store.for_station("KGX")
        self.now += 60
        self.assertEqual(self.request("POST", self.body(env="production")), (200, {"ok": True}))
        self.assertEqual(self.darwin.requests, 2)  # normal path: board read again
        (f,) = self.store.for_station("KGX")
        self.assertEqual(f.env, "production")
        self.assertEqual((f.started, f.last), (before.started, before.last))
        self.assertNotEqual(f.gen, before.gen)  # a send in flight to the old env can't touch it

    def raw(self, data: bytes, reset=False) -> bytes:
        sock = socket.create_connection(("127.0.0.1", self.api.server_address[1]), timeout=10)
        try:
            sock.sendall(data)
            if reset:  # RST instead of FIN
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                return b""
            out = b""
            while chunk := sock.recv(65536):
                out += chunk
            return out
        finally:
            sock.close()

    def test_rejected_body_is_never_parsed_as_next_request(self):
        inner = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
        for proto in [b"HTTP/1.0", b"HTTP/1.1"]:
            with self.subTest(proto):
                body = inner + b" " * 5000
                out = self.raw(b"POST /follow " + proto + b"\r\nHost: x\r\nContent-Length: "
                               + str(len(body)).encode() + b"\r\n\r\n" + body)
                self.assertEqual(out.count(b"HTTP/1."), 1, out)
                self.assertIn(b" 400 ", out.split(b"\r\n")[0])

    def test_client_reset_mid_body_logs_no_address(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.raw(b"POST /follow HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n{\"tok", reset=True)
            time.sleep(0.5)  # let the handler thread see the reset
        self.assertNotIn("127.0.0.1", err.getvalue())
        self.assertEqual(self.log.getvalue(), "")
        self.assertEqual(self.request("POST", self.body())[0], 200)  # server still serving

    def test_handle_error_logs_class_name_only(self):
        try:
            raise ValueError("secret " + TOKEN)
        except ValueError:
            self.api.handle_error(None, ("127.0.0.1", 1234))
        self.assertEqual(self.log.getvalue(), "unhandled ValueError\n")

    def test_follow_logs_nothing(self):
        self.request("POST", self.body())
        self.request("POST", self.body())
        self.request("POST", self.body(token="x"))
        self.request("DELETE", {"token": TOKEN})
        self.assertEqual(self.log.getvalue(), "")


class StationsTest(unittest.TestCase):
    def test_load_stations_falls_back_to_bundled(self):
        known = srv.load_stations("http://127.0.0.1:9/nothing.json", srv.BUNDLED_STATIONS)
        self.assertIn("KGX", known)
        self.assertGreater(len(known), 2400)

    def test_main_starts_on_8510_with_key(self):
        seen = {}

        class Dummy:
            server_address = ("0.0.0.0", 8510)
            stations = {"KGX"}

            def serve_forever(self):
                pass

        def fake_make(host, port, **kw):
            seen.update(host=host, port=port, **kw)
            return Dummy()

        orig_make, orig_load = srv.make_server, srv.load_stations
        srv.make_server, srv.load_stations = fake_make, lambda url, fb: {"KGX"}
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(srv.main(env={"DARWIN_API_KEY": "k", "PORT": "9999"}), 0)
        finally:
            srv.make_server, srv.load_stations = orig_make, orig_load
        self.assertEqual((seen["host"], seen["port"]), ("0.0.0.0", 8510))
        self.assertEqual(seen["darwin_url"], srv.DARWIN_URL)
        self.assertEqual(seen["api_key"], "k")
        self.assertIn("follow: off (APNS_* missing or invalid)\n", err.getvalue())
        self.assertNotIn("follow: on", err.getvalue())
        self.assertIsNone(seen["push"])  # no APNs secrets: /follow answers 503, no poller

    def test_main_with_apns_starts_poller(self):
        import base64
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        seen, runs, ran = {}, [], threading.Event()

        class Dummy:
            server_address = ("0.0.0.0", 8510)
            stations = {"KGX"}

            fetch_position = None

            def fetch_board(self, crs):
                return {}

            def serve_forever(self):
                pass

        class FakePoller:
            def __init__(self, store, fetch_board, push, **kw):
                runs.append((store, fetch_board, push))

            def run(self, stop, every=30.0):
                runs.append(stop)
                ran.set()

        def fake_make(host, port, **kw):
            seen.update(kw)
            return Dummy()

        orig = srv.make_server, srv.load_stations, srv.Poller
        srv.make_server, srv.load_stations, srv.Poller = fake_make, (lambda url, fb: {"KGX"}), FakePoller
        try:
            env = {"DARWIN_API_KEY": "k", "APNS_KEY": base64.b64encode(pem).decode(),
                   "APNS_KEY_ID": "KID", "APNS_TEAM_ID": "TEAM"}
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(srv.main(env=env), 0)
        finally:
            srv.make_server, srv.load_stations, srv.Poller = orig
        self.assertIn("follow: on\n", err.getvalue())
        self.assertNotIn("KID", err.getvalue())
        self.assertNotIn("TEAM", err.getvalue())
        self.assertTrue(ran.wait(5))
        self.assertIsNotNone(seen["push"])
        self.assertIsInstance(seen["follows"], FollowStore)
        store, _, push = runs[0]
        self.assertIs(store, seen["follows"])
        self.assertIs(push, seen["push"])
        self.assertIsInstance(runs[1], threading.Event)

    def test_missing_key_exits_1(self):
        self.assertEqual(srv.main(env={}), 1)


if __name__ == "__main__":
    unittest.main()
