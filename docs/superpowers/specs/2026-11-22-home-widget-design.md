# Home screen widget (1.5) — design

**Why:** the user asked for Andén's home screen widget in What Platform: next trains of the last
station at a glance, refreshing by itself like Weather or Stocks, with a gallery preview.

## Goals
- iOS (small, medium) and Android (resizable, 4x2 target) widget: next 4 trains of the station the
  app last showed, with the app's destination filters.
- Refreshes by itself without opening the app: it asks our API for the board.
- A real preview in the widget gallery (sample: London Euston).
- Tap opens the app.

## Non-goals
- Choosing a station in the widget (configuration intent). Later, if asked.
- Lock screen / StandBy families.
- Any change to the API or the VPS.

## Approach (decided)
Andén's widget had to mix a timetable with Renfe's real time. Here the API already gives the live
board, so the widget simply fetches `GET https://api.whatplatform.uk/departures/{CRS}` itself
(User-Agent `WhatPlatform/1.5`, 10 s timeout; nginx caches 30 s). Rejected: the app pushing data
only (goes stale with the app closed); a server-pushed widget (WidgetKit push needs iOS 26 + server
work, nothing equivalent on Android).

## Data
- App → widget (App Group `group.com.jfcaba.platform` on iOS, home_widget prefs on Android), key
  `next_trains`, written when the station, filters or board change:
  `{crs, name, filters: [dest...], board: {generatedAt: epochSec, services: [{std, etd, platform,
  destination, cancelled}]}}` (at most 40 services, from the base board plus loaded pages).
- Widget's own fetch, key `widget_board`: `{crs, fetchedAt, generatedAt, services: [...]}`.
- The widget uses whichever board for the app's current `crs` has the newer `generatedAt`.

## Rules (same in Swift and Kotlin)
- Times are London times "HH:MM"; the instant is the one on yesterday/today/tomorrow's London date
  nearest to the board's `generatedAt` (not now: a board kept offline overnight must not come back
  as today's trains).
- Departure instant = expected time if `etd` is HH:MM, else `std`.
- Shown: services matching the filters (all if none), departure ≥ now − 60 s; cancelled ones stay
  until their `std`. Sorted by departure instant. First 4.
- Late = expected HH:MM ≠ std, or `etd == "Delayed"` → amber. Cancelled (`cancelled` or
  `etd == "Cancelled"`) → struck through and dimmed, no platform.
- Board older than 10 min → header adds a muted "updated HH:MM" (London time).

## Look
- Small: per row `HH:MM` (expected if late, amber) and a platform pill. No destination.
- Medium (iOS): `HH:MM`, destination (one line, truncated), platform pill, then "Due" /
  "N min" / "Cancelled" / "Delayed" (amber when late); iOS redraws it every minute from its timeline.
- Android: same row but the last column is a status ("On time" / "Late" / "Delayed" /
  "Cancelled"): Android only redraws every ~15 min with the app closed, so a countdown would go stale.
- Brand blue `#1E3A8A` pill with white text; amber `#B45309` (dark `#FBBF24`).
- Empty: "Open What Platform to see the next trains".

## Refresh
- iOS: `getTimeline` fetches (at most once a minute, else the saved one), 120 per-minute entries,
  policy `.after(now + 15 min)`. Gallery (`isPreview` with no real trains) and placeholder use the
  sample.
- Android: WorkManager periodic job every 15 min with a CONNECTED constraint (Android cuts the network
  of background jobs without it — learnt in Andén), one-off job on enable; an inexact alarm at the
  first train's departure + 30 s repaints; `updatePeriodMillis` 30 min. `previewLayout` (Android 12+)
  + `previewImage`.

## Left to the builder
Exact spacing and font sizes, within the Andén widget's proportions.
