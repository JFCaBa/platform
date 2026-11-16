# Platform: status

## Real-world check (16-11-2026, 15:24 UK)

Birmingham New Street: `https://api.whatplatform.uk/departures/BHM` (generatedAt 15:24:11Z) against the
National Rail website board ("Updated 15:24"). The first 10 trains are identical: times, status, platforms
(10A, 12, 3A, 7A, 4C, 11B, 8B, 3B, 12A, 4B) and both cancellations (15:33 Reading, 15:34 Liverpool Lime Street).
The website also shows trains that have just left ("Departed"); Darwin's public board keeps them as "On time"
for a minute or two.

King's Cross on the iOS simulator (location 51.5302,-0.1240): station found at 110 m, live board, platform 9
shown, 3 NRCC alerts collapsed. Screenshot: `docs/screenshots/kgx.png`.

## App Store (16-11-2026)

- Record "What Platform" created in team 338 TAC, S.L. (en-GB, bundle com.jfcaba.platform, SKU whatplatform-ios).
- Build 1.0.0 (1) uploaded with `xcodebuild -exportArchive` (method app-store-connect, upload): processing → TestFlight.

## Google Play (16-11-2026)

- "Create app" filled in on the "Jose Catala" account (What Platform, com.jfcaba.platform, en-GB, app, free).
  The two declarations are ticked by the user. AAB 1.0.0 (1) signed with Andén's upload key:
  `app/build/app/outputs/bundle/release/app-release.aab` (51 MB, uploaded by the user).

## Pending (user)

- Decided 16-11-2026: same accounts as Andén (App Store: team 338 TAC, S.L.; Google Play: personal account "Jose Catala"), store name "What Platform".
  Personal Play account → 14-day closed test with 12+ testers.
- App Store Connect / Play Console entries, following `tren/docs/store/estado.md`. No "Submit for review"
  without explicit confirmation.
