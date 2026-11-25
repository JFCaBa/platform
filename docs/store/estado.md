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
- 18-11-2026 (después): Play no dejaba enviar la 8: `screenOrientation="portrait"` implica
  `android.hardware.screen.portrait` obligatoria (sin tablets/escritorio/XR). Declarada `required="false"` → build
  **9 (1.2.0)** (commit 29fe46b). Nueva versión de Alpha con el AAB 9, notas en-GB; vista previa "Ready to release"
  (+7 tablets, +3 TV). Guardada en Publishing overview, **sin enviar** ("Submit 1 change for review" lo pulsa el
  usuario, mejor tras aprobarse la 4). iOS sigue en el build 8 en TestFlight (pubspec ya en 1.2.0+9).
- 18-11-2026 (tarde): Google **rechaza la 4** por Misleading Claims ("Missing Source Link for Government
  Information", en la descripción completa). Descripción en-GB con bloque "Sources" (nationalrail.co.uk,
  raildata.org.uk, NaPTAN en data.gov.uk) + aviso "does not represent any government entity" (listing-en.md),
  guardada. Publishing overview: 14 cambios (ficha, App content, Alpha 9 (1.2.0), declaración FGS), pendientes de
  que el usuario pulse "Submit 14 changes for review" → "Send changes for review".

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
- 19-11-2026: la 1.1.0 ya está en la App Store. **Versión 1.2.0 creada** con el build 8: descripción (seguir un tren, "Show more", Sources + aviso), novedades, notas del revisor 1.2.0 (`review-notes-en.md`) y **publicación manual**, guardada. App Privacy: Device ID · Not Linked · App Functionality · sin tracking rellenado; falta que el usuario pulse **Publish** en ese diálogo y luego "Add for Review". Se publica la semana del 23-11-2026.
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

## 1.3.0 (10) — rediseño (20-11-2026)
- App: tarjeta grande del próximo tren (minutos, andén grande o "Platform not yet shown"), retrasos en ámbar,
  cancelados atenuados, "Live · hh:mm:ss" bajo la estación, 3 estaciones recientes (commit 9787f1e).
- iOS: 1.2.0 ya en la App Store. Build 1.3.0 (10) subido; **versión 1.3.0 creada** con el build 10, descripción
  (+ "Your recent stations, one tap away.") y novedades (`listing-en.md`), publicación manual, guardada. Capturas: las
  de la 1.2 (sin la tarjeta nueva). Falta "Add for Review" → enviar (lo pulsa el usuario).
- 20-11-2026 (después): ficha 1.3.0 en ASC con **cabecera nueva** (`app/tools/icon/header-b-5244x2950.png`), **5 capturas
  6.3"** y **vista previa** (29,5 s) de `docs/store/screenshots-1.3/` y `docs/store/preview/` (panel de estación UK).
- Play: Alpha **10 (1.3.0)** guardada por el usuario (sin enviar; la 9 sigue In review). Ficha principal guardada
  como borrador: gráfico destacado nuevo, 5 capturas nuevas y descripción igualada con iOS (paradas, seguir un tren,
  "Show more", estaciones recientes). Se envía junto con lo pendiente en Publishing overview.
- Play: AAB 10 en `app/build/app/outputs/bundle/release/app-release.aab` (52 MB). La entrega anterior (Alpha 9,
  ficha, FGS) sigue **In review**: crear la versión de Alpha con el AAB 10 cuando Google la apruebe, para no
  reiniciar la revisión.
- 20-11-2026 (tarde): **build 11 (1.3.0)**: el tren seguido ocupa la tarjeta grande (commit ce815e2). ASC: versión 1.3.0
  con el **build 11** y novedades con "Following a train? That one goes on top.", guardada. Play: borrador de Alpha
  nuevo (release 5) con notas, sin el 10; falta que el usuario arrastre el AAB 11, guarde y luego envíe todo desde
  Publishing overview (la 9 sigue In review).
- 20-11-2026: Play Alpha **11 (1.3.0)** guardada (AAB subido por el usuario) y ficha guardada (declaración de IA:
  "Don't label assets", decidido por el usuario). Publishing overview: **4 cambios sin enviar** (Alpha 11, descripción,
  capturas, gráfico destacado); la 9 sigue In review. "Submit 4 changes for review" lo pulsa el usuario.


