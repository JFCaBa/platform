# Play Console: foreground service declaration (What Platform 1.1)

Play Console → App content → Foreground service permissions. Required because 1.1 declares
`FOREGROUND_SERVICE_DATA_SYNC` (manifest: `android:foregroundServiceType="dataSync"`).

**Foreground service type:** Data sync.

**Which feature uses it (task description):**
Following a train. When the user follows a train (touch and hold it on the departure board, or tap
"Follow this train"), the app keeps checking that station's live departures every 30 seconds and
alerts the user if the train's platform changes, its expected time changes or it is cancelled.
Platform changes at British stations are often announced only a few minutes before departure,
so the check has to keep running while the user is walking to the station with the app closed.
The service shows an ongoing notification with the train's current platform and status and a
Stop button, and stops by itself when the train leaves, 2 minutes after a cancellation, after
3 hours at most, or when the user taps Stop.

**User impact if the task is deferred or interrupted by the system:**
The user would miss a last-minute platform change or cancellation and could miss their train.
WorkManager's 15-minute minimum interval is too coarse for this.

**Is it user initiated?** Yes: it only starts when the user explicitly follows a train, and the
user can stop it at any time from the notification or the app.

**Video:** `~/Desktop/WhatPlatform-follow-demo.mp4` (55 s, emulator, test data from a local copy
of our API so a platform change happens on camera). Play needs a link: upload it to YouTube as
**Unlisted** and paste the link.

## Data safety

Unchanged: no data collected or shared. The stops request carries Darwin's train id; following
polls the same anonymous station endpoint; alerts are local notifications. No new permissions
beyond POST_NOTIFICATIONS / FOREGROUND_SERVICE / FOREGROUND_SERVICE_DATA_SYNC / WAKE_LOCK.

## Why dataSync (17-11-2026)

developer.android.com (FGS types) lists "Fetch data" and "Transfer data between a device and the
cloud over a network" under dataSync. If Play rejects it, the fallback is `specialUse` with a
`PROPERTY_SPECIAL_USE_FGS_SUBTYPE` explanation (manifest-only change).
