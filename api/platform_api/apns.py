"""APNs client: HTTP/2 with token-based (JWT) auth. Never logs device tokens."""
from __future__ import annotations

import base64
import binascii
import json
import sys
import threading
import time
from typing import Mapping, Optional, TextIO

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

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
    ).encode("utf-8", errors="replace")


def build_payload(title: str, body: str) -> Optional[bytes]:
    """Encode the alert, truncating the body (never the title) to fit 4 KB.

    Returns None if even an empty body does not fit."""
    if len(_payload(title, "")) > MAX_PAYLOAD:
        return None
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
                 transport: Optional[httpx.BaseTransport] = None,
                 log: TextIO = sys.stderr):
        self._key_pem = key_pem
        self._key_id = key_id
        self._team_id = team_id
        self._topic = topic
        self._clock = clock
        self._client = httpx.Client(http2=True, timeout=10, transport=transport)
        self._jwt: Optional[str] = None
        self._jwt_at = 0.0
        self._lock = threading.Lock()
        self._log = log

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Optional["Apns"]:
        key_b64 = (env.get("APNS_KEY") or "").strip()
        key_id = (env.get("APNS_KEY_ID") or "").strip()
        team_id = (env.get("APNS_TEAM_ID") or "").strip()
        if not (key_b64 and key_id and team_id):
            return None
        try:
            key_pem = base64.b64decode(key_b64, validate=True)
            key = serialization.load_pem_private_key(key_pem, password=None)
        except (binascii.Error, ValueError, TypeError):
            return None
        if not (isinstance(key, ec.EllipticCurvePrivateKey)
                and isinstance(key.curve, ec.SECP256R1)):
            return None
        return cls(key_pem, key_id, team_id)

    def _token(self) -> str:
        with self._lock:
            now = self._clock()
            age = now - self._jwt_at
            if self._jwt is None or age < 0 or age >= JWT_TTL:
                self._jwt = jwt.encode(
                    {"iss": self._team_id, "iat": int(now)},
                    self._key_pem, algorithm="ES256", headers={"kid": self._key_id},
                )
                self._jwt_at = now
            return self._jwt

    def _drop_token(self) -> None:
        with self._lock:
            self._jwt = None

    def _note(self, line: str) -> None:
        try:
            self._log.write(line + "\n")
        except Exception:
            pass

    def send(self, token: str, env: str, title: str, body: str) -> str:
        """Returns "ok", "gone" (token no longer valid) or "error". Never raises.
        No apns-collapse-id: every alert stays on the lock screen. One immediate retry on a
        network exception only, never on an HTTP status."""
        try:
            payload = build_payload(title, body)
            if payload is None:
                self._note("apns payload too large")
                return "error"
            host = HOSTS.get(env, HOSTS["production"])
            headers = {
                "authorization": "bearer " + self._token(),
                "apns-topic": self._topic,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-expiration": str(int(self._clock()) + EXPIRATION_SECONDS),
                "content-type": "application/json",
            }
            url = f"https://{host}/3/device/{token}"
            try:
                r = self._client.post(url, content=payload, headers=headers)
            except httpx.TransportError:
                r = self._client.post(url, content=payload, headers=headers)
        except Exception as e:
            self._note(f"apns network {type(e).__name__}")
            return "error"
        if r.status_code == 200:
            return "ok"
        reason = None
        try:
            reason = r.json().get("reason")
        except Exception:
            pass
        self._note(f"apns {r.status_code} {reason}")
        if r.status_code == 403 and reason == "ExpiredProviderToken":
            self._drop_token()  # other 403s keep it: renewing too often is TooManyProviderTokenUpdates
        if r.status_code == 410:
            return "gone"
        if r.status_code == 400 and reason in GONE_REASONS:
            return "gone"
        return "error"
