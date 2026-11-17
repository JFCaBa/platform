# Follow a train on iOS (What Platform 1.2) — design

## Why
UK tester feedback (17-11-2026): platform changes are the norm in the UK and people miss them.
Android 1.1 already follows one train on the phone (foreground service polling every 30 s, local
notifications). iOS cannot poll in the background (BGAppRefresh runs when iOS decides, often hours
late), so on iOS the follow option is hidden today. The only reliable way is for the server to
watch the train and tell the iPhone through Apple push (APNs).

## Phasing (decided)
1. **This design: push alerts on iOS.** The server watches the followed train and sends a normal
   push notification when its platform, expected time or status changes.
2. **Later, separate design: Live Activity** (lock screen / Dynamic Island) updated by push, reusing
   the server's follow list and diff from phase 1. Not specified here, but phase 1 must not block it
   (keep the server's per-follow state generic enough to also hold a Live Activity push token).

## Goals
- iOS user follows one train from the board, exactly as on Android (same gesture and panel button,
  same bell on the row, same snackbar with Undo), and gets an alert when, compared with the last
  reading: a platform appears or changes, the expected time changes, or it is cancelled.
  Alert texts are the Android ones (`changes()` in `app/lib/follow/follow_logic.dart`).
- Works with the app closed or killed.
- No Firebase, no accounts, no third-party push service.

## Non-goals
- Android changes: Android keeps its on-device foreground service. (Moving Android to server push
  later is possible; not now.)
- Live Activity (phase 2), several trains, following from another station, notification action
  buttons ("Stop" from the notification). Stopping is done in the app.
- An ongoing "current state" notification like Android's: iOS has no equivalent; phase 2 covers it.

## Anti-goals
- Anything that links a follow to a person: no logs of tokens, IPs or trains, no persistence.
- Alert spam: no alert on the first reading, none on repeated identical readings.

## Privacy (decided)
The server keeps the APNs device token while the train is followed, so on iOS the App Privacy label
changes from "Data Not Collected" to **Identifiers → Device ID · Not Linked to You · App
Functionality** (Apple: data is "collected" if it leaves the device and is kept longer than needed to
answer the request in real time). Play Data safety is unchanged (Android does not send anything).
- Tokens live **only in memory**. Nothing written to disk, no token/train/IP in logs (keep the
  current "requests are not logged" rule).
- A follow is deleted when the train leaves the board, 2 min after it is cancelled, 3 h after it
  started, or when the user stops it. A server restart forgets all follows (see app re-sync).
- Privacy policy (site/) gets two sentences saying exactly this.

## Approaches considered
1. **Server push alerts now, Live Activity later (chosen).** Small native code, mostly Python in the
   existing API; the user gets alerts soonest and the server work is reused by phase 2.
2. Live Activity first: best fit for "my train" but needs a SwiftUI widget extension inside the
   Flutter app; slower to build and to get through review.
3. On-device background refresh: too coarse and unreliable for a change minutes before departure.

## Design

### Server (api/, same container)
- `POST /follow` body `{"token", "env": "production"|"sandbox", "crs", "std", "destination",
  "serviceId"?}`. Upsert keyed by token (one train per device; a new train replaces the old one).
  Validate: token hex 64–200 chars, CRS known, `std` HH:MM, destination ≤ 100 chars, serviceId matches
  `SERVICE_ID_RE`. Before accepting, read the board once: if the train is not on it → `410` (app
  clears its follow). Otherwise `200` and that reading becomes the baseline (no alert).
- `DELETE /follow` body `{"token"}` → `204` whether or not it existed.
- Re-POSTing the same train keeps the existing baseline and start time (idempotent, used by the
  app's re-sync), so it does not re-alert or extend the 3 h limit.
- A background thread polls every 30 s, **one Darwin board call per distinct CRS** among the follows
  (shared with the board endpoint's slot limit), finds each train (by serviceId when both sides have
  one, else std + destination: same rule as `FollowedTrain.matches`), diffs with the last reading
  using a Python port of `changes()`, and sends one push per alert text. Network/Darwin errors are
  silent; polling continues. Darwin 429 → that cycle is skipped for 5 min.
- End rules as above (gone from board, cancelled + 2 min, 3 h, DELETE).
- Cap: 500 active follows and **50 distinct stations** being polled (a follow that would add a
  51st station → `503`). Worst case 100 Darwin calls/min from the poller. The poller has its
  **own pool of 2 Darwin slots**, so polling never takes the board endpoint's slots and user
  boards are never starved. (Claude's call; the Rail Data Marketplace quota for the key is
  checked while planning and these numbers lowered if needed.)
- Abuse (Claude's call): nginx `limit_req` per IP on `/follow` (in nginx memory only, nothing
  logged), the caps above, and a token is validated loosely (hex, 64–200 chars: Apple says token
  length may change). Fake tokens die at the first APNs rejection or at 3 h.
- Restarts (accepted 17-11-2026): every deploy or crash forgets all follows; the app restores its
  follow the next time it is opened. Deploy the API outside UK commuting peaks.
- APNs: HTTP/2 to `api.push.apple.com` (or `api.sandbox.push.apple.com` for `env: sandbox`),
  token auth (ES256 JWT from a .p8 key, refreshed every ~50 min), topic `com.jfcaba.platform`,
  `apns-push-type: alert`, `apns-expiration` = now + 10 min (a stale platform alert is useless), payload `{"aps":{"alert":{"title":"08:12 to Cardiff Central",
  "body":"Platform changed: 3 → 5"},"sound":"default"}}`. APNs `410`/`400 BadDeviceToken` → drop
  the follow. Secrets in `/opt/platform/.env`: `APNS_KEY` (the .p8 contents), `APNS_KEY_ID`,
  `APNS_TEAM_ID`. `APNS_KEY` is stored **base64-encoded** on one line (env_file can't hold the
  multi-line PEM); noted in `deploy/README.md`. Without them `/follow` answers `503`.
- Dependencies (builder's call on exact pins): the API is stdlib-only today; HTTP/2 and ES256 need
  third-party code. My call: a pinned `requirements.txt` (e.g. `httpx[http2]` + `PyJWT[crypto]`)
  installed in the Dockerfile.
- nginx: proxy `/follow` without caching, with a modest `limit_req` per IP; still no access log.

### App (app/)
- New `PushFollower implements Follower` used on iOS (Android keeps `FollowService`). The follow UI
  stops being hidden on iOS.
- Getting the token without Firebase: a small method channel in `AppDelegate.swift`
  (`registerForRemoteNotifications`, returns the hex token or an error). Push Notifications
  capability / `aps-environment` entitlement added. Notification permission asked on first follow
  (alert + sound); denied → nothing followed, snackbar explains, as on Android.
- `follow(t)`: permission → token → `POST /follow` → on 200 store `{train, startedAt}` in
  shared_preferences and show the bell. `410` → snackbar "That train has left". Network error →
  snackbar, nothing followed.
- `stop()`: `DELETE /follow`, clear local state (clear locally even if the request fails).
- `sync()` (app start / resume): if a local follow exists and started < 3 h ago, re-POST it (heals a
  server restart); `410` or > 3 h → clear it. `env` is `sandbox` in debug builds, `production` in
  release/TestFlight.
- Tapping a notification just opens the app.

### Stores
- Version 1.2.0 (after 1.1.0 is through review). App Privacy label as above; description and
  review notes mention following with push; privacy policy updated (site/, git pull on the VPS).
- Prerequisite (user, in the developer portal with Claude filling forms): create an APNs auth key
  (.p8) in team 338 TAC, S.L., enable Push Notifications on `com.jfcaba.platform`, put the key in
  `/opt/platform/.env`.

### Order
Server first (with a fake APNs client in tests), deployed and checked before any app build with
the iOS follow UI goes out. The real-device e2e waits for the .p8 key; if it doesn't exist yet,
everything up to that test is built and the plan stops there.

### Testing
- Server: unit tests for the Python `changes()` port driven by the **same cases** as the Dart tests
  (shared JSON fixture), follow store end rules with an injected clock, endpoint validation, APNs
  client against a fake.
- App: `PushFollower` against a fake API; e2e on a real iPhone with a sandbox token (the simulator
  can't receive real APNs pushes from the server).

## Left to the builder
Exact library pins, module layout of the follow store/poller, JWT caching details, how the fixture
is shared between Dart and Python tests, nginx rate numbers.