## 1.4.0 (12) — tu tren en vivo (21-11-2026)
- API desplegada (022a24e): `/service/{id}` con `position`; Live Activity por push; tokens de actividad hasta 512 hex.
- iOS: build 12 subido a App Store Connect (incluye la extensión FollowActivity, App ID com.jfcaba.platform.FollowActivity creado por firma automática). Falta: crear la versión 1.4.0 en ASC, asignar el build 12, novedades (listing-en.md) y probar en iPhone real por TestFlight (pantalla de bloqueo y Dynamic Island).
- Android: AAB 12 en app/build/app/outputs/bundle/release/app-release.aab (52,4 MB). Lo sube el usuario.
- Política de privacidad actualizada (token de la Live Activity, solo en memoria).

## 1.5.0 (13) — home screen widget (22-11-2026; branch merged to main 25-11-2026)

- iOS (small: time + platform; medium: time, destination, platform, countdown) and Android (4x2,
  resizable) widget with the next 4 trains of the last station opened, with its destination filters.
- Refreshes by itself: fetches `/departures/{CRS}` (iOS timeline every ~15 min; Android WorkManager
  every 15 min with network). Gallery preview with a London Euston sample.
- App Group `group.com.jfcaba.platform` added to Runner and FollowActivity (Xcode registers it on the
  first archive with -allowProvisioningUpdates).
- No new data collected: App Privacy unchanged.
- Verified: Android emulator (gallery preview, real Euston board, worker fetch); iOS simulator build
  and renders. Real iPhone pending.
- 22-11-2026 17:27: iOS build 1.5.0 (13) uploaded to App Store Connect for TestFlight (from the
  branch; App Group entitlement on app and extension checked). Not assigned to any version.
- 22-11-2026: Play internal testing (first use of the track) draft release 13 (1.5.0) saved, AAB
  uploaded by the user, notes en-GB. Pending (user): testers list, Next → roll out. Alpha keeps 12
  (1.4.0) Ready to publish. What Platform is under the jfcaba68 Google account (Play Console u/1).
- Merged to main 25-11-2026; next: archive and AAB of the 1.5.0 for the stores.
- Notes for the stores (draft): "New home screen widget: your next trains and platforms at a glance."

## 1.5.0 (14) — About button (22-11-2026)

- iOS build 14 uploaded to App Store Connect. AAB 1.5.0 (14) uploaded by the user to a new internal testing release
  ("14 (1.5.0)", en-GB notes: widget + About button), rolled out by the user on 22-11-2026.

## Estadísticas de uso en el servidor (23-11-2026)

Página `/admin` (spec `docs/superpowers/specs/2026-11-23-admin-stats-design.md`). Política
actualizada (sin «no analytics»; recuento anónimo explicado). Revisión de las etiquetas de
privacidad de las tiendas, conclusión de Claude: **sin cambios**.
- App Store (App Privacy): lo que se guarda son totales por estación, hora, versión y día; no son
  datos de un usuario ni ligados a un dispositivo. La IP se usa en memoria para contar
  visitantes únicos y no se guarda. Sigue «Device ID · Not Linked · App Functionality» solo por
  el seguimiento en iPhone.
- Google Play (Data safety): la IP se procesa de forma efímera (en memoria, con clave diaria
  que se borra); no se recoge ni comparte.
- Matiz: los hashes del día viven en memoria hasta medianoche. Si Apple o Google preguntan,
  la respuesta es que es un recuento agregado sin identificador persistente.


## Web (25-11-2026)

- https://whatplatform.uk es ahora la web (panel como la app, botón de App Store); la política de privacidad pasa a https://whatplatform.uk/privacy.
- Play: URL de privacidad cambiada a `/privacy` en App content (el usuario guarda y envía desde Publishing overview).
- App Store: la URL de privacidad solo se puede cambiar con una versión nueva → cambiarla al preparar la 1.5.0, junto con `privacyUrl` en `app/lib/config.dart` (`https://whatplatform.uk/privacy`). Mientras tanto el enlace de las apps instaladas abre la portada, que enlaza a Privacy.
- Arreglado en main (sale con la 1.5.0): las páginas de «Show more» caducan a los 10 min (no vuelven trenes de ayer tras una noche en segundo plano), la hora repetida de octubre y `privacyUrl` = `/privacy`. Al preparar la 1.5.0 hay que recompilar (el build 14 no lo lleva) y cambiar la URL de privacidad en App Store Connect.
