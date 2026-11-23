# What Platform — página de estadísticas (diseño)

Fecha: 23-11-2026 · Estado: borrador para aprobación

## Intención

Una pequeña página de administración en el servidor para ver cómo se usa What Platform:
la evolución día a día, qué estaciones importan más y algo que se pueda enseñar a otra
persona en el móvil. Hoy no hay ningún dato: nginx tiene `access_log off` y la API no
registra peticiones (política de privacidad).

**Éxito:** abres `api.whatplatform.uk/admin` en el móvil y en un vistazo ves personas al
día, estaciones más vistas, horas punta, versiones y trenes seguidos, con un aspecto lo
bastante cuidado para enseñarlo.

## Objetivos

- Visitantes únicos aproximados por día, sin guardar la IP nunca.
- Peticiones por día, por hora y por estación (CRS); ranking de estaciones.
- Reparto por versión de la app (del User-Agent `WhatPlatform/x.y`).
- Trenes seguidos en iPhone (`/follow`): altas por día y activos ahora.
- Página protegida con usuario y contraseña, cómoda en el móvil, con el estilo de la app.

## No objetivos

- Separar iPhone de Android (la app manda el mismo User-Agent; quedaría para una versión
  futura de la app que lo añada).
- Andén: comparte nginx (`/anden/...`) pero su política dice que no se registra nada.
  Sus peticiones no se cuentan.
- Cambios en la app.
- Tiempo real al segundo: basta con datos al minuto.

## Anti-objetivos (sería un fracaso aunque funcione)

- Que una IP, un User-Agent completo o un identificador estable llegue a disco o a un log
  (incluido el log de Docker y el `error_log` de nginx).
- Que el hash de un día se pueda relacionar con el de otro (eso sería seguimiento).
- Contar mal por culpa de la caché de nginx (ver Restricciones).
- Que la recogida de estadísticas pueda tumbar o frenar `/departures`.

## Restricciones

- nginx guarda en caché `/departures/{CRS}` 30–60 s y `/service/{id}` 30 s: la API solo ve
  los fallos de caché. **Hay que contar en nginx**, no en el código Python.
- El contenedor `platform-api` es `read_only` con `tmpfs /tmp`; la SQLite necesita un
  volumen persistente en el host (p. ej. `/opt/platform/stats`).
- Deploy en `/opt/platform/repo` (propiedad de root): requiere sudo, preguntar antes
  (memoria del proyecto).
- La política de privacidad (`site/index.html`) dice hoy «Our server keeps no logs of these
  requests and does not record your IP address» y «no analytics». Debe actualizarse en el
  mismo cambio, antes o a la vez que el deploy.

## Enfoques considerados

- **A. Log de nginx sin IP + resumen en la API + página propia.** Sin visitantes únicos.
- **B. GoAccess sobre logs de nginx.** Rápido, pero genérico, necesita IPs en disco y no
  sirve para enseñar.
- **C. A + visitantes únicos aproximados con hash diario (estilo Plausible).** ← **Elegido
  por el usuario**: quiere contar personas; acepta explicarlo en la política.

## Diseño

### Recogida

- En el `server` de `api.whatplatform.uk`, en las `location` de What Platform
  (`/departures/...`, `/service/...`, `/follow`), nginx envía cada petición por syslog
  (`access_log syslog:server=127.0.0.1:<puerto>,nohostname <formato>;`) a un receptor UDP en
  el contenedor de la API. No se escribe nada en disco en nginx. Las `location` de Andén
  siguen con `access_log off`.
- Formato de la línea: hora, método, URI, estado, `$upstream_cache_status`, IP, User-Agent.
- El receptor (hilo en el proceso de la API) por cada línea:
  - calcula `hash = HMAC(clave_del_día, IP + User-Agent)` en memoria y lo mete en un set
    del día; la IP y el User-Agent se descartan al momento;
  - extrae del User-Agent solo la versión (`WhatPlatform/1.5` → `1.5`; otro → `otro`);
  - incrementa contadores en memoria: día, hora, estación (CRS de `/departures/{CRS}`),
    tipo de ruta, versión.
- La clave del día es aleatoria, vive solo en memoria y se reemplaza a medianoche (hora de
  Londres). Al cambiar de día se guarda `len(set)` como visitantes del día y se borran set
  y clave. Si el proceso se reinicia a mitad de día se pierde la clave y el set: los
  visitantes de ese día salen algo inflados; se acepta.
- Cada minuto los contadores se vuelcan a SQLite (suma incremental). El recuento parcial de
  visitantes de hoy también se guarda para mostrarlo.
- Seguimientos: contar altas por día en el `POST /follow` (ya pasa por la API, sin caché) y
  leer los activos del estado en memoria que ya existe.
