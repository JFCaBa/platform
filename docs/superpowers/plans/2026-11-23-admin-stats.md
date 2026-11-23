# Página de estadísticas — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `api.whatplatform.uk/admin` muestra personas al día, estaciones más vistas, horas punta, versiones y trenes seguidos, sin que ninguna IP llegue a disco.

**Architecture:** nginx manda una línea syslog por petición de What Platform (UDP, 127.0.0.1) a un receptor en el proceso de la API. El receptor hashea IP+UA con una clave diaria en memoria, suma contadores y cada minuto los vuelca a una SQLite en un volumen. `/admin`, detrás de `auth_basic` y una cabecera secreta, renderiza en el servidor una página HTML con SVG en línea.

**Tech Stack:** Python 3.12 stdlib (`socket`, `sqlite3`, `hmac`, `zoneinfo`), `tzdata` (pip), nginx `access_log syslog:`, Docker compose.

**Spec:** `docs/superpowers/specs/2026-11-23-admin-stats-design.md`

## Global Constraints

- Nunca escribir IP, User-Agent completo, hash de visitante ni la clave diaria en disco, log, stderr o SQLite.
- La clave diaria es `secrets.token_bytes(32)`, vive solo en memoria y se cambia al empezar cada día de Londres (`Europe/London`).
- Solo cuentan respuestas 2xx/3xx (304 incluido) de `GET /departures/...`, `GET /service/...` y `POST /follow`. No cuentan 4xx/5xx, `DELETE`, `/health`, `/admin` ni nada de `/anden/...`. Todos los `$upstream_cache_status` cuentan igual.
- Visitante = petición con User-Agent que empieza por `WhatPlatform/`. Versión = lo que sigue a `WhatPlatform/` hasta espacio (máx. 16 caracteres, `[0-9A-Za-z.+-]`); si no, `otro` (cuenta en peticiones, no como visitante).
- Un fallo de las estadísticas nunca afecta a `/departures`, `/service` ni `/follow`: excepciones capturadas, log solo `stats: <Class>`.
- Agregados para siempre; copia diaria con `sqlite3` `backup()`, se guardan las 7 últimas.
- La API sigue sin registrar peticiones; el docstring de `server.py` y el README de deploy se actualizan con lo nuevo.
- Tests: `cd api && python -m pytest -q tests`, estilo `unittest` como `tests/test_server.py`.

## Review Focus

1. Paquete syslog malformado, truncado o con campos de más (UA con espacios/escapes `\x..`) → se ignora sin excepción. Test en Task 1.
2. Reinicio a mitad de día → los visitantes de hoy no bajan (base guardada + set nuevo). Test en Task 2.
3. Días sin tráfico (medianoche sin paquetes) → el cambio de día ocurre igual en el volcado por minuto, con fila de visitantes del día anterior. Test en Task 2.
4. `/admin` sin cabecera secreta o con `ADMIN_KEY` vacío → 404, igual que una ruta desconocida. Test en Task 4.
5. Renovación de un seguimiento (mismo token y tren) → no suma alta; cambio a otro tren → sí. Test en Task 4.

---

## Archivos

- Create `api/platform_api/stats.py` — `parse_line`, `Tally` (memoria: hash, contadores, cambio de día).
- Create `api/platform_api/stats_db.py` — `StatsDB` (SQLite: esquema, volcado, consultas, copias).
- Create `api/platform_api/admin.py` — `summary()` y `render_page()` (HTML + SVG).
- Modify `api/platform_api/server.py` — receptor UDP, hilo de volcado, `/admin`, altas de seguimiento.
- Modify `api/compose.yaml`, `api/requirements.txt`, `deploy/nginx/whatplatform.uk.conf`, `deploy/README.md`, `site/index.html`, `docs/store/estado.md`.
- Tests: `api/tests/test_stats.py`, `api/tests/test_stats_db.py`, `api/tests/test_admin.py`, ampliar `api/tests/test_server.py`.

### Task 1: Parseo de líneas y `Tally`

**Files:** Create `api/platform_api/stats.py`, Test `api/tests/test_stats.py`, Modify `api/requirements.txt` (añadir `tzdata==2025.2`).

