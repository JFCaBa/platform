# stations.json en el VPS — plan

Fecha: 24-11-2026 · Aprobado por el usuario en conversación (diseño corto).

**Goal:** servir la lista de estaciones desde `https://api.whatplatform.uk/stations.json`, generada
en el VPS, para poder hacer privado el repo más adelante sin depender de GitHub Pages.

**Contexto:** hoy `stations.yml` (GitHub Actions, mensual, día 3 04:17 UTC) ejecuta
`pipeline/build_stations.py` (stdlib, Python 3.12) y publica en `jfcaba.github.io/platform/stations.json`.
La app (`app/lib/config.dart` `stationsUrl`) y la API (`server.py` `STATIONS_URL`) lo descargan;
ambas tienen copia empaquetada de reserva (`app/assets/stations.json`, `api/platform_api/stations.json`).

## Global Constraints

- GitHub Pages y `stations.yml` siguen funcionando sin cambios hasta que la nueva versión de la app
  esté en las tiendas y adoptada; después se desactivan y el repo pasa a privado (fuera de este plan).
- Nunca servir un fichero vacío o roto: se valida antes de sustituir (JSON válido, `version == 1`,
  ≥ 2400 estaciones, cada una con `crs` de 3 letras, `name`, `lat`, `lon`).
- El fichero no cuenta en las estadísticas (`/admin`).

## Task 1: script de refresco en el VPS

**Files:** Create `deploy/stations/refresh.sh`, `deploy/stations/check_stations.py`,
test `pipeline/tests/test_check_stations.py` (o junto al script si el import es más simple).

- `check_stations.py <fichero>` → exit 0 si cumple la validación de Global Constraints; exit 1 y una
  línea a stderr con el motivo si no.
- `refresh.sh` (bash, `set -euo pipefail`): `cd /opt/platform/repo`; `PYTHONDONTWRITEBYTECODE=1`;
  ejecuta `python3 -m unittest discover -s tests` en `pipeline/`; genera en
  `/opt/platform/stations/stations.json.tmp`; `check_stations.py` sobre el tmp; `mv` atómico a
  `stations.json`. Log con fecha a `/opt/platform/stations/refresh.log` (sin datos de usuarios).
  Si algo falla, el fichero anterior se queda y el log dice qué paso falló.
- Tests de `check_stations`: válido → 0; JSON roto, lista corta, `crs` en minúsculas, falta `lat` → 1.

## Task 2: nginx

En el `server` de `api.whatplatform.uk`:
```
location = /stations.json {
    limit_except GET { deny all; }
    alias /opt/platform/stations/stations.json;
    default_type application/json;
    add_header Cache-Control "public, max-age=86400" always;
    gzip on; gzip_types application/json;
    (cabeceras de seguridad del server repetidas)
}
```
Sin `access_log` (hereda `off`): no cuenta en estadísticas. ETag/`If-None-Match` los da nginx.

## Task 3: la API lee el fichero local

- `compose.yaml`: volumen `/opt/platform/stations:/stations:ro`.
- `load_stations(url, fallback, local: Path | None = None)`: primero `local` si existe y es válido
  (≥ 2400), luego URL, luego empaquetado. `main` pasa `local=Path(env.get("STATIONS_FILE", "/stations/stations.json"))`.
  Los nombres de estación de `/admin` salen de la misma fuente (`station_names`), con el empaquetado
  como reserva.
- Tests: local válido gana a URL; local corto/roto → URL; sin local → como hoy.

## Task 4: deploy (con sudo, aprobado)

- `sudo install -d -o ubuntu -g ubuntu -m 755 /opt/platform/stations`; primera ejecución de
  `refresh.sh` a mano; cron de `ubuntu`: `17 4 3 * * /usr/bin/bash /opt/platform/repo/deploy/stations/refresh.sh`.
- `git pull`, API `docker compose up -d --build`, nginx `cp` + `nginx -t` + reload (con copia previa).
- Comprobar: `curl -A WhatPlatform/test https://api.whatplatform.uk/stations.json` → 200 JSON igual en
  contenido al de GitHub Pages (mismo nº de estaciones); segunda petición con `If-None-Match` → 304.
- `deploy/README.md`: sección «Stations».

## Task 5: app (rama de la próxima versión, `feat/home-widget`)

- `stationsUrl = 'https://api.whatplatform.uk/stations.json'`.
- Test que falla si `userAgent` (`WhatPlatform/x.y`) no coincide con `major.minor` de `pubspec.yaml`
  (lee el fichero), para que no vuelva a quedarse fija.
- No se compila ni se sube a tiendas aquí: queda para la próxima build.
