# Your train, live (What Platform 1.4) — design

## Why
User request (21-11-2026): while following a train, see it live "like waiting for an Uber": on the
home screen of the app and outside it (iOS lock screen / Dynamic Island, Android ongoing
notification). The user asked to just build it ("lánzate"); the calls below are Claude's.

## What the user sees (Claude's call)
The followed train, with:
- **countdown** to its expected departure ("12 min", "Due", "Delayed", "Cancelled"),
- **platform** (or "Platform not yet shown"),
- **status** ("On time", "Exp 16:48"),
- **where the train is now** (the Uber part): "2 stops away · left Stevenage 16:31",
  "Next stop: here · left Hitchin 16:38", "Not yet left London Kings Cross" (origin), or nothing when
  Darwin gives no service id / no previous stops (the train starts here: "Starts here").

Where:
1. **App home:** at the followed train's station the big next-train card (already the followed one)
   gets the "where" line. At any other station a compact "Your train" strip sits above the board
   (time + destination, platform pill, countdown, where); tap → opens the followed station.
2. **iOS Live Activity** (iOS 16.1+): lock screen + Dynamic Island, started when the user follows,
   updated by APNs `liveactivity` pushes from the server, ended when the follow ends. The countdown
   is drawn by iOS from a date, so it ticks without pushes. iOS < 16.1: push alerts only (as today).
3. **Android ongoing notification** (the existing foreground-service one): title
   "16:42 to Peterborough · Plat 10", text "12 min · On time · 2 stops away (left Stevenage)".

## Data: where the train is (decided from a live Darwin sample, 21-11-2026)
Darwin Service Details for a service id from a station's board lists `previousCallingPoints`
(stops before that station) with `at` ("On time" or "HH:MM") once passed, `et` while not.
- Last previous stop with `at` set → `lastStop` (name) and `lastAt` (actual time: `at` when HH:MM,
  else its `st`); `stopsAway` = previous stops after it + 1 (this station).
- No previous stop has `at` → `notStarted` = first previous stop's name (the origin).
- No previous stops → `startsHere: true`.
API `/service/{id}` adds `"position": {...}` (one of the three shapes) next to `portions`. Older apps
ignore it.

## Server (api/)
- `POST /follow` accepts optional `"activityToken"` (hex 64–200, same rule as `token`). Re-POSTing the
  same train with a new or added activity token updates it without resetting the baseline.
- Poller, per tick (30 s), for follows with an activity token: builds the content state from the board
  reading plus the position (one Service Details call per such follow, at most every 60 s, from the
  poller's own Darwin slots; errors keep the last position). Sends a `liveactivity` push only when the
  state changed (no repeats). On any follow end (left board, cancelled + 2 min, 3 h, DELETE, gone)
  sends `event: end` with `dismissal-date` now + 15 min (train gone) or now (DELETE).
- APNs: topic `com.jfcaba.platform.push-type.liveactivity`, `apns-push-type: liveactivity`,
  priority 10 for platform/cancel changes, 5 otherwise. Payload
  `{"aps":{"timestamp":<now>,"event":"update"|"end","content-state":{...},"stale-date":<departs+600>}}`.
- Content state (JSON, also built by the app for the first state):
  `{"departs": <epoch s of expected departure, null if unknown>, "status": "On time"|"Exp 16:48"|
  "Delayed"|"Cancelled"|"", "platform": "10"|null, "where": "2 stops away · left Stevenage 16:31"|null,
  "cancelled": bool}`. Epoch seconds, not Date, so Swift decoding is unambiguous.
- Same privacy rules: tokens in memory only, never logged.

## App (Flutter)
- `TrainPosition` model + `whereText(position)` in `domain/`, shared by card, strip, Android text and
  the Live Activity's first state (same strings as the server's Python port).
- iOS: `LiveTrainActivity` wrapper over a method channel `whatplatform/activity`
  (`start(attrs, state) → bool`, `update(state)`, `end()`, callback `activityToken(hex)`); PushFollower
  starts it after a 200 follow, sends the activity token with a re-POST when iOS gives it, ends it on
  stop/clear. Native: Widget Extension `FollowActivity` (SwiftUI, iOS 16.1), `NSSupportsLiveActivities`.
- Android: FollowLoop also fetches the position (every 60 s, serviceId only) and passes it to the
  ongoing text.
- Home: a `FollowTracker` (ChangeNotifier) polls, while the app is in the foreground and a train is
  followed, the followed station's board (when not the one on screen) and the position (60 s).

## Non-goals
Andén (separate design after this ships), several trains, push-to-start, Live Activity on iPad,
Android 16 progress-style notifications, a map.

## Approaches considered
1. **Server-pushed Live Activity reusing the follow poller (chosen):** works with the app killed; the
   server already polls and diffs.
2. App-updated Live Activity only (no server pushes): stops updating once iOS suspends the app.
3. Third-party (Firebase) Live Activity push: adds an account and a dependency; anti-goal.
