# Follow a train on iOS with server push — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On iOS, follow one train from the board and get an APNs alert when its platform, expected time or status changes, with the app closed.

**Architecture:** The existing Python API gains an in-memory follow store, a 30 s poller (one Darwin board call per distinct station, own 2-slot pool) that diffs each followed train with a Python port of the app's `changes()`, and an APNs client (HTTP/2 + ES256 JWT). The Flutter app gets an iOS `PushFollower` (behind the existing `Follower` interface) that registers for remote notifications through a small method channel and calls `POST/DELETE /follow`.

**Tech Stack:** Python 3.12 (stdlib server, `unittest`), `httpx[http2]`, `PyJWT[crypto]`; Flutter/Dart (`http`, `shared_preferences`, `flutter_local_notifications` for the permission prompt), Swift (AppDelegate), nginx.

**Spec:** `docs/superpowers/specs/2026-11-17-ios-follow-push-design.md`

## Global Constraints

- Follows only in memory; never write tokens, trains or IPs to disk or logs. Keep `log_request`/`log_message` silent.
- End a follow: gone from the board on 2 consecutive readings (same as Android's `FollowLoop`), 2 min after cancelled, 3 h after start, on DELETE, on APNs `410` or `400 BadDeviceToken`.
- Caps: 500 follows, 50 distinct stations; over either → `503 {"error":"busy"}`.
- Poll every 30 s; Darwin 429 → skip polling for 5 min. Network/Darwin errors silent.
- Token: hex, 64–200 chars, **lowercased on input** (store key). `env`: `production` | `sandbox`. `std`: `HH:MM`. destination ≤ 100 chars. serviceId matches `SERVICE_ID_RE`. CRS in known stations. `startedAt`: epoch ms (the app's original start); server uses `started = max(startedAt, now − 3 h)` clamped to ≤ now, and answers `410` if `now − startedAt ≥ 3 h` (a server restart never extends the 3 h). Expiry uses wall clock (`time.time`).
- APNs: hosts `api.push.apple.com` / `api.sandbox.push.apple.com`, topic `com.jfcaba.platform`, `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration` = now + 600 s, no `apns-collapse-id` (every alert stays on the lock screen, like Android), JWT refreshed every 50 min. **One push per train per poll cycle**: body = that cycle's `changes()` texts joined by `"\n"`. Payload `{"aps":{"alert":{"title":<"08:12 to Cardiff Central">,"body":<texts>},"sound":"default"}}`, ≤ 4 KB (truncate body).
- Delivery is best effort (agreed by consenso): `last` always advances after a reading; a failed send (`"error"`) is lost, not retried.
- Concurrency: every follow carries a generation number; the poller only updates or removes a follow if its generation is unchanged since it was read (a DELETE or replacement during a send wins).
- Secrets in `/opt/platform/.env`: `APNS_KEY` (base64 of the .p8 file), `APNS_KEY_ID`, `APNS_TEAM_ID`. Missing → `/follow` answers `503 {"error":"unavailable"}`.
- Alert texts are exactly the Dart `changes()` texts (`Platform 5`, `Platform changed: 3 → 5`, `Now expected 08:19`, `Now on time`, `Delayed`, `Cancelled`, `Cancelled: <reason>`).
- Android code paths unchanged. App version `1.2.0+8`, user agent `WhatPlatform/1.2`.
- Commits: run the `consenso` skill on each code diff before committing (user's global rule); docs-only commits are exempt.

## Review Focus

1. Same train re-POSTed (app re-sync after resume) must keep baseline and start time: no duplicate alert, 3 h not extended. → test in Task 2 and Task 5.
2. A different train POSTed with the same token replaces the old follow and resets baseline/start. → Task 2.
3. Train missing from one board reading (Darwin glitch) must not end the follow; two in a row does. → Task 4.
4. Darwin cancellation taken back (cancelled then not) must clear the 2 min linger. → Task 4.
5. App killed while following, server restarted, app reopened: `sync()` re-POSTs with the original `startedAt` and gets 200 (train still there, 3 h not reset) or 410 (clear). → Task 5 and Task 7.
6. Stop or a new follow while an older request is still in flight (sync→stop, follow A→follow B): the latest user action wins, on the phone and on the server. → Task 7.
7. APNs token rotates between follows: the old registration is deleted. → Task 7.

---

### Task 1: Shared change rules (Python port of `changes()`)

**Files:**
- Create: `api/platform_api/follow.py`, `api/tests/fixtures/follow_changes.json`, `api/tests/test_follow.py`
- Modify: `app/test/follow_logic_test.dart` (add a fixture-driven test)

**Interfaces:**
- Produces: `changes(before: dict, after: dict) -> list[str]`, `is_cancelled(d: dict) -> bool`, `matches(train: dict, d: dict) -> bool`, `find_followed(board: dict, train: dict) -> dict | None`. Departures are the API's own service dicts (`to_board` shape); `train` is `{"crs","std","destination","serviceId"?}`.

- [ ] **Step 1:** Write `follow_changes.json`: a list of `{"before": {...}, "after": {...}, "alerts": [...]}` covering every case in the existing Dart `test('changes', ...)` (lines 45–60), using only `platform`, `etd`, `cancelled`, `cancelReason` (other fields default).
- [ ] **Step 2:** `test_follow.py`: `test_changes_fixture` loops the fixture asserting `changes(b, a) == alerts`; `test_matches_by_id_when_both_have_one`, `test_matches_by_std_and_destination_otherwise`, `test_find_followed_wrong_crs_is_none`.
- [ ] **Step 3:** Dart: `test('changes match the shared fixture', ...)` reads `../api/tests/fixtures/follow_changes.json` and asserts the same.
- [ ] **Step 4:** Run `cd api && python3 -m unittest tests.test_follow -v` → FAIL (module missing).
- [ ] **Step 5:** Implement `follow.py` mirroring `follow_logic.dart` (`HHMM` from `board.py`).
- [ ] **Step 6:** Run `cd api && python3 -m unittest -v` and `cd app && flutter test test/follow_logic_test.dart` → all PASS.
- [ ] **Step 7:** consenso, then commit `feat(api): port follow change rules, shared fixture with the app`.

### Task 2: Follow store

**Files:**
- Modify: `api/platform_api/follow.py`
- Test: `api/tests/test_follow.py`

**Interfaces:**
- Produces:
  - `class Follow` (dataclass): `token: str, env: str, train: dict, started: float, last: dict | None, cancelled_at: float | None, missing: int, gen: int`.
  - `class FollowStore(clock: Callable[[], float] = time.time, max_follows=500, max_stations=50)`, thread-safe (one lock). All new modules start with `from __future__ import annotations` (tests run on 3.9 too).
    - `upsert(token, env, train, baseline: dict, started: float) -> str` → `"ok"` | `"busy"`. Same token + same train (`crs`, `std`, `destination`, `serviceId`) → keeps `started`/`last`/`gen`, returns `"ok"`. Different train → replaces with the given `started`, `last=baseline`, new `gen` (store-wide counter).
    - `is_same(token, train) -> bool`.
    - `update(token, gen, **fields) -> bool` (no-op returning False if gone or `gen` differs).
    - `remove(token, gen: int | None = None) -> None` (with `gen`: only if unchanged).
    - `stations() -> set[str]`; `for_station(crs) -> list[Follow]` (copies safe to iterate).
    - `__len__`.

- [ ] **Step 1:** Tests: `test_upsert_same_train_keeps_baseline_and_start` (advance clock, re-upsert with a different baseline, `last` and `started` unchanged), `test_new_train_replaces`, `test_cap_follows` (501st new token → `"busy"`; re-upsert of existing token still `"ok"`), `test_cap_stations` (51st distinct CRS → `"busy"`, a new follow at an already polled CRS → `"ok"`), `test_remove_unknown_is_noop`, `test_update_and_remove_with_stale_gen_are_noops`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** consenso, commit `feat(api): in-memory follow store`.

### Task 3: APNs client and dependencies

**Files:**
- Create: `api/platform_api/apns.py`, `api/requirements.txt`, `api/tests/test_apns.py`
- Modify: `api/Dockerfile` (`COPY requirements.txt` + `pip install --no-cache-dir -r requirements.txt` before `USER app`), `.gitignore` (`api/.venv/`)

**Interfaces:**
- Produces: `class Apns(key_pem: bytes, key_id: str, team_id: str, topic="com.jfcaba.platform", clock=time.time, transport: httpx.BaseTransport | None = None)` with `send(token: str, env: str, title: str, body: str, collapse_id: str) -> str` returning `"ok"` | `"gone"` (410, or 400 with reason `BadDeviceToken`/`DeviceTokenNotForTopic`) | `"error"` (anything else, incl. network). One `httpx.Client(http2=True, timeout=10)` reused. `Apns.from_env(env: Mapping) -> Apns | None` (base64-decodes `APNS_KEY`; any of the three missing → `None`).

- [ ] **Step 1:** `requirements.txt` with exact pins of current `httpx[http2]` and `PyJWT[crypto]`. Local venv: `python3 -m venv api/.venv && api/.venv/bin/pip install -r api/requirements.txt` (use a 3.12 interpreter if available; tests must also run on 3.9).
- [ ] **Step 2:** Tests with `httpx.MockTransport` and a throwaway EC P-256 key generated in the test: `test_request_shape` (URL `https://api.push.apple.com/3/device/<token>`, sandbox host for `env="sandbox"`, headers topic/push-type/priority/collapse-id/expiration = clock+600, `authorization: bearer <jwt>` whose header has `kid`, claims `iss`=team, `iat`=clock, verifies with the public key; body equals the payload in Global Constraints), `test_jwt_reused_under_50_min_and_renewed_after`, `test_410_is_gone`, `test_400_bad_device_token_is_gone`, `test_500_and_network_error_are_error`, `test_from_env_missing_is_none`, `test_payload_over_4kb_truncates_body`.
- [ ] **Step 3:** Run `api/.venv/bin/python -m unittest tests.test_apns -v` → FAIL. **Step 4:** Implement. **Step 5:** PASS.
- [ ] **Step 6:** `cd api && docker build .` succeeds.
- [ ] **Step 7:** consenso, commit `feat(api): APNs client (HTTP/2, token auth)`.

### Task 4: Poller

**Files:**
- Modify: `api/platform_api/follow.py`
- Test: `api/tests/test_follow.py`

**Interfaces:**
- Consumes: `FollowStore`, `Follow`, `changes`, `find_followed`, `is_cancelled` (Tasks 1–2); something with `send(token, env, title, body) -> str` (Task 3).
- Each tick first ends follows by clock (3 h, cancelled + 2 min), **before** the 429 pause check and before any fetch, so expiry never depends on Darwin answering.
- Produces: `class Poller(store, fetch_board: Callable[[str], dict], push, clock=time.time)` with `tick() -> None` (one pass over `store.stations()`) and `run(stop: threading.Event, every=30.0)`. `fetch_board` may raise anything (silent, follow kept); an exception whose `status` attribute is `429` (e.g. `server.Upstream`) pauses all polling 5 min. `follow.py` must not import `server.py` (server imports follow). Constants `MAX_DURATION = 3*3600`, `CANCELLED_LINGER = 120`, `RATE_LIMIT_PAUSE = 300` in `follow.py`. Title = `f"{std} to {destination}"`.

- [ ] **Step 1:** Tests with a fake board source, fake push (records calls / returns configured result) and a manual clock: `test_alert_on_platform_change`, `test_two_changes_one_push_joined_by_newline` (same collapse id), `test_no_alert_when_unchanged`, `test_one_fetch_per_station` (3 follows at 2 CRS → 2 fetches), `test_missing_once_keeps_twice_ends`, `test_cancelled_ends_after_two_minutes`, `test_cancellation_taken_back_clears_linger`, `test_three_hours_ends`, `test_expiry_runs_during_429_pause`, `test_expiry_runs_during_upstream_errors`, `test_gone_token_removed`, `test_push_error_keeps_follow_and_advances_last`, `test_replaced_during_send_survives` (fake push re-upserts the token with another train and returns `"gone"`: the new follow stays, untouched), `test_deleted_during_send_not_recreated`, `test_upstream_error_silent`, `test_429_pauses_five_minutes`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (read follows under the lock, fetch and send outside it, write back with `update`/`remove` by `gen`). **Step 4:** PASS.
- [ ] **Step 5:** consenso, commit `feat(api): follow poller`.

### Task 5: `/follow` endpoints and wiring

**Files:**
- Modify: `api/platform_api/server.py`
- Test: `api/tests/test_server.py`

**Interfaces:**
- Consumes: Tasks 2–4. `make_server(..., follows: FollowStore | None = None, push=None)`; the poller and POST share one `poll_slots = threading.BoundedSemaphore(2)` (never the board's `slots`). POST waits up to 5 s for a slot; timeout → `503 {"error":"busy"}` (not 502: Darwin didn't fail).
- Produces: `POST /follow`, `DELETE /follow` (JSON body ≤ 4 KB, `Content-Type` not checked). `main()` builds `Apns.from_env(env)`; when `None`, `/follow` → `503 {"error":"unavailable"}` and no poller thread.

POST responses: `400 {"error":"bad request"}` (validation per Global Constraints, bad JSON, body too big), `410 {"error":"gone"}` (train not on the board, or `startedAt` ≥ 3 h ago), `502 {"error":"upstream"}` (Darwin failed), `429` on Darwin 429, `503 {"error":"busy"}` (caps), `200 {"ok":true}`. If `store.is_same(token, train)` the board is not re-read: `200` straight away. DELETE → `204` always (bad body → `400`).

- [ ] **Step 1:** Tests using the existing `FakeDarwin` and a fake push: `test_follow_ok_then_poll_alerts`, `test_follow_train_not_on_board_410`, `test_follow_validation_400` (subTests: short token, non-hex, 201 chars, bad env, `std` "8:12", unknown CRS, long destination, bad serviceId, missing/non-int `startedAt`, not JSON, 5 KB body), `test_refollow_same_train_no_darwin_call`, `test_refollow_after_restart_keeps_original_start` (fresh store, `startedAt` 2 h 50 min ago → ends 10 min later), `test_started_over_3h_ago_410`, `test_uppercase_token_is_same_follow` (POST upper, DELETE lower → gone), `test_follow_without_apns_503`, `test_delete_with_body_204` (real HTTP round trip through the test server), `test_follow_does_not_use_board_slots` (board slots full → POST still served), `test_poll_slots_full_503_after_wait`, `test_follow_logs_nothing` (log stream stays empty on success).
- [ ] **Step 2:** FAIL. **Step 3:** Implement `do_POST`/`do_DELETE`; `main()` starts `Poller.run` in a daemon thread. **Step 4:** All API tests PASS (`api/.venv/bin/python -m unittest -v`).
- [ ] **Step 5:** consenso, commit `feat(api): POST/DELETE /follow`.

### Task 6: nginx, privacy policy, deploy

**Files:**
- Modify: `deploy/nginx/whatplatform.uk.conf`, `deploy/README.md`, `site/index.html`

- [ ] **Step 1:** nginx: top-level `limit_req_zone $binary_remote_addr zone=follow:1m rate=30r/m;` (stations share IPs via Wi-Fi/CGNAT); `location = /follow { limit_except POST DELETE { deny all; } limit_req zone=follow burst=20 nodelay; limit_req_status 429; client_max_body_size 4k; proxy_pass http://127.0.0.1:8510/follow; }` with the same blanked `X-Real-IP`/`X-Forwarded-For`, `Connection ""`, timeouts and security headers as the other locations, no cache.
- [ ] **Step 2:** README: the three `APNS_*` lines, `base64 -i AuthKey_XXXX.p8 | tr -d '\n'` to produce `APNS_KEY`, "deploy outside UK commuting peaks: a restart forgets follows".
- [ ] **Step 3:** Privacy policy: two sentences — on iPhone, following a train sends the device's push token and the train to our server, kept only in memory and deleted when the train leaves, is cancelled, after 3 hours or when you stop following; nothing else is stored or logged.
- [ ] **Step 4:** Docs commit `docs: nginx /follow, APNs env, privacy policy for iOS following`, push.
- [ ] **Step 5:** Deploy (ask the user before the first sudo of the session): `git pull`, `docker compose up -d --build`, copy nginx conf, `nginx -t`, reload. Without APNs secrets: `curl -s -X POST https://api.whatplatform.uk/follow -d '{}'` → `400`; valid body → `503 unavailable`; `/departures/KGX` still 200.

### Task 7: iOS push token and `PushFollower`

**Files:**
- Create: `app/lib/follow/push_follower.dart`, `app/lib/follow/push_token.dart`, `app/ios/Runner/Runner.entitlements`, `app/test/push_follower_test.dart`
- Modify: `app/ios/Runner/AppDelegate.swift`, `app/ios/Runner.xcodeproj/project.pbxproj` (`CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` for all configs), `app/lib/main.dart`, `app/lib/config.dart` (`userAgent` `WhatPlatform/1.2`), `app/pubspec.yaml` (`1.2.0+8`)

**Interfaces:**
- Produces:
  - `abstract class PushToken { Future<bool> requestPermission(); Future<String?> token(); Future<String> environment(); }`; `ChannelPushToken` calls `MethodChannel('whatplatform/push')` methods `requestPermission` (bool), `token` (String?, null on failure), `environment` (`'sandbox'` | `'production'`). No new Dart dependency.
  - `class PushFollower extends ChangeNotifier implements Follower` — `static Future<PushFollower> create({required http.Client client, required SharedPreferences prefs, required PushToken push, String baseUrl = apiBaseUrl, DateTime Function() clock = DateTime.now})`, which calls `sync()` once. Local state key `push_follow` = `{"train": FollowedTrain.toJson(), "startedAt": ms, "token": hex, "env": env}`. POST body includes `startedAt`.
  - All operations run one at a time through a `_serial` queue (as `FollowService` does) and carry a local generation; a result from a superseded operation is discarded (never re-saves after a later `stop()`/`follow()`).
  - `follow(t)`: permission false → `false`; token null → throws `FollowFailed('notifications')`; if a saved follow used a different token, best-effort DELETE of the old one; POST 200 → save, notify, `true`; 410 → throws `FollowFailed('gone')`; other → throws `FollowFailed('network')`.
  - `stop()`: clear + notify first, then best-effort DELETE with the saved token.
  - `sync()`: no local state → nothing; `startedAt` ≥ 3 h ago → clear + best-effort DELETE; current token differs from saved → DELETE old, POST with new; else re-POST: 410 → clear; 200 or any error → keep.
- Swift (`AppDelegate.swift`, channel `whatplatform/push`): `requestPermission` → `UNUserNotificationCenter.requestAuthorization([.alert, .sound])`; `token` → return the cached token if iOS already gave one, else `registerForRemoteNotifications()` and complete the pending `FlutterResult` from `didRegisterForRemoteNotificationsWithDeviceToken` (hex lowercase, cached) or `didFailToRegister…` (`FlutterError`), 10 s timeout; `environment` → `aps-environment` read from `embedded.mobileprovision` (`development` → `sandbox`), no profile (App Store/TestFlight) → `production`. Entitlement `aps-environment` = `development` (Xcode sets production on distribution export).
- UI: `home_screen.dart` `_toggleFollow` maps `FollowFailed('gone')` → snackbar "That train has left", `'network'` → "Couldn't follow: check your connection", `'notifications'` → the existing denied message. `main.dart`: iOS → `PushFollower`, Android unchanged.

- [ ] **Step 1:** Tests (MockClient + fake `PushToken` + manual clock): `follow posts token env and train`, `permission denied follows nothing`, `410 throws gone and saves nothing`, `stop clears even if DELETE fails`, `sync re-posts within 3 h and keeps on 200`, `sync clears on 410`, `sync clears after 3 h and sends DELETE`, `sync keeps on network error`, `sync posts original startedAt`, `stop during pending sync wins` (delayed POST response arrives after stop: nothing saved), `second follow wins over first` (delayed first response), `token rotation deletes old registration`, `create calls sync`; home screen test: `gone shows "That train has left"`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement Dart, Swift, entitlements. **Step 4:** `flutter test` all PASS; `flutter analyze` clean; `flutter build ios --release --no-codesign` succeeds.
- [ ] **Step 5:** consenso, commit `feat(app): follow a train on iOS via server push, 1.2.0+8`.

### Task 8: APNs key, real-device check, store prep

Needs the user (portal buttons, sudo, real iPhone). Stop here if the .p8 key doesn't exist yet.

- [ ] **Step 1:** In developer.apple.com (team 338 TAC, S.L.), with Claude filling forms and the user pressing the buttons: enable Push Notifications on `com.jfcaba.platform`, create an APNs auth key, download the .p8. Put `APNS_*` in `/opt/platform/.env` (never in chat/repo), `docker compose up -d`.
- [ ] **Step 2:** Debug build on a real iPhone (sandbox): follow a train at a busy station; `/follow` 200; wait for or provoke a change (e.g. platform assigned close to departure); alert arrives with the app killed. Stop following → DELETE 204. Record the result in `docs/store/estado.md`.
- [ ] **Step 3:** Archive 1.2.0 (8), upload; TestFlight check (production env) with the same test.
- [ ] **Step 4:** ASC: App Privacy → Identifiers › Device ID, not linked, App Functionality; description and review notes mention following with push. No "Submit for review" without the user's explicit OK. Docs commit to `docs/store/estado.md`.
