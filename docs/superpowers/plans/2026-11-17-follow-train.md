# Follow a Train Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an Android user follow one train and get local notifications when its platform, expected time or status changes, with the app closed.

**Architecture:** Pure Dart logic (`lib/follow/follow_logic.dart`) compares two readings of the followed departure and decides alerts, the ongoing text and when to stop. `FollowLoop` (`lib/follow/follow_loop.dart`) runs one poll per tick with injected fetch/notify/clock, so it is unit-tested. `FollowService` (`lib/follow/follow_service.dart`) is the only plugin glue: an Android foreground service (flutter_foreground_task) whose task handler drives a `FollowLoop` every 30 s, and flutter_local_notifications for the sounding alerts. The UI talks to a small `Follower` interface, faked in widget tests.

**Tech Stack:** Flutter 3.50, flutter_foreground_task ^11.0.3, flutter_local_notifications ^23.0.2.

**Spec:** `docs/superpowers/specs/2026-11-17-follow-train-design.md`

## Global Constraints

- Android only: on iOS `Follower` is null, rows are not tappable, no follow UI.
- No server change; poll `GET /departures/{crs}` via the existing `DeparturesClient.fetch` every 30 s.
- A train is identified by (crs, std, destination). One followed train at a time.
- No alert for the first reading. Network errors are silent and polling continues.
- `RateLimited` → no polls for 5 min (`rateLimitBackoff`).
- Stop when the train is absent from a successfully fetched board, 2 min after it is first seen cancelled, 3 h after following started, or on Stop.
- Copy (exact): snackbar `Following 08:12 to Cardiff Central` with action `Undo`; on unfollow `Stopped following`; permission denied `Allow notifications to follow a train`; ongoing `08:12 to Cardiff Central · Plat 3 · On time`; alerts `Platform 5` (first platform), `Platform changed: 3 → 5`, `Now expected 08:19`, `Now on time`, `Delayed`, `Cancelled` / `Cancelled: <reason>`. Alert title: `08:12 to Cardiff Central`.
- Version `1.1.0+5`. Nothing collected or sent anywhere new.

## Consenso rulings (round 0)

- Ticks are serialized: a tick that starts while another runs returns true without fetching.
- `alert`/`ongoing` callbacks return `Future<void>` and are awaited; a failing callback is caught and does not count as a fetch error.
- Deadlines (3 h, 2 min after cancelled) are checked at the start of every tick, before the backoff and before fetching.
- A first reading already cancelled gives no alert but starts the 2-min linger.
- "Gone" means absent from two successful boards in a row (Darwin keeps cancelled trains on the board; one blip must not stop).
- `statusText`/`platformText` move to `lib/domain/departure_text.dart` (re-exported by `departure_row.dart`); `rateLimitBackoff` moves to `lib/data/departures.dart`. No UI import from follow code.
- FollowService: follow() stops a running service before saving the new train and starting again; the handler builds its loop in `onStart` from saved data. The handler initialises flutter_local_notifications in `onStart`. When the handler stops itself it sends `'stopped'` to main (`FlutterForegroundTask.sendDataToMain`); FollowService listens (`addTaskDataCallback`), clears `current`, notifies; it also re-syncs from `isRunningService` + saved data on app resume.
- Rejected: adaptive polling interval (YAGNI for a 3-h max follow); Play dataSync declaration is a release step, already in the spec.

## Review Focus

1. The followed train's expected time changes between polls → it is still found (identity ignores etd). Test in Task 1.
2. The board fetch fails several times in a row → no stop, no alert, next good poll compares with the last good reading. Test in Task 2.
3. User changes station while following → following continues; the bell shows only on the followed station's board. Test in Task 3.
4. Train seen cancelled → exactly one `Cancelled` alert, not repeated each poll, stop 2 min later. Test in Task 2.
5. App reopened while a follow is running → the bell is on the right row (Follower reads the saved train). Checked manually in Task 4.

---

### Task 1: Follow logic

**Files:**
- Create: `app/lib/follow/follow_logic.dart`
- Test: `app/test/follow_logic_test.dart`

