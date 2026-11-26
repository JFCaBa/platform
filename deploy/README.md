# Deploy (VPS `ssh myairports`)

Layout: `/opt/platform/repo` (clone), `/opt/platform/.env` (root, 600: `DARWIN_API_KEY=...` for the board and `DARWIN_SERVICE_KEY=...` for Service Details (train stops; without it `/service/` answers 503), plus, for iPhone follow alerts, `APNS_KEY=` (base64 of the Apple `.p8` key), `APNS_KEY_ID=` and `APNS_TEAM_ID=`; without them `/follow` answers `503 unavailable`. Written by hand, never in git;
`api/compose.yaml` reads it through `env_file`).

Relies on what this server already has for its other sites: `snippets/block-bad-bots.conf`, `snippets/honeypot.conf`,
`/etc/letsencrypt/options-ssl-nginx.conf`, `/etc/letsencrypt/ssl-dhparams.pem` and the `/var/www/certbot` webroot.
API container listens on `127.0.0.1:8510` (and UDP `127.0.0.1:8511` for stats); nginx in front (TLS, 30 s cache per station, no access log on disk).

## First install

```sh
sudo git clone https://github.com/JFCaBa/platform.git /opt/platform/repo
cd /opt/platform/repo/api && sudo docker compose up -d --build
curl -s -A platform-check http://127.0.0.1:8510/health        # {"ok":true}

# certificate (HTTP-only bootstrap: the full site needs the cert to exist)
sudo mkdir -p /var/cache/nginx/platform /var/www/certbot
sudo cp /opt/platform/repo/deploy/nginx/whatplatform.uk.conf /etc/nginx/sites-available/
sudo awk '/^server \{/{n++} n<=1' /etc/nginx/sites-available/whatplatform.uk.conf | sudo tee /etc/nginx/sites-enabled/whatplatform.uk.conf >/dev/null
sudo nginx -t && sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/certbot -d whatplatform.uk -d www.whatplatform.uk -d api.whatplatform.uk \
  --deploy-hook "nginx -t && systemctl reload nginx"
sudo cp /etc/nginx/sites-available/whatplatform.uk.conf /etc/nginx/sites-enabled/whatplatform.uk.conf
sudo nginx -t && sudo systemctl reload nginx
```

## Stats (`/admin`)

nginx sends each What Platform API request over UDP to `127.0.0.1:8511` (syslog, no file on
disk); the API keeps only aggregates in `/opt/platform/stats/stats.db` and shows them at
`https://api.whatplatform.uk/admin` behind a password. Once:

```sh
sudo install -d -o 10001 -g 10001 -m 700 /opt/platform/stats            # API's uid in the image
KEY=$(openssl rand -hex 32)
printf '\nADMIN_KEY=%s\n' "$KEY" | sudo tee -a /opt/platform/.env >/dev/null   # leading \n: .env may lack one
echo "proxy_set_header X-Admin-Key \"$KEY\";" | sudo tee /etc/nginx/platform-admin-key.conf >/dev/null
sudo chmod 600 /etc/nginx/platform-admin-key.conf; unset KEY
sudo apt-get install -y apache2-utils                                     # htpasswd, if missing
sudo htpasswd -c /etc/nginx/platform-admin.htpasswd <user>                # you choose user + password
```

Then the usual update (API + nginx). Check: `curl -s -A platform-check https://api.whatplatform.uk/departures/KGX`,
then open `/admin` (401 without the password); the request shows up within a minute. Daily backups
(7 kept) in `/opt/platform/stats/backups`. Without `ADMIN_KEY` `/admin` answers 404; if the DB cannot be
opened the API logs `stats: off` and serves the rest as usual.

