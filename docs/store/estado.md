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
- **Enviada a revisión el 17-11-2026: Waiting for Review.**

## Play 1.1.0 (7)
- Borrador en Alpha con notas en-GB y declaración FGS (dataSync, Network processing → Other, vídeo
  https://www.youtube.com/watch?v=CzQffbLA2To). Se envía cuando Google apruebe la versión 4.
- 18-11-2026: el borrador de Alpha pasa a **8 (1.2.0)** (AAB 8 subido por el usuario, el 7 quitado del borrador y
  sigue en la biblioteca; notas en-GB con "Show more" hasta 4 h). Guardado como borrador, sin enviar: la versión 4
  sigue en revisión. Publishing overview muestra **Managed publishing on** (no off como decía arriba): al aprobarse
  la 4 hay que publicarla a mano.

## Seguir trenes en iOS (servidor, 17-11-2026)
- Rama feat/ios-follow-push fusionada en main (d715b4c) + CI arreglada (instala requirements.txt). App 1.2.0+8 lista en código, sin subir.
- VPS desplegado ~21:30: API reconstruida (log `follow: off (APNS_* missing or invalid)`), nginx con `location = /follow` recargado (`nginx -t` OK).
  Comprobado: /health ok, /departures/KGX 200, POST /follow → 503 unavailable (sin clave APNs), GET /follow 403, política con la sección iPhone publicada.
- Pendiente: clave APNs (.p8) en el equipo 338 TAC → `APNS_*` en /opt/platform/.env → `docker compose up -d` (log `follow: on`); prueba en iPhone real; 1.2.0 (8) a App Store tras aprobarse la 1.1.0, con App Privacy "Device ID · Not Linked · App Functionality".
- 17-11-2026 ~21:50: Push Notifications activado en el App ID com.jfcaba.platform. No se pudo crear clave APNs nueva (límite de 2 claves team-scoped Sandbox & Production en 338 TAC):
  se reutiliza la de Matchday (Key ID SAZJXCZQW3, fichero en /home/ubuntu/matchday-secrets/apns-key.p8 del mismo VPS). Revocarla rompería Matchday y What Platform a la vez.
  APNS_* añadidos a /opt/platform/.env (copia previa .env.bak-202611172048, 600 root). Log: `follow: on`. POST {} → 400, tren inexistente → 410, DELETE → 204.
- 17-11-2026: prueba real en iPhone 11 (iOS 27.0.1, build release firmada para desarrollo → sandbox): seguido el 21:18 KGX→Ely desde España; a las 21:12 UK le asignan andén 0 y llega el aviso "21:18 to Ely / Platform 0" con la app cerrada. ✅

## Próxima versión: What Platform iOS 1.2.0 (8) — pendiente (esperando revisión de la 1.1.0)
- 18-11-2026: build 1.2.0 (8) subido a App Store Connect para TestFlight (seguir trenes por push + "Show more" hasta ~4 h). IPA comprobado: `aps-environment` = production. No asignado a ninguna versión: la 1.1.0 sigue en revisión con el build 7.
Código en main (1.2.0+8), servidor desplegado con `follow: on`, prueba real OK. Cuando Apple apruebe la 1.1.0:
1. Archivar 1.2.0 (8) y comprobar que el IPA exportado lleva `aps-environment` = production (el fichero Runner.entitlements dice development; Xcode lo cambia al exportar).
2. Subir a App Store Connect (`xcodebuild -exportArchive`, método app-store-connect) y asignar el build a la versión 1.2.0; probar antes por TestFlight (entorno production).
3. App Privacy: pasar de "Data Not Collected" a Identifiers → Device ID · Not Linked to You · App Functionality.
4. Ficha: descripción y novedades en-GB con "follow a train on iPhone: alerts for platform, time and cancellation changes" y "scroll down or tap Show more to see trains up to 4 hours ahead"; notas del revisor (seguir un tren, permiso de notificaciones, cómo probarlo).
5. Captura nueva opcional con la campanita en una fila.
6. Enviar a revisión: lo pulsa el usuario.
Además: Android 1.1.0 (7) sigue esperando a que Google apruebe la versión 4 de Play. Pruebas reales pendientes de "Now expected …" y "Cancelled" (Paulo).

## Límites de Darwin en Rail Data Marketplace (consultado 17-11-2026, pestaña Licence de cada producto)
- Live Departure Board (P-d81d6eaf…, v1.1) y Service Details (P-4dec1247…): licencia Open, Charging model **Free**, **Fair usage limit: No**, sin SLA; atribución "National Rail" (la API ya la manda).
- Condición especial: no revender los datos tal cual; uso comercial solo si se aumentan o integran (la app sí: estación más cercana, filtros, paradas, avisos).
- No hay cuota publicada ni cabeceras de límite en las respuestas. En la práctica el gateway aplica un "spike arrest" de ~100 peticiones/segundo (error 429 visto por usuarios en dic-2025/ene-2026, openraildata-talk). Cifra antigua de OpenLDBWS (no RDM): 5 millones / 4 semanas.
- Nuestro máximo: sondeo de avisos ≤ 100/min + paneles detrás de la caché de 30 s de nginx → muy por debajo. Ante 429: app y servidor esperan 5 min.