**Interfaces:**
- Consumes: `Departure`, `Board` (`lib/data/departures.dart`), `statusText`, `platformText` (`lib/ui/departure_row.dart`; move both to `follow_logic.dart`'s neighbour only if an import cycle appears — otherwise import them).
- Produces:
  - `class FollowedTrain { final String crs, std, destination; Map<String,dynamic> toJson(); factory FollowedTrain.fromJson(Map); bool matches(Departure d); String get title; }` — `title` = `'$std to $destination'`; `matches` compares std and destination only; value equality on all three fields.
  - `Departure? findFollowed(Board b, FollowedTrain t)` — `b.crs == t.crs` and first `matches`, else null.
  - `String ongoingText(FollowedTrain t, Departure d)` — title, then `platformText(d)` and `statusText(d)` when non-empty, joined by ` · `.
  - `List<String> changes(Departure before, Departure after)` — alert bodies, in order platform then time; if `after` is cancelled and `before` was not, returns only `['Cancelled']` or `['Cancelled: <cancelReason>']`.

- [ ] **Step 1: Write failing tests** `app/test/follow_logic_test.dart` with a `dep({std='08:12', dest='Cardiff Central', etd, platform, cancelled=false, cancelReason})` helper:
  - `matches ignores etd and platform`: `t.matches(dep(etd: '08:19', platform: '5'))` true; other std or destination false.
  - `findFollowed only on its station`: board crs `CDF` with the train → found; same services with crs `NWP` → null.
  - `ongoingText`: platform 3 + 'On time' → `'08:12 to Cardiff Central · Plat 3 · On time'`; no platform, no etd → `'08:12 to Cardiff Central'`.
  - `changes`: null→'5' → `['Platform 5']`; '3'→'5' → `['Platform changed: 3 → 5']`; 'On time'→'08:19' → `['Now expected 08:19']`; '08:19'→'08:19' → `[]`; '08:19'→'On time' → `['Now on time']`; 'On time'→'Delayed' → `['Delayed']`; '3'→null platform → `[]`; '3'→'5' and 'On time'→'08:19' → both, platform first; not cancelled→cancelled with reason 'a signalling problem' → `['Cancelled: a signalling problem']`; cancelled→cancelled → `[]`; etd 'Cancelled' counts as cancelled.
  - `FollowedTrain json round-trip` keeps equality.
- [ ] **Step 2: Run** `cd app && flutter test test/follow_logic_test.dart` — Expected: FAIL (file not found).
- [ ] **Step 3: Implement** `follow_logic.dart` with the signatures above.
- [ ] **Step 4: Run** the same — Expected: all pass.
- [ ] **Step 5: Commit** after consenso: `feat(app): follow logic for train changes`.

### Task 2: Follow loop

**Files:**
- Create: `app/lib/follow/follow_loop.dart`
- Test: `app/test/follow_loop_test.dart`

**Interfaces:**
- Consumes: Task 1; `RateLimited`, `rateLimitBackoff` (`lib/app_controller.dart`; import the const or redefine `const followRateLimitBackoff = Duration(minutes: 5)` if importing drags the controller in — prefer importing).
- Produces:
  - `class FollowLoop { FollowLoop({required FollowedTrain train, required DateTime startedAt, required Future<Board> Function(String crs) fetch, required Future<void> Function(String title, String body) alert, required Future<void> Function(String text) ongoing, required DateTime Function() clock}); Future<bool> tick(); }`
  - `tick()` returns false when following must stop (caller then stops the service), true otherwise. Constants `followMaxDuration = Duration(hours: 3)`, `cancelledLinger = Duration(minutes: 2)`.

- [ ] **Step 1: Write failing tests** with a queue of fetch results (Board or thrown exception) and a mutable clock:
  - `first reading updates ongoing, no alert`.
  - `platform change alerts once`: readings plat 3 then 5 then 5 → one alert `('08:12 to Cardiff Central', 'Platform changed: 3 → 5')`.
  - `errors are silent and keep the last good reading`: plat 3, throw, throw, plat 5 → ticks return true, one alert 3 → 5.
  - `rate limited skips fetches for 5 min`: throw `RateLimited`; tick at +1 min does not call fetch; at +5 min it does.
  - `train gone from two good boards stops`: one board without it → true; a second → false; a board without it, then with it, then without → still true.
  - `cancelled alerts once and stops 2 min later`: on time at t0, cancelled at t0+30 s → one alert; tick at +1 min true, no second alert; tick at +2 min 30 s false.
  - `first reading cancelled: no alert, stops after 2 min`.
  - `deadline wins over backoff`: RateLimited at 2 h 58 min, tick at 3 h → false without fetching.
  - `overlapping ticks fetch once`: fetch held by a Completer, second tick returns true, fetch called once.
  - `stops after 3 h` even when the train is still on the board.
- [ ] **Step 2: Run** `flutter test test/follow_loop_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** `FollowLoop`.
- [ ] **Step 4: Run** — Expected: pass.
- [ ] **Step 5: Commit** after consenso: `feat(app): follow loop`.

### Task 3: Follow from the board

**Files:**
- Create: `app/lib/follow/follower.dart`
- Modify: `app/lib/ui/departure_row.dart` (optional `followed` bool → `Icons.notifications_active` before the platform; optional `onTap`, wrap in `InkWell` only when non-null)
- Modify: `app/lib/ui/home_screen.dart` (`HomeScreen({..., Follower? follower})`; rows get `onTap` when follower non-null; listen to follower)
- Test: `app/test/home_screen_test.dart` (add a `FakeFollower` in `test/support.dart`)

**Interfaces:**
- Produces: `abstract class Follower implements Listenable { FollowedTrain? get current; Future<bool> follow(FollowedTrain t); Future<void> stop(); }` — `follow` returns false when notification permission is denied.

- [ ] **Step 1: Write failing widget tests** (station CDF board fixture as the existing tests use; pick a row by its std text):
  - `tapping a row follows it`: tap → `fake.current == FollowedTrain(crs, std, dest)`, snackbar `Following <std> to <dest>`, bell icon on that row.
  - `Undo stops following`; `tapping the followed row stops` with snackbar `Stopped following`.
  - `permission denied`: fake returns false → snackbar `Allow notifications to follow a train`, no bell.
  - `bell only on the followed station`: fake.current with another crs → no bell on this board.
  - `no follower, rows are not tappable`: no `InkWell` ancestor of a row's std text.
- [ ] **Step 2: Run** `flutter test test/home_screen_test.dart` — Expected: new tests FAIL.
- [ ] **Step 3: Implement** Follower, row and screen changes.
- [ ] **Step 4: Run** full `flutter test` — Expected: all pass.
- [ ] **Step 5: Commit** after consenso: `feat(app): follow a train from the board`.

### Task 4: Android service and wiring

**Files:**
- Create: `app/lib/follow/follow_service.dart`
- Modify: `app/pubspec.yaml` (deps, `version: 1.1.0+5`), `app/lib/main.dart`, `app/lib/config.dart` (`userAgent = 'WhatPlatform/1.1'`), `app/android/app/src/main/AndroidManifest.xml`, `app/android/app/build.gradle.kts` (core library desugaring for flutter_local_notifications).

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `class FollowService extends ChangeNotifier implements Follower { static Future<FollowService> create(); }`; top-level `@pragma('vm:entry-point') void followCallback()` setting a `TaskHandler` that builds `FollowLoop` from the saved train (`FlutterForegroundTask.saveData('train', jsonEncode(..))`, `'startedAt'`) and on each repeat event runs `tick()`, updating the service notification with `ongoing` text and stopping the service when `tick()` is false. Alerts via flutter_local_notifications channel `train_changes` (importance high). Ongoing notification channel `following` (importance low), button `Stop`.

- [ ] **Step 1:** `flutter pub add flutter_foreground_task flutter_local_notifications`; manifest: `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `WAKE_LOCK`, and the plugin's `<service android:name="com.pravera.flutter_foreground_task.service.ForegroundService" android:foregroundServiceType="dataSync" android:exported="false" />`; desugaring in gradle.
- [ ] **Step 2:** Implement `FollowService` (interval 30 s via `ForegroundTaskEventAction.repeat(30000)`, request notification permission in `follow`, restore `current` from saved data in `create()` when the service is running, clear it when the service stops). In `main.dart` create it only when `Platform.isAndroid` and pass it to `HomeScreen`.
- [ ] **Step 3: Verify** `flutter analyze` → no issues; `flutter test` → all pass; `flutter build apk --release` → succeeds.
- [ ] **Step 4: Manual check** on an Android emulator/device if one is available: follow a train, close the app, see the ongoing notification; reopen and see the bell (Review Focus 5); Stop removes it. If no device, say so.
- [ ] **Step 5: Commit** after consenso: `feat(app): follow service on Android, 1.1.0+5`; copy APK to `~/Desktop/WhatPlatform-1.1.0.apk`.