**Interfaces:**
- Produces:
  - `Hit = NamedTuple(ts: float, kind: str, crs: str | None, ip: str, ua: str)` con `kind` en `{"departures", "service", "follow"}`.
  - `parse_line(packet: bytes) -> Hit | None`.
  - `london_day(ts: float) -> str` (`"YYYY-MM-DD"`) y `london_hour(ts: float) -> int`.
  - `class Tally(key_factory=lambda: secrets.token_bytes(32))` con:
    - `add(hit: Hit) -> None` — si `london_day(hit.ts)` es posterior al día en curso, primero cierra ese día (nueva clave, set vacío). Si es anterior (paquete rezagado tras medianoche), se descarta.
    - `add_follow(ts: float) -> None` — alta de seguimiento (la llama el servidor, Task 4).
    - `visitors_today() -> int` — tamaño del set del día en curso.
    - `drain(now: float) -> list[Delta]` — devuelve y pone a cero los contadores, un `Delta` por día con datos; si `london_day(now)` es posterior al día en curso, lo cierra.
    - `Delta = dataclass(day: str, visitors: int, closed: bool, requests: int, follows: int, hours: dict[int,int], stations: dict[str,int], versions: dict[str,int])`; `visitors` = tamaño del set de ese día (no se pone a cero en `drain`, solo crece); `closed=True` si ese día ya terminó (el set y la clave ya se borraron).

