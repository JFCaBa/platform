import http.client
import io
import json
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from platform_api import server as srv  # noqa: E402

FIX = Path(__file__).parent / "fixtures"
KGX = (FIX / "darwin_kgx.json").read_bytes()


class FakeDarwin:
    """Darwin stand-in. mode: ok | error | sleep | drip | headerdrip | slow | null | badservice."""

    def __init__(self):
        self.mode = "ok"
        self.requests = 0
        self.inflight = 0
        self.max_inflight = 0
        self.keys = []
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
                try:
                    if fake.mode == "error":
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
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(KGX)))
                        self.end_headers()
                        self.wfile.write(KGX)
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
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/LDBWS/api/20220120/GetDepartureBoard"


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.darwin = FakeDarwin()
        self.log = io.StringIO()
        self.api = srv.make_server("127.0.0.1", 0, darwin_url=self.darwin.url, api_key="test-key",
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

    def test_concurrency_limit_503(self):
        self.darwin.mode = "slow"
        results = []

        def call():
            results.append(self.get("/departures/KGX")[0])

        threads = [threading.Thread(target=call) for _ in range(9)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertIn(503, results)
        self.assertEqual(results.count(200) + results.count(503), 9)
        self.assertLessEqual(self.darwin.max_inflight, 8)

    def test_no_client_ip_in_logs(self):
        self.get("/departures/KGX")
        self.get("/nope")
        out = self.log.getvalue()
        self.assertIn("/departures/KGX 200", out)
        self.assertNotIn("127.0.0.1", out)

    def test_health_200(self):
        status, _, body = self.get("/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"ok": True})

    def test_other_paths_404(self):
        self.assertEqual(self.get("/")[0], 404)
        self.assertEqual(self.get("/departures/")[0], 404)


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
            self.assertEqual(srv.main(env={"DARWIN_API_KEY": "k", "PORT": "9999"}), 0)
        finally:
            srv.make_server, srv.load_stations = orig_make, orig_load
        self.assertEqual((seen["host"], seen["port"]), ("0.0.0.0", 8510))
        self.assertEqual(seen["darwin_url"], srv.DARWIN_URL)
        self.assertEqual(seen["api_key"], "k")

    def test_missing_key_exits_1(self):
        self.assertEqual(srv.main(env={}), 1)


if __name__ == "__main__":
    unittest.main()
