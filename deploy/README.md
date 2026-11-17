# Deploy (VPS `ssh myairports`)

Layout: `/opt/platform/repo` (clone), `/opt/platform/.env` (root, 600: `DARWIN_API_KEY=...` for the board and `DARWIN_SERVICE_KEY=...` for Service Details (train stops; without it `/service/` answers 503), plus, for iPhone follow alerts, `APNS_KEY=` (base64 of the Apple `.p8` key), `APNS_KEY_ID=` and `APNS_TEAM_ID=`; without them `/follow` answers `503 unavailable`. Written by hand, never in git;
`api/compose.yaml` reads it through `env_file`).

Relies on what this server already has for its other sites: `snippets/block-bad-bots.conf`, `snippets/honeypot.conf`,
`/etc/letsencrypt/options-ssl-nginx.conf`, `/etc/letsencrypt/ssl-dhparams.pem` and the `/var/www/certbot` webroot.
API container listens on `127.0.0.1:8510`; nginx in front (TLS, 30 s cache per station, no access log).

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

## Update

```sh
cd /opt/platform/repo && sudo git pull --ff-only
cd api && sudo docker compose up -d --build                     # API changes
# API logs: only Darwin failures (station code + reason), never requests or client addresses
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
curl -s -A platform-check -X POST https://api.whatplatform.uk/follow -d '{}'   # {"error":"bad request"} (400)
```

Without the `APNS_*` variables a valid `/follow` body answers `503 unavailable`.
