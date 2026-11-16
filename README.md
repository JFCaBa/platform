# Platform

The next National Rail departures at your nearest station in Great Britain, with
delays, cancellations and the platform. Free, no ads, no accounts, no data collected.

- `app/`: Flutter app (iOS + Android)
- `api/`: small API on our server (`https://api.whatplatform.uk/departures/{CRS}`) that calls Darwin
- `pipeline/`: builds `stations.json` (published on GitHub Pages)
- `deploy/`: nginx site
- `docs/`: design, plan, Darwin notes

Data: National Rail (Darwin, via the Rail Data Marketplace). Station locations: NaPTAN (OGL).
