# Store screenshots and app preview (UK departure board)

All screens come from the real app driven by `app/integration_test/store_test.dart`: a fixed clock
(Friday 20-11-2026, 08:12 at London King's Cross) and a chosen board (one train late, one cancelled,
platforms), stops and a fake follower. The station list is the bundled `assets/stations.json`.
Re-run it whenever the UI changes.

1. Simulator: iPhone 6.3" (1206x2622), dark appearance,
   `xcrun simctl status_bar <udid> override --time 8:12 --batteryState charged --batteryLevel 100`.
2. From `app/`, with the watchers started first:
   `tools/store/capture.sh <log> <work>/raw <udid> &`, `tools/store/record.sh <log> <work>/video <udid> &`, then
   `flutter test integration_test/store_test.dart -d <udid> > <log>`.
3. `python3 tools/store/compose_screenshots.py <work>` writes `<work>/final/{ios-6.9,ios-6.3,android}`;
   `tools/store/make_preview.sh <work>/video` writes the 886x1920 App Store preview.
4. Header (5244x2950) and Play feature graphic (1024x500): `tools/icon/render-header-b.sh`.

Copy the results into `docs/store/screenshots-1.3/` and `docs/store/preview/`. Set `CHROME` to use another Chrome. Needs Chrome, ImageMagick and ffmpeg.
