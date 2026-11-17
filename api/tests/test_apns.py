from __future__ import annotations

import base64
import io
import json
import unittest

try:
    import httpx
    import jwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    HAVE_DEPS = True
except ImportError:  # stdlib-only interpreter
    HAVE_DEPS = False

if HAVE_DEPS:
    from platform_api.apns import Apns


@unittest.skipUnless(HAVE_DEPS, "httpx/PyJWT/cryptography not installed")
class ApnsTest(unittest.TestCase):
    def setUp(self):
        self.private = ec.generate_private_key(ec.SECP256R1())
        self.pem = self.private.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        self.now = 1_000_000.0
        self.requests = []
        self.status = 200
        self.reason = None
        self.raise_error = False

    def clock(self):
        return self.now

    def handler(self, request):
        self.requests.append(request)
        if self.raise_error:
            raise httpx.ConnectError("boom")
        content = json.dumps({"reason": self.reason}) if self.reason else b""
        return httpx.Response(self.status, content=content)

    def apns(self, pem=None):
        self.log = io.StringIO()
        return Apns(
            pem or self.pem, "KEYID12345", "TEAMID1234",
            clock=self.clock, transport=httpx.MockTransport(self.handler), log=self.log,
        )

    def test_request_shape(self):
        result = self.apns().send("ab" * 32, "production", "08:12 to Cardiff Central", "Platform 5")
        self.assertEqual(result, "ok")
        req = self.requests[0]
        self.assertEqual(str(req.url), "https://api.push.apple.com/3/device/" + "ab" * 32)
        self.assertEqual(req.method, "POST")
        h = req.headers
        self.assertEqual(h["apns-topic"], "com.jfcaba.platform")
        self.assertEqual(h["apns-push-type"], "alert")
        self.assertEqual(h["apns-priority"], "10")
        self.assertNotIn("apns-collapse-id", h)  # every alert stays on the lock screen
        self.assertEqual(h["apns-expiration"], str(int(self.now) + 600))
        scheme, token = h["authorization"].split(" ", 1)
        self.assertEqual(scheme, "bearer")
        self.assertEqual(jwt.get_unverified_header(token)["kid"], "KEYID12345")
        claims = jwt.decode(token, self.private.public_key(), algorithms=["ES256"], options={"verify_iat": False})
        self.assertEqual(claims, {"iss": "TEAMID1234", "iat": int(self.now)})
        self.assertEqual(json.loads(req.content), {"aps": {
            "alert": {"title": "08:12 to Cardiff Central", "body": "Platform 5"},
            "sound": "default",
        }})

    def test_sandbox_host(self):
        self.apns().send("cd" * 32, "sandbox", "t", "b")
        self.assertEqual(self.requests[0].url.host, "api.sandbox.push.apple.com")

    def test_jwt_reused_under_50_min_and_renewed_after(self):
        a = self.apns()
        a.send("ab" * 32, "production", "t", "b")
        self.now += 49 * 60
        a.send("ab" * 32, "production", "t", "b")
        self.now += 2 * 60
        a.send("ab" * 32, "production", "t", "b")
        auth = [r.headers["authorization"] for r in self.requests]
        self.assertEqual(auth[0], auth[1])
        self.assertNotEqual(auth[1], auth[2])

    def test_410_is_gone(self):
        self.status = 410
        self.reason = "Unregistered"
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b"), "gone")

    def test_400_bad_device_token_is_gone(self):
        self.status = 400
        for reason in ("BadDeviceToken", "DeviceTokenNotForTopic"):
            self.reason = reason
            self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b"), "gone")

    def test_other_400_is_error(self):
        self.status = 400
        self.reason = "PayloadEmpty"
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b"), "error")

    def test_500_and_network_error_are_error(self):
        self.status = 500
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b"), "error")
        self.raise_error = True
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b"), "error")

    def test_from_env_missing_is_none(self):
        full = {
            "APNS_KEY": base64.b64encode(self.pem).decode(),
            "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T",
        }
        self.assertIsNotNone(Apns.from_env(full))
        for k in full:
            self.assertIsNone(Apns.from_env({**full, k: ""}))
            self.assertIsNone(Apns.from_env({kk: v for kk, v in full.items() if kk != k}))

    def test_from_env_decodes_key(self):
        env = {
            "APNS_KEY": base64.b64encode(self.pem).decode(),
            "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T",
        }
        self.assertEqual(Apns.from_env(env)._key_pem, self.pem)

    def test_payload_over_4kb_truncates_body(self):
        title = "08:12 to Cardiff Central"
        body = "Delayed é\n" * 1000
        self.assertEqual(self.apns().send("ab" * 32, "production", title, body), "ok")
        content = self.requests[0].content
        self.assertLessEqual(len(content), 4096)
        sent = json.loads(content)["aps"]["alert"]
        self.assertEqual(sent["title"], title)
        self.assertTrue(body.startswith(sent["body"]))
        self.assertGreater(len(sent["body"]), 3000)

    def test_payload_truncation_is_maximal(self):
        title = "08:12 to Cardiff Central"
        body = "Platform changed: 3 \u2192 5\n" * 500
        self.apns().send("ab" * 32, "production", title, body)
        content = self.requests[0].content
        sent = json.loads(content)["aps"]["alert"]["body"]
        self.assertLessEqual(len(content), 4096)
        self.assertTrue(body.startswith(sent))
        longer = body[:len(sent) + 1]
        from platform_api.apns import _payload
        self.assertGreater(len(_payload(title, longer)), 4096)

    def test_huge_title_is_error_without_request(self):
        self.assertEqual(self.apns().send("ab" * 32, "production", "x" * 5000, "b"), "error")
        self.assertEqual(self.requests, [])

    def test_lone_surrogate_does_not_raise(self):
        self.assertEqual(self.apns().send("ab" * 32, "production", "t\ud800", "b\udc00"), "ok")

    def test_from_env_rejects_garbage_and_wrong_curve(self):
        env = {"APNS_KEY_ID": "K", "APNS_TEAM_ID": "T"}
        bad = base64.b64encode(b"-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----\n").decode()
        self.assertIsNone(Apns.from_env({**env, "APNS_KEY": bad}))
        self.assertIsNone(Apns.from_env({**env, "APNS_KEY": base64.b64encode(b"hello").decode()}))
        other = ec.generate_private_key(ec.SECP384R1()).private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption())
        self.assertIsNone(Apns.from_env({**env, "APNS_KEY": base64.b64encode(other).decode()}))

    def test_bad_key_send_returns_error(self):
        a = self.apns(pem=b"not a key")
        self.assertEqual(a.send("ab" * 32, "production", "t", "b"), "error")
        self.assertEqual(self.requests, [])

    def test_403_expired_token_drops_cached_jwt(self):
        a = self.apns()
        a.send("ab" * 32, "production", "t", "b")
        self.now += 1
        self.status, self.reason = 403, "ExpiredProviderToken"
        a.send("ab" * 32, "production", "t", "b")
        self.now += 1
        self.status, self.reason = 200, None
        a.send("ab" * 32, "production", "t", "b")
        auth = [r.headers["authorization"] for r in self.requests]
        self.assertEqual(auth[0], auth[1])  # cached until the 403
        self.assertNotEqual(auth[1], auth[2])

    def _send_at(self, a, dt, status, reason):
        self.now += dt
        self.status, self.reason = status, reason
        a.send("ab" * 32, "production", "t", "b")
        return self.requests[-1].headers["authorization"]

    def test_other_403_renews_jwt_once_then_bounded_to_20_min(self):
        a = self.apns()
        first = self._send_at(a, 0, 200, None)
        self.assertEqual(self._send_at(a, 1, 403, "InvalidProviderToken"), first)
        second = self._send_at(a, 1, 200, None)
        self.assertNotEqual(second, first)  # skew-style 403 heals
        self.assertEqual(self._send_at(a, 1, 403, "InvalidProviderToken"), second)
        self.assertEqual(self._send_at(a, 1, 200, None), second)  # within 20 min: kept
        self.assertEqual(self._send_at(a, 20 * 60, 403, "InvalidProviderToken"), second)
        self.assertNotEqual(self._send_at(a, 1, 200, None), second)  # after 20 min: may refresh

    def test_read_timeout_is_not_retried(self):
        calls = []

        def handler(request):
            calls.append(request)
            raise httpx.ReadTimeout("slow")

        a = Apns(self.pem, "K", "T", clock=self.clock, transport=httpx.MockTransport(handler),
                 log=io.StringIO())
        self.assertEqual(a.send("ab" * 32, "production", "t", "b"), "error")
        self.assertEqual(len(calls), 1)

    def test_connect_error_retries_once_then_ok(self):
        calls = []

        def handler(request):
            calls.append(request)
            if len(calls) == 1:
                raise httpx.ConnectError("boom")
            return httpx.Response(200)

        a = Apns(self.pem, "K", "T", clock=self.clock, transport=httpx.MockTransport(handler),
                 log=io.StringIO())
        self.assertEqual(a.send("ab" * 32, "production", "t", "b"), "ok")
        self.assertEqual(len(calls), 2)

    def test_network_error_twice_is_error_after_two_requests(self):
        self.raise_error = True
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b"), "error")
        self.assertEqual(len(self.requests), 2)

    def test_http_500_is_not_retried(self):
        self.status = 500
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b"), "error")
        self.assertEqual(len(self.requests), 1)

    def test_from_env_strips_whitespace(self):
        env = {
            "APNS_KEY": base64.b64encode(self.pem).decode() + "\n",
            "APNS_KEY_ID": " KID123 \n", "APNS_TEAM_ID": "\tTEAM99 ",
        }
        a = Apns.from_env(env)
        self.assertEqual((a._key_id, a._team_id, a._key_pem), ("KID123", "TEAM99", self.pem))
        self.assertIsNone(Apns.from_env({**env, "APNS_KEY_ID": "  \n"}))

    def test_backwards_clock_renews_jwt(self):
        a = self.apns()
        a.send("ab" * 32, "production", "t", "b")
        self.now -= 100
        a.send("ab" * 32, "production", "t", "b")
        auth = [r.headers["authorization"] for r in self.requests]
        self.assertNotEqual(auth[0], auth[1])

    def test_log_has_status_reason_and_no_token(self):
        token = "ab" * 32
        a = self.apns()
        self.status, self.reason = 400, "PayloadEmpty"
        a.send(token, "production", "SECRET TITLE", "SECRET BODY")
        self.assertEqual(self.log.getvalue(), "apns 400 PayloadEmpty\n")
        self.raise_error = True
        a = self.apns()
        a.send(token, "production", "SECRET TITLE", "SECRET BODY")
        self.assertEqual(self.log.getvalue(), "apns network ConnectError\n")
        for text in (token, "SECRET"):
            self.assertNotIn(text, self.log.getvalue())


if __name__ == "__main__":
    unittest.main()
