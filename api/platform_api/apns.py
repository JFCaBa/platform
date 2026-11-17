"""APNs client: HTTP/2 with token-based (JWT) auth. Never logs device tokens."""
from __future__ import annotations

import base64
import binascii
import json
import time
from typing import Mapping, Optional

import httpx
import jwt

HOSTS = {
    "production": "api.push.apple.com",
    "sandbox": "api.sandbox.push.apple.com",
}
JWT_TTL = 50 * 60  # Apple requires a refresh between 20 and 60 minutes
EXPIRATION_SECONDS = 600
MAX_PAYLOAD = 4096
GONE_REASONS = {"BadDeviceToken", "DeviceTokenNotForTopic"}


def _payload(title: str, body: str) -> bytes:
    return json.dumps(
        {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}},
        ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8")


def build_payload(title: str, body: str) -> bytes:
    """Encode the alert, truncating the body (never the title) to fit 4 KB."""
    data = _payload(title, body)
    if len(data) <= MAX_PAYLOAD:
        return data
    lo, hi = 0, len(body)  # longest body prefix that fits
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(_payload(title, body[:mid])) <= MAX_PAYLOAD:
            lo = mid
        else:
            hi = mid - 1
    return _payload(title, body[:lo])


class Apns:
    def __init__(self, key_pem: bytes, key_id: str, team_id: str,
                 topic: str = "com.jfcaba.platform", clock=time.time,
                 transport: Optional[httpx.BaseTransport] = None):
        self._key_pem = key_pem
        self._key_id = key_id
        self._team_id = team_id
        self._topic = topic
        self._clock = clock
        self._client = httpx.Client(http2=True, timeout=10, transport=transport)
        self._jwt: Optional[str] = None
        self._jwt_at = 0.0

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Optional["Apns"]:
        key_b64 = env.get("APNS_KEY") or ""
        key_id = env.get("APNS_KEY_ID") or ""
        team_id = env.get("APNS_TEAM_ID") or ""
        if not (key_b64 and key_id and team_id):
            return None
        try:
            key_pem = base64.b64decode(key_b64, validate=True)
        except (binascii.Error, ValueError):
            return None
        return cls(key_pem, key_id, team_id)

    def _token(self) -> str:
        now = self._clock()
        if self._jwt is None or now - self._jwt_at >= JWT_TTL:
            self._jwt = jwt.encode(
                {"iss": self._team_id, "iat": int(now)},
                self._key_pem, algorithm="ES256", headers={"kid": self._key_id},
            )
            self._jwt_at = now
        return self._jwt

    def send(self, token: str, env: str, title: str, body: str, collapse_id: str) -> str:
        """Returns "ok", "gone" (token no longer valid) or "error"."""
        host = HOSTS.get(env, HOSTS["production"])
        headers = {
            "authorization": "bearer " + self._token(),
            "apns-topic": self._topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": collapse_id,
            "apns-expiration": str(int(self._clock()) + EXPIRATION_SECONDS),
            "content-type": "application/json",
        }
        try:
            r = self._client.post(f"https://{host}/3/device/{token}",
                                  content=build_payload(title, body), headers=headers)
        except Exception:
            return "error"
        if r.status_code == 200:
            return "ok"
        if r.status_code == 410:
            return "gone"
        if r.status_code == 400:
            try:
                reason = r.json().get("reason")
            except Exception:
                reason = None
            if reason in GONE_REASONS:
                return "gone"
        return "error"