- Pérdida de algún paquete UDP: aceptable. El receptor nunca debe bloquear ni romper las
  peticiones normales.

### Almacenamiento

- SQLite en volumen del host, solo agregados: por día (visitantes, peticiones, altas de
  seguimiento), por día+hora, por día+estación, por día+versión. Se guardan para siempre.

### Página `/admin`

- Servida por la API (HTML con los datos ya dentro, o HTML + `/admin/data.json`), protegida
  con `auth_basic` en nginx (`htpasswd` en `/opt/platform/`, fuera del repo). Sin caché.
- Selector Hoy · 7 d · 30 d · Todo.
- Tarjetas: personas hoy, estaciones distintas hoy, trenes seguidos (activos / hoy).
- Personas al día (gráfico de 30 días), estaciones más vistas (barras, top 20 con nombre de
  estación), peticiones por hora, versiones de la app.
- Estilo de What Platform, claro/oscuro, legible en el móvil.

```
What Platform · estadísticas        Hoy  7d  30d  Todo
┌───────────┬───────────┬───────────┐
│ Personas  │ Estaciones│ Trenes    │
│ hoy  142  │ hoy  61   │ seguidos 9│
└───────────┴───────────┴───────────┘
Personas al día          ▁▂▂▃▅▄▆▇  (30 días)
Estaciones más vistas    KGX ████████ 1.204
                         EUS █████    760 …
Horas punta              gráfico por hora
Versiones de la app      1.5 · 82%   1.4 · 15% …
```

### Privacidad

- `site/index.html`: sustituir «no analytics» y «does not record your IP address» por un
  texto honesto: contamos peticiones por estación y hora, y visitantes únicos por día; para
  esto último la IP y el User-Agent se combinan un instante con una clave aleatoria que se
  borra cada día, de forma no reversible, y nunca se guardan. Fecha de actualización nueva.
- Comentario de cabecera del nginx conf actualizado.
- App Privacy de App Store y Data safety de Play: no cambian (no hay datos ligados a un
  usuario ni a un dispositivo); revisarlo y anotarlo en `docs/store/estado.md`.

## Decidido por Claude (corregible)

- syslog UDP en vez de log en disco, para que la IP no toque nunca el disco.
- Medianoche en hora de Londres para el corte de día.
- Agregados para siempre (ocupan muy poco).
- Contraseña con `auth_basic` de nginx.

## Precisiones (tras la revisión; decididas por Claude)

- **Red:** el receptor UDP escucha dentro del contenedor y compose publica
  `127.0.0.1:<puerto>:<puerto>/udp`, igual que el TCP actual. Hay que comprobar en el deploy
  que llegan paquetes. Si el proxy de Docker da problemas, el plan B es mover el receptor a
  un contenedor aparte con red del host, que escribe en la misma SQLite.
- **Qué cuenta:** solo respuestas 2xx/3xx/304 de `/departures/...`, `/service/...` y
  `POST /follow`. No cuentan 4xx/5xx, 429, bots bloqueados, `DELETE /follow` ni `/health`.
  Todos los estados de caché (HIT, MISS, STALE…) cuentan igual.
- **Visitantes:** solo peticiones con User-Agent `WhatPlatform/…`. El resto (curl, bots)
  suma en «otro» en peticiones, pero no como persona.
- **`/admin`:** nueva `location` con `auth_basic`, `proxy_pass` a 8510, `no-store` y las
  mismas cabeceras de seguridad. La API solo responde a `/admin` si llega una cabecera
  secreta que pone nginx (valor en `/opt/platform/.env`), para que nada más en el host lo lea.
  El usuario crea el `htpasswd` (paso manual con sudo, en el README de deploy).
- **SQLite:** `/opt/platform/stats` con `chown 10001`. Copia diaria con `sqlite3 .backup`
  a un fichero junto al original (7 copias). Si el fichero se corrompe se empieza de cero;
  se acepta.
- **Altas de seguimiento:** cuenta cada `POST /follow` con éxito que crea un seguimiento
  nuevo (no las renovaciones del mismo token). «Activos ahora» = seguimientos vigentes en
  el estado en memoria de `follow.py`.
- **Orden del deploy:** política y recogida van en el mismo `git pull`. App Privacy y Data
  safety: Claude revisa las respuestas y anota la conclusión en `docs/store/estado.md`.

## A criterio de quien lo construya

- Puerto UDP, esquema exacto de tablas, librería o SVG a mano para los gráficos.
- Si la página lleva los datos incrustados o los pide a un JSON.
- Tests: receptor (parseo, hash, cambio de día), volcado a SQLite, agregados de la página.