If nothing arrives (Docker's UDP publishing on 127.0.0.1): publish `172.17.0.1:8511:8511/udp` and point
nginx's `syslog:server=` at `172.17.0.1:8511`, or as a last resort `network_mode: host` for the API
container. The receiver must stay in the API process (it shares the in-memory tally with `/admin`).

## Stations (`/stations.json`)

`https://api.whatplatform.uk/stations.json` is rebuilt monthly on this server from NaPTAN (the same
`pipeline/build_stations.py` as the GitHub Pages workflow, which keeps running for installed apps
until they all read from here). The API reads the same file (`/stations` in the container), with
its bundled copy as fallback. Once:

```sh
sudo install -d -o ubuntu -g ubuntu -m 755 /opt/platform/stations
bash /opt/platform/repo/deploy/stations/refresh.sh                      # first build, as ubuntu
( crontab -l; echo '17 4 3 * * /usr/bin/bash /opt/platform/repo/deploy/stations/refresh.sh >> /opt/platform/stations/refresh.log 2>&1' ) | crontab -
```

A failed build keeps the previous file; see `/opt/platform/stations/refresh.log`.

## Website (`whatplatform.uk`)

Static files in `site/`, served by nginx from the repo checkout (`/opt/platform/repo/site`):
`index.html` (shell for `/` and `/station/{CRS}`), `privacy.html` (`/privacy`), `style.css`,
`js/*.js` (ES modules, no build), the App Store badge and icons. Everything else in `site/`
(`test/`, `package.json`) answers 404. The browser calls `https://api.whatplatform.uk` directly;
the API locations it uses send `Access-Control-Allow-Origin: https://whatplatform.uk`.

Search engines get one crawlable page per station: `deploy/web/build_pages.py` builds
`station/{CRS}.html` (title, canonical, JSON-LD, nearby stations; the board still comes from the JS),
`stations.html` (A–Z, served at `/stations`) and `sitemap.xml` from `stations.json` into
`/opt/platform/pages/current` (a symlink swapped atomically; the previous build is kept).
`refresh.sh` rebuilds them monthly; rebuild by hand after a deploy that changes `site/index.html`.
Any 404 answers with the page shell and status 404. `robots.txt` points to the sitemap. Registered
in Google Search Console (Domain property) and Bing Webmaster Tools.

- Tests: `node --test site/test/*.test.js` (Node's own runner, no dependencies) and
  `python3 -m unittest discover -s deploy/web -p 'test_*.py'`.
- First time on the server: `sudo install -d -o ubuntu -g ubuntu /opt/platform/pages`, then the
  build below.
- Local: `python3 deploy/web/dev.py` → http://localhost:8000/ (serves `site/` like nginx and
  proxies the API with a User-Agent the stats do not count as a person).
- Deploy: `git pull` (files) and, when the nginx conf changed, copy it and reload (Update below).
- Check:

  ```bash
  curl -sI -A Mozilla/5.0 https://whatplatform.uk/ | grep -i -E '^HTTP|content-security'   # 200 + CSP
  curl -sI -A Mozilla/5.0 https://whatplatform.uk/station/KGX | head -1                      # 200
  curl -s -A Mozilla/5.0 https://whatplatform.uk/station/KGX | grep -o '<title>[^<]*'         # Kings Cross
  curl -sI -A Mozilla/5.0 https://whatplatform.uk/station/ZZZ | head -1                      # 404
  curl -s -A Mozilla/5.0 https://whatplatform.uk/sitemap.xml | grep -c '<url>'               # stations + 3
  curl -sI -A Mozilla/5.0 https://whatplatform.uk/privacy | head -1                          # 200
  curl -sI -A Mozilla/5.0 https://whatplatform.uk/test/api.test.js | head -1                 # 404
  curl -sI -A Mozilla/5.0 https://api.whatplatform.uk/departures/KGX | grep -i access-control  # whatplatform.uk
  ```

## Update

```sh
cd /opt/platform/repo && sudo git pull --ff-only
python3 deploy/web/build_pages.py                                # website pages (as ubuntu)
cd api && sudo docker compose up -d --build                     # API changes
# API logs: Darwin failures (station code + reason), `apns <status> <reason>` / `apns network <Class>`,
# `follow poller: <Class>`, `unhandled <Class>` and a startup line `follow: on|off`.
# Never tokens, trains, requests or client addresses.
sudo docker compose logs --tail 20
sudo cp ../deploy/nginx/whatplatform.uk.conf /etc/nginx/sites-enabled/ && sudo nginx -t && sudo systemctl reload nginx   # nginx changes
```

The privacy page is served straight from `/opt/platform/repo/site`, so `git pull` updates it.

### APNs key and restarts

Produce `APNS_KEY` from the `.p8` with `base64 -i AuthKey_XXXX.p8 | tr -d '\n'`.
Follows live only in the API's memory: deploy outside UK commuting peaks, because a restart forgets follows.
Rebuild with `docker compose up -d --build` so the image picks up the new dependencies.

## Check

nginx blocks `curl/` user agents (bot filter): pass `-A platform-check`.

```sh
curl -s -A platform-check https://api.whatplatform.uk/departures/KGX | head -c 300
curl -s -A platform-check -o /dev/null -D - https://api.whatplatform.uk/departures/KGX | grep -i x-cache   # HIT on the 2nd call within 30 s
```

```sh
curl -s -A platform-check -X POST https://api.whatplatform.uk/follow -d '{}'   # {"error":"bad request"} (400) with APNS_* set
```

Without the `APNS_*` variables every `/follow` request answers `503 unavailable` (checked before the body), and the log says `follow: off`.
