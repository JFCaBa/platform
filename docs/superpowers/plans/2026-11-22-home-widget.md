# Home screen widget Implementation Plan

**Goal:** iOS and Android home screen widget with the next trains of the last station, refreshing by itself.

**Architecture:** the app writes station + filters + its board via home_widget; each widget fetches
`/departures/{CRS}` itself and resolves times with the same rule on both platforms. Ported from
Andén's widget (tren repo: app/ios/FollowActivity/NextTrains*.swift,
app/android/.../NextTrains*.kt).

**Tech Stack:** Flutter + home_widget ^0.10.0, WidgetKit (existing FollowActivity extension),
Android AppWidget + WorkManager 2.11.2.

**Spec:** docs/superpowers/specs/2026-11-22-home-widget-design.md

## Global Constraints
- Version 1.5.0+13; work on branch `feat/home-widget` (1.4 (12) is still in review).
- App Group `group.com.jfcaba.platform` on Runner and FollowActivity.
- User-Agent `WhatPlatform/1.5` (API rejects requests without it).
- English UI copy.

## Review Focus
- Midnight: a 23:58 train seen at 00:01 must be "yesterday", a 00:05 train at 23:50 "tomorrow".
- Station changed in the app while the widget holds a fetched board for the old one: never show it.
- Old app snapshot (or garbage JSON): widget shows the empty message, no crash.
- API 429/5xx/offline: keep the saved board; header shows its age when > 10 min.
- Filters whose destinations are not on the board: empty list, not all trains.

---

### Task 1: Dart publisher
**Files:** Create `app/lib/widget/home_widget.dart`; modify `app/lib/main.dart`, `app/pubspec.yaml`
(home_widget, version 1.5.0+13), `app/lib/config.dart` (userAgent `WhatPlatform/1.5`);
test `app/test/home_widget_test.dart`.
- `Map<String,Object?> widgetSnapshot(Station s, Set<String> filters, Board? board, List<Departure> services)`
  → spec shape (services capped at 40; board null → `board: null`).
- `class WidgetPublisher { publish(...) }` writes JSON + `updateWidget` only when the JSON changes;
  write errors reset the dedupe.
- main.dart: `HomeWidget.setAppGroupId` on iOS; controller listener publishes.
- Tests: shape and cap; same snapshot twice → one write; filter change → new write; failed write retried.

### Task 2: iOS widget
**Files:** create `app/ios/FollowActivity/NextTrainsData.swift` (Foundation only),
`NextTrainsWidget.swift`, `FollowActivity.entitlements`; modify `FollowActivityBundle.swift`,
`Runner/Runner.entitlements`; tool `app/tools/ios/add_next_trains_widget.rb` (xcodeproj gem).
- `departureAt(_ hhmm: String, now: Date) -> Date?`, `resolve(snapshot:fetched:now:) -> [ShownTrain]`,
  `parseBoard(Data, fetchedAt:)`, `refreshBoard(crs:completion:)`, `sampleSnapshot(now:)`.
- Test harness in scratchpad (swiftc) covering the Review Focus cases + real API parse.
- Verify: simulator build, renders of small and medium.

### Task 3: Android widget
**Files:** create `NextTrainsData.kt` (pure Kotlin), `NextTrainsWorker.kt`, `NextTrainsWidgetProvider.kt`,
layouts `next_trains_widget.xml` / `_preview.xml`, `xml/next_trains_widget_info.xml`, drawables,
colors (day/night), strings; manifest receiver; gradle work-runtime + junit + org.json test deps.
- JVM tests `NextTrainsDataTest.kt` for the same cases as Task 2.
- Verify on the emulator: gallery preview, widget fills, refresh by the worker with the app closed.

### Task 4: Ship
- `flutter test`, `flutter analyze`; consenso on the diff; commit on the branch; docs/store/estado.md
  "1.5.0 (13)" section. iOS archive/upload and AAB only when the user asks (1.4 first).