Formato de línea (Task 5 lo configura en nginx). El datagrama real de nginx con `nohostname` es `<190>Nov 23 16:22:36 platform: ` + mensaje (la fecha syslog va entre la prioridad y la etiqueta; el parser busca la primera aparición de `platform: ` y la ignora). Mensaje = campos separados por `|`:
`$msec|$request_method|$uri|$status|$upstream_cache_status|$remote_addr|$http_user_agent|E`. El último campo debe ser exactamente `E` (marca de fin: un datagrama truncado no la tiene y se descarta); el UA es lo que queda entre la IP y `|E` y puede contener `|`. El receptor lee con `recv(65535)`. nginx escapa `"`, `\` y bytes <32/>126 como `\xHH`.

- [ ] **Step 1: Tests que fallan** en `test_stats.py`:
  - `test_parse_departures`: `b'<190>Nov 23 16:22:36 platform: 1763900000.123|GET|/departures/KGX|200|HIT|1.2.3.4|WhatPlatform/1.5|E'` → `Hit(1763900000.123, "departures", "KGX", "1.2.3.4", "WhatPlatform/1.5")`.
  - `test_parse_later_page`: `/departures/KGX/45` → kind `departures`, crs `KGX`.
  - `test_parse_service_and_follow`: `/service/10741504KNGX____` → `("service", None)`; `POST|/follow|200` → `("follow", None)`.
  - `test_parse_rejects`: devuelven `None`: status `404`, `429`, `502`; `DELETE /follow 204`; `GET /health 200`; `/anden/follow`; `/admin`; paquete vacío, sin `platform: `, con menos de 8 campos, sin `|E` final (UA truncado: `...|1.2.3.4|WhatPl`), `$msec` no numérico, bytes no UTF-8.
  - `test_parse_ua_with_pipes`: UA `a|b c` → `ua == "a|b c"`.
  - `test_parse_real_nginx_datagram`: fixture `tests/fixtures/nginx_syslog.bin` capturado de `nginx` real con el `log_format` de Task 5 (o copiado byte a byte del formato documentado de nginx si no hay nginx local; anotar el origen en el test) → se parsea.
  - `test_visitors_dedupe_and_versions`: 3 hits mismo IP+UA `WhatPlatform/1.5`, 1 de otra IP `WhatPlatform/1.4`, 1 con UA `curl/8` → `drain`: `visitors_today == 2`, `requests == 5`, `versions == {"1.5": 3, "1.4": 1, "otro": 1}`.
  - `test_hours_and_stations`: hits a KGX a las 08:10 y 08:50 de Londres, EUS a las 09:00 → `hours == {8: 2, 9: 1}`, `stations == {"KGX": 2, "EUS": 1}`.
  - `test_drain_resets_counters_but_not_visitors`: tras `drain`, otro `drain` sin hits → `requests == 0`, `visitors_today` igual que antes.
  - `test_day_close_on_drain`: hits el día D, `drain(now=D+1 00:00:30 Londres)` → un `Delta(day=D, closed=True, visitors=n)`; después `visitors_today() == 0` y `key_factory` se ha llamado 2 veces.
  - `test_day_close_on_hit`: hits de D, luego un hit de D+1, luego `drain` → dos `Delta`: D (`closed=True`, sus contadores) y D+1 (`closed=False`, 1 petición).
  - `test_late_hit_dropped`: tras cerrar D, un hit con `ts` de D → no cuenta en nada.
  - `test_same_ip_new_day_new_hash`: mismo IP+UA en D y D+1 → 1 visitante en cada día.
  - `test_nothing_sensitive_kept`: tras un cierre de día, `repr(vars(tally))` no contiene `"1.2.3.4"` ni el UA.
  - `test_london_dst`: `london_day`/`london_hour` en 2026-03-29 00:30 UTC (GMT → día 29, hora 0) y 2026-06-01 23:30 UTC (BST → día 2 de junio, hora 0).

- [ ] **Step 2:** `cd api && python -m pytest -q tests/test_stats.py` → FAIL (módulo no existe).
- [ ] **Step 3: Implementar** `stats.py`. Hash: `hmac.new(key, f"{ip}\n{ua}".encode(), "sha256").digest()[:16]` guardado en un `set` del día; IP y UA no se guardan en ningún atributo. Lock `threading.Lock` alrededor de `add`/`add_follow`/`drain`.
- [ ] **Step 4:** mismo comando → PASS.
- [ ] **Step 5: Commit** `feat(api): stats tally with daily-keyed visitor hash`.

### Task 2: SQLite (`StatsDB`)

**Files:** Create `api/platform_api/stats_db.py`, Test `api/tests/test_stats_db.py`.

**Interfaces:**
- Consumes: `Delta` de Task 1.
- Produces: `class StatsDB(path: str | Path)`:
  - `apply(deltas: list[Delta]) -> None` — suma `requests`/`follows`/`hours`/`stations`/`versions`; visitantes: ver abajo. Una transacción.
  - `visitors_base(day: str) -> int` — base congelada de ese día: el valor guardado en `days` la primera vez que este `StatsDB` ve ese día (leído una vez y guardado en `self._base[day]`; nunca se relee). Así `base + set en memoria` no duplica lo ya volcado.
  - `stations_count(day: str) -> int` — estaciones distintas de ese día.
  - `days(since: str | None) -> list[dict]` (`day, visitors, requests, follows`), `top_stations(since, limit=20) -> list[tuple[str,int]]`, `hours(since) -> dict[int,int]`, `versions(since) -> dict[str,int]`. `since=None` = todo.
  - `backup(dest_dir: Path, day: str, keep: int = 7) -> None` — crea `dest_dir` si no existe (`mkdir(parents=True, exist_ok=True)`), `sqlite3.Connection.backup` a `stats-<day>.db`, borra las más antiguas por encima de `keep`.
- Esquema: `days(day TEXT PRIMARY KEY, visitors INT, requests INT, follows INT)`, `hours(day, hour, requests, PRIMARY KEY(day,hour))`, `stations(day, crs, requests, PK(day,crs))`, `versions(day, version, requests, PK(day,version))`. `journal_mode=WAL`. Una conexión, `check_same_thread=False` y lock.
- Visitantes: al crear `StatsDB`, el servidor lee `base = visitors_base(hoy)`. `apply` escribe `visitors = base_del_día + delta.visitors` (no suma incremental: es el tamaño del set, que solo crece). `StatsDB` guarda `base` por día en memoria (`self._base`), leída la primera vez que ve ese día.

- [ ] **Step 1: Tests que fallan:**
  - `test_apply_sums`: dos `apply` del mismo día con `requests` 3 y 2 → `days()[0]["requests"] == 5`; estaciones y horas sumadas.
  - `test_visitors_not_summed`: `apply` con `visitors` 4 y luego 6 (mismo set creciendo) → 6.
  - `test_restart_keeps_visitors`: `apply(visitors=10)`, cerrar, nuevo `StatsDB` sobre el mismo fichero, `apply(visitors=3)` mismo día → 13.
  - `test_base_frozen`: `apply(visitors=4)` hoy y luego `visitors_base(hoy)` → 0 (base del arranque), no 4.
  - `test_stations_count`: KGX y EUS hoy → 2.
  - `test_closed_day_without_traffic`: `Delta(closed=True, requests=0, visitors=7)` crea la fila del día con 7.
  - `test_queries_since`: tres días; `days(since=d2)` devuelve 2 filas ordenadas; `top_stations` ordenado desc y con `limit`.
  - `test_backup_keeps_7`: 9 `backup` con días distintos → 7 ficheros, los más nuevos; cada uno abre con `sqlite3` y tiene la tabla `days`.
  - `test_no_sensitive_columns`: columnas de todas las tablas ⊂ `{day, visitors, requests, follows, hour, crs, version}`.
- [ ] **Step 2:** `python -m pytest -q tests/test_stats_db.py` → FAIL.
- [ ] **Step 3: Implementar** `stats_db.py` (upserts con `INSERT ... ON CONFLICT DO UPDATE`).
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(api): stats SQLite store with daily backups`.

