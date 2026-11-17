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
- Builds uploaded with `xcodebuild -exportArchive` (method app-store-connect, upload):
  1.0.0 (1); (2) time column fix; (3) restores NSLocationAlwaysAndWhenInUseUsageDescription (ITMS-90683:
  Apple requires it because geolocator references the API; the app only asks When In Use).

## Google Play (16-11-2026)

- "Create app" filled in on the "Jose Catala" account (What Platform, com.jfcaba.platform, en-GB, app, free).
  The two declarations are ticked by the user. AAB 1.0.0 (3) signed with Andén's upload key:
  `app/build/app/outputs/bundle/release/app-release.aab` (51 MB, uploaded by the user).

## Screenshots

`docs/store/screenshots/ios-6.3/` (1206×2622: King's Cross, Manchester, Reading, Birmingham, search) and
`docs/store/screenshots/android/` (1080×2400: the same four stations). Live data, 16-11-2026 ~16:00 UK.

## Pending (user)

- Decided 16-11-2026: same accounts as Andén (App Store: team 338 TAC, S.L.; Google Play: personal account "Jose Catala"), store name "What Platform".
  Personal Play account → 14-day closed test with 12+ testers.
- App Store Connect / Play Console entries, following `tren/docs/store/estado.md`. No "Submit for review"
  without explicit confirmation.

## Play (17-11-2026)
- Prueba cerrada "Alpha": Reino Unido, lista "Beta testers", feedback https://whatplatform.uk/. Versión 4 (1.0.0).
- Ficha completa (textos, icono, gráfico, 4 capturas; categoría Travel & Local), contenido de la app y declaraciones hechas (PEGI 3 / ESRB E, sin datos recogidos, sin advertising ID, público 18+).
- **Enviada a revisión el 17-11-2026.** Publicación gestionada desactivada: al aprobarse, la prueba se activa sola.
- Después: enlace de participación a los probadores; 14 días con ≥ 12 inscritos; luego pedir acceso a producción.

## App Store 1.1.0 (17-11-2026)
- Versión renombrada 1.0 → 1.1.0; build 7 (1.1.0) asignado (paradas; seguir trenes oculto en iOS). Grupo TestFlight "internal".
- Ficha: descripción sin el seguimiento Android, keywords, subtítulo, soporte/privacidad https://whatplatform.uk/,
  copyright "2026 What Platform", 6 capturas 6.3" (incluye `06-stops.png`), notas del revisor (`review-notes-en.md`),
  sin login. Categoría Travel + Navigation. Content rights: sí, con derechos. Edad 4+. App Privacy: Data Not Collected.
  Gratis, 174 países: todos menos China continental (pide Security Assessment y declaración AIGC).
- Política de privacidad nueva publicada (git pull en el VPS).
- Pendiente (usuario): contacto del revisor, "Add for Review" y envío.

## Play 1.1.0 (7)
- Borrador en Alpha con notas en-GB y declaración FGS (dataSync, Network processing → Other, vídeo
  https://www.youtube.com/watch?v=CzQffbLA2To). Se envía cuando Google apruebe la versión 4.
