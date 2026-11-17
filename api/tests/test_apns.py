from __future__ import annotations

import base64
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

    def apns(self):
        return Apns(
            self.pem, "KEYID12345", "TEAMID1234",
            clock=self.clock, transport=httpx.MockTransport(self.handler),
        )

    def test_request_shape(self):
        result = self.apns().send("ab" * 32, "production", "08:12 to Cardiff Central", "Platform 5", "cid")
        self.assertEqual(result, "ok")
        req = self.requests[0]
        self.assertEqual(str(req.url), "https://api.push.apple.com/3/device/" + "ab" * 32)
        self.assertEqual(req.method, "POST")
        h = req.headers
        self.assertEqual(h["apns-topic"], "com.jfcaba.platform")
        self.assertEqual(h["apns-push-type"], "alert")
        self.assertEqual(h["apns-priority"], "10")
        self.assertEqual(h["apns-collapse-id"], "cid")
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
        self.apns().send("cd" * 32, "sandbox", "t", "b", "c")
        self.assertEqual(self.requests[0].url.host, "api.sandbox.push.apple.com")

    def test_jwt_reused_under_50_min_and_renewed_after(self):
        a = self.apns()
        a.send("ab" * 32, "production", "t", "b", "c")
        self.now += 49 * 60
        a.send("ab" * 32, "production", "t", "b", "c")
        self.now += 2 * 60
        a.send("ab" * 32, "production", "t", "b", "c")
        auth = [r.headers["authorization"] for r in self.requests]
        self.assertEqual(auth[0], auth[1])
        self.assertNotEqual(auth[1], auth[2])

    def test_410_is_gone(self):
        self.status = 410
        self.reason = "Unregistered"
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b", "c"), "gone")

    def test_400_bad_device_token_is_gone(self):
        self.status = 400
        for reason in ("BadDeviceToken", "DeviceTokenNotForTopic"):
            self.reason = reason
            self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b", "c"), "gone")

    def test_other_400_is_error(self):
        self.status = 400
        self.reason = "PayloadEmpty"
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b", "c"), "error")

    def test_500_and_network_error_are_error(self):
        self.status = 500
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b", "c"), "error")
        self.raise_error = True
        self.assertEqual(self.apns().send("ab" * 32, "production", "t", "b", "c"), "error")

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
        self.assertEqual(self.apns().send("ab" * 32, "production", title, body, "c"), "ok")
        content = self.requests[0].content
        self.assertLessEqual(len(content), 4096)
        sent = json.loads(content)["aps"]["alert"]
        self.assertEqual(sent["title"], title)
        self.assertTrue(body.startswith(sent["body"]))
        self.assertGreater(len(sent["body"]), 3000)


if __name__ == "__main__":
    unittest.main()