### Task 3: Página `/admin` (`admin.py`)

**Files:** Create `api/platform_api/admin.py`, Test `api/tests/test_admin.py`.

**Interfaces:**
- Consumes: `StatsDB` (Task 2), nombres de estación de `stations.json` (`{"crs","name"}`).
- Produces:
  - `RANGES = {"today": 0, "7d": 6, "30d": 29, "all": None}` (días hacia atrás desde hoy, inclusive).
  - `summary(db: StatsDB, today: str, rng: str, live_visitors: int, active_follows: int, names: dict[str,str]) -> dict` con claves `range, visitors_today, stations_today, follows_today, active_follows, daily (últimos 30 días siempre, [{day, visitors}]), top (rango: [{crs, name, requests}]), hours (rango: 24 valores), versions (rango: [{version, requests, pct}])`. `rng` desconocido → `"7d"`.
  - `render_page(s: dict) -> str` — HTML completo, sin JS ni recursos externos.
- Página: título «What Platform · stats», selector Today · 7d · 30d · All (enlaces `?range=`), tarjetas (personas hoy, estaciones hoy, trenes seguidos activos/hoy), barras SVG de personas por día (30 días), top 20 estaciones (barras horizontales con nombre y CRS), barras de 24 horas, versiones con porcentaje. Colores: marca `#1E3A8A`, ámbar `#B45309` / oscuro `#FBBF24`; tokens en `:root` y `@media (prefers-color-scheme: dark)`; ancho de móvil sin scroll horizontal. Textos de la página en inglés (como la app). Todo el texto dinámico con `html.escape`.

- [ ] **Step 1: Tests que fallan:**
  - `test_summary_ranges`: DB con datos de hoy y de hace 10 días → `rng="7d"` excluye el de hace 10 días en `top`; `"all"` lo incluye; `"x"` → `range == "7d"`.
  - `test_summary_today_uses_live`: `visitors_today == live_visitors` (el en curso de memoria + base), no el último volcado.
  - `test_daily_fills_gaps`: días sin fila salen con `visitors: 0`; siempre 30 elementos.
  - `test_versions_pct`: `{"1.5": 3, "otro": 1}` → pct 75 y 25.
  - `test_render_escapes`: nombre de estación `<script>` aparece como `&lt;script&gt;`.
  - `test_render_has_sections`: el HTML contiene `People per day`, `Top stations`, `Busiest hours`, `App versions`, y no contiene `<script`, `http://` ni `https://`.
