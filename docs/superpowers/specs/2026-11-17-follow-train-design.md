# Follow a train (What Platform 1.1) — short design

## Why
Feedback from a UK tester (17-11-2026): platform changes are the norm in the UK and people miss them.
Let the user "follow" one train and tell them, with a local notification, when its platform,
expected time or status changes. Still KISS: one tap, no account, nothing sent anywhere.

## Goals
- Follow one train from the board; get an alert when it changes: platform assigned or changed,
  expected time changed, cancelled.
- Works with the app closed (Android). An APK for the tester today.
- Keep "no data collected": everything runs on the phone, local notifications only.

## Non-goals (this version)
- iOS background following (needs a Live Activity or push; later). On iOS the follow option is hidden.
- Server push, accounts, following several trains, following from another station.
- Any server change.

## Approaches considered
1. **On-device follow (chosen).** An Android foreground service polls the station board while a
   train is followed and posts local notifications. No server change, no data collected, doable today.
   Cost: Android only for now; Play will need a foreground-service declaration before release.
2. Server push (FCM/APNs). Works on iOS too, but the server must store device tokens (privacy
   declarations change), plus Firebase and certificates. Not for today.
3. Periodic background work (WorkManager, 15 min minimum). Too coarse: platforms change minutes before departure.

## Design
- **UI.** Tapping a departure row follows it: a bell icon shows on that row and a snackbar says
  "Following 08:12 to Cardiff Central" with Undo. Tapping the followed row again stops following.
  Only one train at a time; following another replaces it. First follow asks for notification
  permission (Android 13+); if denied, nothing is followed and a snackbar explains why.
- **Identity.** A train is the board's (station CRS, `std`, destination). No serviceID: avoids an API change.
- **Service.** While following, a foreground service polls `GET /departures/{crs}` every 30 s
  (the nginx cache window) and keeps an ongoing, silent notification with the current state,
  e.g. "08:12 to Cardiff Central · Plat 3 · On time", with a Stop action.
- **Alerts.** A separate, sounding notification when, compared with the last poll:
  platform appears or changes ("Platform changed: 3 → 5"), expected time changes
  ("Now expected 08:19"), or it is cancelled ("Cancelled", with the reason if any).
  No alert for the first reading. Network errors are silent; after them polling just continues.
- **Stops by itself** when the train is gone from the board (departed), 2 min after it is cancelled,
  3 h after following started, or on Stop. Following survives the app being closed, not a reboot.
- **Rate limit (429)**: wait 5 min, as the app does today.
- **Version** 1.1.0+5. Release APK to the Desktop for the tester.

## Left to the builder
Plugin choice (e.g. flutter_foreground_task + flutter_local_notifications), how the service
shares the board-diff logic with the app (pure Dart function, unit-tested), notification icons.
