# Your train, live — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the followed train live (countdown, platform, status, where it is) on the app home, an iOS Live Activity pushed by the server, and the Android ongoing notification.

**Architecture:** The API derives the train's position from Darwin Service Details `previousCallingPoints` and adds it to `/service/{id}`. The existing follow poller also keeps a Live Activity content state per follow and pushes it to APNs (`liveactivity`) when it changes. The app shares one Dart `whereText()`; iOS gets a SwiftUI widget extension driven by a method channel; Android's FollowLoop adds the position to its ongoing text.

**Tech Stack:** Python 3.12 stdlib + httpx/jwt (api/), Flutter/Dart (app/), Swift/SwiftUI ActivityKit (ios/FollowActivity), Ruby `xcodeproj` gem (1.27, installed) for adding the target.

**Spec:** `docs/superpowers/specs/2026-11-21-live-train-design.md`

## Global Constraints

- Darwin keys only in `/opt/platform/.env` on the VPS; never in app, repo or chat.
- Tokens (device and activity) only in memory on the server; never logged (log exception type names only).
- English UI copy, exact strings: "N stops away · left X HH:MM" (N ≥ 2), "Next stop: here · left X HH:MM" (N = 1), "Not yet left X", "Starts here", "Your train", "Platform not yet shown".
- App imports `package:material_ui/material_ui.dart` (project convention, not `material.dart`).
- iOS app target stays at 15.0; Live Activity code behind `@available(iOS 16.1, *)`; extension target 16.1.
- Content state JSON keys exactly: `departs` (int epoch s | null), `status` (string), `platform` (string | null), `where` (string | null), `cancelled` (bool).
- Live Activity APNs topic `com.jfcaba.platform.push-type.liveactivity`, `apns-push-type: liveactivity`.
- Position fetched at most every 60 s per follow, from the poller's existing 2-slot Darwin pool.
- Service Details answers are cached in memory 30 s per serviceId (one `ServiceCache` in server.py, used by both `/service/{id}` and the poller's `fetch_position`).
- Android: the home-screen tracker's extra board/position polls (foreground only) are accepted; they hit the same 30 s caches.
- Version 1.4.0+12. Run `flutter test` (app/) and `python -m pytest` (api/) green before each commit; consenso on each diff.

## Review Focus

- A train with no `serviceId` (older board entry): no position anywhere, no Service Details call, everything else works — test in Task 4 and Task 6.
- Darwin `at` = "On time" vs "HH:MM" vs "No report"/"Cancelled": "No report" and "Cancelled" don't count as passed — test in Task 1.
- Departure across midnight (std 00:05 read at 23:58): `departs` is tomorrow, not 24 h ago — test in Task 2 (Python) and Task 5 (Dart already DST/midnight-safe via `minutesUntil`).
- Activity token arrives after the follow POST (iOS gives it async): re-POST updates the token without resetting baseline or start — test in Task 4.
- Follow ends while a Live Activity is up (train left, DELETE, APNs gone): exactly one `end` push, none after — test in Task 4.

---

### Task 1: API — train position from Service Details

**Files:**
- Modify: `api/platform_api/board.py` (add `train_position`, extend `to_stops`)
- Test: `api/tests/test_board.py`

**Interfaces:**
- Produces: `train_position(darwin: dict) -> dict` returning exactly one of
  `{"lastStop": str, "lastAt": "HH:MM", "stopsAway": int}`, `{"notStarted": str}`, `{"startsHere": True}`.
  `to_stops(...)` result gains key `"position"`.

- [ ] **Step 1: Failing tests** `test_position_last_passed_stop` (previous [A st 16:00 at "On time", B st 16:10 at "16:12", C st 16:20 et "On time"] → `{"lastStop":"B","lastAt":"16:12","stopsAway":2}`), `test_position_on_time_uses_st` (A at "On time" only, then nothing → lastAt "16:00", stopsAway 1), `test_position_not_started` (all `et` → `{"notStarted":"A"}`), `test_position_no_report_is_not_passed` (B at "No report", C at "Cancelled" → passed is A), `test_position_starts_here` (no previousCallingPoints → `{"startsHere": True}`), `test_to_stops_has_position`.
- [ ] **Step 2:** `cd api && python -m pytest tests/test_board.py -q` → FAIL (no `train_position`).
- [ ] **Step 3:** Implement from `previousCallingPoints[0].callingPoint` only (portion 0 is the train's own path; other portions are joining trains). Passed = `at` is "On time" or HH:MM.
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit `feat(api): where the train is, in /service`.

### Task 2: API — Live Activity content state

**Files:**
- Create: `api/platform_api/live.py`
- Test: `api/tests/test_live.py`

**Interfaces:**
- Produces: `where_text(position: dict | None) -> str | None`; `departs_epoch(d: dict, now: float) -> int | None` (expected departure of a board service `d` in Europe/London: `etd` if HH:MM, else `std` when `etd` is "On time"/None; None for "Delayed"/"Cancelled"; picks the London instant nearest to `now` among yesterday/today/tomorrow); `content_state(d: dict, position: dict | None, now: float) -> dict` with the five keys; `status` = "Cancelled" | "Exp HH:MM" | "On time" | "Delayed" | "".

- [ ] **Step 1: Failing tests:** where texts for the three shapes + None + stopsAway 1 ("Next stop: here · left B 16:12"); `departs_epoch` for "On time", "16:48", "Delayed" → None, midnight (std "00:05", now 23:58 London → next day); BST date (2026-07-01) and GMT date; `content_state` cancelled → `{"departs":None,"status":"Cancelled","cancelled":True,...}`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement with `zoneinfo.ZoneInfo("Europe/London")`.
- [ ] **Step 4:** Pass. **Step 5:** Commit `feat(api): Live Activity content state`.

### Task 3: API — APNs Live Activity send

**Files:**
- Modify: `api/platform_api/apns.py`
- Test: `api/tests/test_apns.py`

**Interfaces:**
- Produces: `Apns.send_activity(token: str, env: str, state: dict, *, event: str = "update", priority: int = 5, stale: int, dismissal: int | None = None)` (callers pass `stale = (departs or now) + 600`, never None) -> str` ("ok" | "gone" | "error", never raises). Headers: topic `f"{self._topic}.push-type.liveactivity"`, `apns-push-type: liveactivity`, `apns-priority: str(priority)`. Payload `{"aps":{"timestamp":int(now),"event":event,"content-state":state, "stale-date"?:stale, "dismissal-date"?:dismissal}}`. Shares transport, JWT, retry and gone rules with `send` (factor a private `_post(token, env, payload, headers_extra)`).

- [ ] **Step 1: Failing tests** with the existing fake transport: headers and payload of an update; `end` carries `dismissal-date`; 410 → "gone"; existing `send` tests unchanged.
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(api): Live Activity pushes`.

### Task 4: API — follows carry a Live Activity

**Files:**
- Modify: `api/platform_api/follow.py`, `api/platform_api/server.py`
- Test: `api/tests/test_follow.py`, `api/tests/test_server.py`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `Follow` gains `activity: str | None`, `state: dict | None` (last pushed content state), `position: dict | None`, `position_at: float`. `FollowStore.upsert(..., activity: str | None = None)`: same train → sets `activity` when given and different (keeps baseline/start; `state = None` so the next tick pushes). `_UPDATABLE` adds `state`, `position`, `position_at`. `Poller(store, fetch_board, push, fetch_position=None, ...)` where `fetch_position(serviceId: str) -> dict` (raises on errors). `POST /follow` accepts optional `activityToken` (TOKEN_RE, lowercased); `_follow_request` returns a 5-tuple `(token, env, train, started_ms, activity)`. `is_same(...)` short-cut only when the activity token is also unchanged.

- [ ] **Step 1: Failing tests:**
  - `test_activity_update_pushed_on_change` (two ticks, same reading → one `send_activity`; platform appears → second with priority 10).
  - `test_position_fetched_every_60s` (ticks at 0, 30, 60 s → `fetch_position` called at 0 and 60; error keeps last position).
  - `test_no_service_id_no_position_call`.
  - `test_late_activity_token_keeps_baseline` (POST without, then with activityToken → baseline/started unchanged, no alert, next tick pushes state).
  - `test_end_pushed_once` for: train gone from board (dismissal now+900), DELETE (dismissal now), cancelled + 2 min, 3 h; none afterwards. DELETE's end is sent by the poller's next tick from a small `ended` list in the store (no APNs call inside the HTTP handler).
  - `test_activity_gone_drops_only_activity` (send_activity "gone" → `activity=None`, follow continues with alerts).
  - server: 400 on bad `activityToken`, 200 with a valid one.
- [ ] **Step 2:** FAIL. **Step 3:** Implement; add `ServiceCache` (30 s TTL, dict + lock, test `test_service_cache_shared`) used by `/service/{id}` and `fetch_position`; wire `fetch_position` in `make_server` using `poll_slots` and `service_url`/`service_key` (None when no service key → no positions). **Step 4:** `python -m pytest -q` all green. **Step 5:** Commit `feat(api): follows drive a Live Activity`.

### Task 5: App — position model and where text

**Files:**
- Create: `app/lib/domain/position.dart`
- Modify: `app/lib/data/departures.dart` (`ServiceDetails fetchService(id)`; `fetchStops` delegates)
- Test: `app/test/position_test.dart`, `app/test/departures_test.dart` (or the existing data test file)

**Interfaces:**
- Produces: `sealed class TrainPosition` with `PassedStop(name, at, stopsAway)`, `NotStarted(origin)`, `StartsHere()`; `TrainPosition? TrainPosition.fromJson(Object?)` (null on missing/bad); `String? whereText(TrainPosition?)` (same strings as `where_text`); `class ServiceDetails {List<List<Stop>> portions; TrainPosition? position;}`; `DeparturesClient.fetchService(String serviceId) -> Future<ServiceDetails>`.

- [ ] **Step 1:** Failing tests mirroring Task 2's where texts and JSON shapes, plus a body without `position` → null.
- [ ] **Step 2–4.** **Step 5:** Commit `feat(app): where the train is`.

### Task 6: App — "Your train" on the home screen

**Files:**
- Create: `app/lib/follow/follow_tracker.dart`, `app/lib/ui/your_train.dart`
- Modify: `app/lib/ui/departure_row.dart` (`NextTrainCard` optional `where` line under the destination, primary colour, icon `Icons.train`), `app/lib/ui/home_screen.dart`, `app/lib/main.dart`
- Test: `app/test/follow_tracker_test.dart`, `app/test/home_screen_test.dart`

**Interfaces:**
- Consumes: Task 5.
- Produces: `class FollowTracker extends ChangeNotifier` (`FollowTracker({required Follower follower, required Future<Board> Function(String crs) fetchBoard, required Future<ServiceDetails> Function(String id) fetchService, required DateTime Function() clock, PeriodicTimerFactory periodic})`, getters `Departure? departure`, `TrainPosition? position`, methods `onForeground()`, `onBackground()`, `set onScreen(Board? b)`). Board polled every 30 s only when the followed CRS ≠ board on screen (else uses that board); position every 60 s when `serviceId` != null; stops when `follower.current == null` or in background. `YourTrainStrip(departure, position, nowUtc, onTap)`.
- HomeScreen gets `FollowTracker? tracker`; at the followed station the NextTrainCard shows `whereText(tracker.position)`; elsewhere `YourTrainStrip` above the board, tap → `controller.selectStation(crs)` (use the controller's existing station-select method).

- [ ] **Step 1:** Failing tests: tracker polls other-station board every 30 s and not when on screen; position every 60 s; no serviceId → no fetchService; stops on unfollow and in background. Widgets: strip shows "Your train", "12 min", "Plat 10", where text; tapping it selects the station; card at the followed station shows the where line; nothing when not following.
- [ ] **Step 2–4.** **Step 5:** Commit `feat(app): your train, live, on the home screen`.

### Task 7: Android — richer ongoing notification

**Files:**
- Modify: `app/lib/follow/follow_loop.dart`, `app/lib/follow/follow_logic.dart` (`ongoingTitle`, `ongoingText` new signature), `app/lib/follow/follow_service.dart`
- Test: `app/test/follow_loop_test.dart`, `app/test/follow_logic_test.dart`

**Interfaces:**
- Produces: `String ongoingTitle(FollowedTrain t, Departure d)` → "16:42 to Peterborough · Plat 10" (no platform part when null); `String ongoingText(Departure d, DateTime nowUtc, TrainPosition? p)` → "12 min · On time · 2 stops away (left Stevenage)" (where text with " · left " turned into " (left …)" and the time dropped: build it from the position, not by string surgery). `FollowLoop` gains `Future<ServiceDetails> Function(String id)? fetchService` and `ongoing` becomes `Future<void> Function(String title, String text)`; position at most every 60 s.
- [ ] **Step 1:** Failing tests for both texts and the 60 s position cadence. **Step 2–4.** **Step 5:** Commit `feat(android): live text in the following notification`.

### Task 8: iOS — Live Activity from Dart

**Files:**
- Create: `app/lib/follow/live_activity.dart`
- Modify: `app/lib/follow/push_follower.dart`, `app/lib/main.dart`
- Test: `app/test/push_follower_test.dart`

**Interfaces:**
- Produces: `abstract class LiveActivity { Future<bool> start(FollowedTrain t, Map<String, Object?> state); Future<void> update(Map<String, Object?> state); Future<void> end(); Stream<String> get tokens; }`; `ChannelLiveActivity` over `MethodChannel('whatplatform/activity')` (methods `start`, `update`, `end`; native calls back `token` with hex); `Map<String, Object?> contentState(Departure d, TrainPosition? p, DateTime nowUtc)` in `domain/position.dart` (Dart twin of Task 2). `PushFollower.create(..., LiveActivity? activity)`: after a 200 follow, `start`; each token from `tokens` → serial re-POST with `activityToken`; `stop()`/clear → `end()`; `_Saved` gains `activity` (hex) so `sync()` re-posts it.
- [ ] **Step 1:** Failing tests with a fake LiveActivity: start after follow; late token → second POST with `activityToken` and same `startedAt`; stop → end; sync re-posts saved activity token; start returning false (unsupported) → follow still works; a token arriving after `stop()` (or for a superseded follow, by `_gen`) → no POST.
- [ ] **Step 2–4.** **Step 5:** Commit `feat(ios): start and feed the Live Activity`.

### Task 9: iOS — widget extension and native channel

**Files:**
- Create: `app/ios/FollowActivity/{FollowActivityBundle.swift, FollowActivityLiveActivity.swift, Info.plist}`, `app/ios/Runner/TrainActivityAttributes.swift` (member of both targets), `app/tools/ios/add_follow_activity_target.rb`
- Modify: `app/ios/Runner/AppDelegate.swift` (channel `whatplatform/activity`), `app/ios/Runner/Info.plist` (`NSSupportsLiveActivities` = YES), `app/ios/Runner.xcodeproj/project.pbxproj` (via the script)

**Interfaces:**
- `struct TrainActivityAttributes: ActivityAttributes { struct ContentState: Codable, Hashable { var departs: Double?; var status: String; var platform: String?; var where: String?; var cancelled: Bool }; var title: String; var station: String }` — `where` is a Swift keyword: declare it with backticks.
- Lock screen: title, countdown `Text(timerInterval: Date()...departs)` only when `departs` is set and in the future (a reversed range crashes the widget); otherwise the status text, platform tile, where line. Dynamic Island compact: platform / countdown; minimal: platform; expanded: full.
- Script: Ruby `xcodeproj` adds an app-extension target `FollowActivity` (bundle id `com.jfcaba.platform.FollowActivity`, team `JH8NFJ6XW7`, automatic signing, iOS 16.1, `SWIFT_VERSION` 5.0), embeds it in Runner ("Embed Foundation Extensions"), adds the shared Swift file to both, adds `FollowActivity` to Runner's target dependencies; extension Info.plist has `NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`. Idempotent.
- [ ] **Step 1:** Run the script; `flutter build ios --simulator --debug` → succeeds.
- [ ] **Step 2:** Simulator (iOS 17+): follow a train with the API pointed at the real server, lock screen shows the activity (screenshot via `xcrun simctl io booted screenshot`); APNs pushes don't reach simulators, so verify updates with `xcrun simctl push` and a liveactivity payload.
- [ ] **Step 3:** Commit `feat(ios): Live Activity widget`.

### Task 10: Ship

- [ ] Deploy API (git pull + `docker compose up -d --build`, outside UK peaks); `/health` ok; `follow: on` in logs.
- [ ] Version `1.4.0+12`; update store texts (What's New) in `docs/store/listing-en.md`; `docs/store/estado.md`.
- [ ] Real iPhone test by the user (TestFlight): follow, lock the phone, see updates. Android test build.
- [ ] Commit `chore: 1.4.0+12`.