- [ ] **Step 2:** `python -m pytest -q tests/test_admin.py` → FAIL.
- [ ] **Step 3: Implementar** `admin.py`.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(api): admin stats page`.

### Task 4: Conexión en el servidor

**Files:** Modify `api/platform_api/server.py` (docstring, `make_server`, `Handler.do_GET`, `do_POST`, `main`), Test `api/tests/test_server.py` (casos nuevos).

**Interfaces:**
- Consumes: `parse_line`, `Tally` (Task 1), `StatsDB` (Task 2), `summary`, `render_page` (Task 3).
- Produces:
  - `make_server(..., stats: Tally | None = None, stats_db: StatsDB | None = None, admin_key: str = "", station_names: dict[str,str] | None = None)`.
  - `run_receiver(sock: socket.socket, tally: Tally, log: TextIO) -> None` (bucle; cada paquete → `parse_line` → `tally.add`; cualquier excepción → `log.write("stats: <Class>\n")` y sigue).
  - `run_flusher(tally, db, backup_dir: Path, stop: threading.Event, log, clock=time.time, every: float = 60.0)`: cada `every` s: si no hay lote pendiente, `pending = tally.drain(clock())`; `db.apply(pending)`; solo si no lanza, `pending = []` y los días `closed` pasan a una lista de copias pendientes. Las copias pendientes se intentan cada ciclo y salen de la lista al terminar bien (un fallo de copia no reaplica contadores). Al activarse `stop`, un último ciclo antes de salir.
  - En `main`: `signal.signal(SIGTERM, ...)` que activa `stop`, espera al hilo del flusher (máx. 5 s) y cierra el servidor, para no perder el último minuto en un reinicio.
  - Env en `main`: `STATS_DB` (defecto `/data/stats.db`), `STATS_BACKUP_DIR` (defecto `/data/backups`), `ADMIN_KEY`. Puerto UDP fijo `8511` en `0.0.0.0` (como el 8510: no configurable, para que nginx, compose y el receptor no se desincronicen). Si no se puede abrir la DB → log `stats: off` y todo lo demás funciona igual.
- `/admin`: `GET /admin` y `GET /admin?range=...`. Si `admin_key` vacío o la cabecera `X-Admin-Key` no coincide (`hmac.compare_digest`) → 404 `{"error":"not found"}`. Si coincide → 200 `text/html; charset=utf-8`, `Cache-Control: no-store`, `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src 'self'`. `live_visitors` = `db.visitors_base(hoy) + ` visitantes del set de hoy; `active_follows = len(follows)` (0 si `follows` es None).
- Altas: en `do_POST`, tras `result == "ok"` (no en la rama `is_same`), `stats.add_follow(clock())` si `stats` no es None, dentro de `try/except Exception` que solo escribe `stats: <Class>`; la respuesta del seguimiento no cambia.
- `/admin` usa `stats_db.stations_count(hoy)` para «estaciones hoy».

- [ ] **Step 1: Tests que fallan** (en `test_server.py`, con el servidor de prueba existente):
  - `test_admin_404_without_key`: `admin_key=""` → `GET /admin` con cualquier cabecera → 404.
  - `test_admin_404_wrong_key`: `admin_key="s3cret"`, cabecera `X-Admin-Key: nope` → 404.
  - `test_admin_ok`: cabecera correcta → 200, `text/html`, `no-store`, cuerpo con `Top stations`.
  - `test_follow_new_counts_renewal_not`: POST nuevo → `tally.drain` da `follows == 1`; mismo POST otra vez (rama `is_same`) → 0; POST del mismo token a otro tren → 1.
  - `test_receiver_survives_garbage`: socket UDP local; enviar `b"\xff\xfe"` y luego una línea válida → la válida cuenta; log solo contiene líneas `stats: ` sin IP.
  - `test_flusher_backs_up_closed_day`: `Tally` con reloj falso en D, hits, avanzar a D+1, ciclo de `run_flusher` con `every` pequeño → existe `stats-D.db` en `backup_dir`.
  - `test_flusher_retries_failed_apply`: `apply` falla una vez → el siguiente ciclo aplica el mismo lote; totales correctos, sin duplicar.
  - `test_follow_ok_when_add_follow_raises`: `add_follow` lanza → `POST /follow` sigue 200 y el log solo tiene `stats: <Class>`.
  - `test_flusher_final_flush_on_stop`: hits, `stop.set()` → los hits están en la DB al terminar el hilo.
  - `test_departures_unaffected_when_stats_broken`: `stats_db` cuyo `apply` lanza → `/departures/KGX` sigue 200 y el flusher sigue vivo.
- [ ] **Step 2:** `python -m pytest -q tests/test_server.py` → FAIL en los nuevos.
- [ ] **Step 3: Implementar.** Actualizar el docstring de privacidad de `server.py`: «Requests are not logged; nginx sends each What Platform request over local UDP to the stats receiver, which keeps only aggregates (see stats.py). Logged: … `stats: <Class>` / `stats: off`».
- [ ] **Step 4:** `python -m pytest -q tests` → todo PASS (incluidos los tests anteriores).
- [ ] **Step 5: Commit** `feat(api): stats receiver, flusher and /admin route`.

### Task 5: nginx, compose, deploy y privacidad

**Files:** Modify `deploy/nginx/whatplatform.uk.conf`, `api/compose.yaml`, `deploy/README.md`, `site/index.html`, `docs/store/estado.md`.

- [ ] **Step 1: nginx.** Arriba del fichero (contexto http):
  `log_format platform_stats '$msec|$request_method|$uri|$status|$upstream_cache_status|$remote_addr|$http_user_agent|E';`
  En las dos `location` de `/departures/...`, la de `/service/...` y `= /follow`:
  `access_log syslog:server=127.0.0.1:8511,nohostname,tag=platform,severity=info platform_stats;`
  (las de Andén, `/health`, `/` y el resto siguen con `access_log off` heredado). Nueva `location = /admin` con `auth_basic "stats"; auth_basic_user_file /etc/nginx/platform-admin.htpasswd; include /etc/nginx/platform-admin-key.conf;` (contiene `proxy_set_header X-Admin-Key "...";`, fuera del repo), `proxy_pass http://127.0.0.1:8510;` (conserva `?range=`), `proxy_set_header X-Real-IP ""`, `X-Forwarded-For ""`, `add_header Cache-Control "no-store" always;` y las cabeceras de seguridad del server repetidas, más `X-Frame-Options DENY` y `Referrer-Policy no-referrer`. Actualizar el comentario de cabecera («Privacy: no access logs on disk; What Platform requests go to the stats receiver over local UDP, aggregates only»).
- [ ] **Step 2: compose.** `ports` añade `"127.0.0.1:8511:8511/udp"`; `volumes: - /opt/platform/stats:/data`.
- [ ] **Step 3: README de deploy.** Sección «Stats»: `sudo install -d -o 10001 -g 10001 -m 700 /opt/platform/stats`; generar `ADMIN_KEY` (`openssl rand -hex 32`) en `.env` y el mismo valor en `/etc/nginx/platform-admin-key.conf` (`sudo install -m 600`); `sudo htpasswd -c /etc/nginx/platform-admin.htpasswd <usuario>` (lo hace el usuario: elige usuario y contraseña); comprobar con `curl -s -A platform-check https://api.whatplatform.uk/departures/KGX` y luego `/admin` con `-u`: las cifras suben en ≤ 1 min. Copias en `/opt/platform/stats/backups`. Plan B si no llegan los paquetes: nginx manda a la IP del puente de Docker (`172.17.0.1:8511`, receptor publicado en esa IP) o, si tampoco, `network_mode: host` para el contenedor de la API. El receptor sigue en el mismo proceso que la API (necesita el mismo `Tally`).
- [ ] **Step 4: Política** (`site/index.html`): en el resumen, quitar «no analytics» y decir «no ads, no tracking and no accounts; we count anonymous usage (see below)»; sustituir «Our server keeps no logs of these requests and does not record your IP address» por: «We count how many times each station is requested, per hour and day. To count how many different people use the app each day, your IP address and app version are combined for an instant with a random key that is deleted every day, in a way that cannot be reversed; only the daily totals are kept. Your IP address is never stored.» Fecha de actualización: 23 November 2026.
- [ ] **Step 5: Store.** Revisar App Privacy (App Store) y Data safety (Play): sin datos ligados a usuario ni dispositivo, sin cambios; anotarlo en `docs/store/estado.md` con fecha.
- [ ] **Step 6: Verificar** `cd api && python -m pytest -q tests` → PASS; `docker compose config` sin errores; si hay nginx local, `nginx -t` con el conf (si no, revisión manual).
- [ ] **Step 7: Commit** `feat(deploy): stats over local syslog, /admin behind auth; privacy text`.

### Task 6: Deploy en el VPS (con el usuario)

- [ ] Pedir permiso para sudo en `ssh myairports`. Fuera de hora punta en UK (un reinicio olvida los seguimientos).
- [ ] Pasos de la sección «Stats» del README; el usuario crea el `htpasswd`.
- [ ] `git pull`, `docker compose up -d --build`, copiar nginx, `nginx -t`, reload.
- [ ] Comprobar: `/admin` sin credenciales → 401; con ellas → página; una petición a `/departures/KGX` aparece en ≤ 1 min; `docker compose logs` sin IPs; `ls /var/log/nginx` sin ficheros nuevos que crezcan con peticiones.
- [ ] No capturar paquetes reales (llevan IPs de usuarios). El formato ya lo fija el fixture de Task 1, generado con nginx local; la prueba en el VPS es que una petición propia a `/departures/KGX` aparezca en `/admin`.
- [ ] Si no llegan paquetes por UDP publicado: plan B del README.
