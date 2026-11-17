# What Platform: notes for App Review (iOS 1.1.0)

Paste into App Store Connect → What Platform → version → App Review Information → Notes.

---

What Platform shows the next National Rail departures at the station nearest to you in Great Britain, with the platform in large type. No account, no login, no in-app purchases, no ads, no analytics.

HOW TO USE IT
- Open the app. If location is allowed, it shows the nearest station's live departures. Outside Great Britain (or with location denied), tap the station name at the top and search any station by name or code, e.g. "King's Cross" or "BHM".
- Tap a train to see the stops it still has to make, with expected times. Tap it again to close.
- Tap a destination chip above the list to show only those trains ("All" clears it).
- "N service alerts" at the top opens National Rail's messages for the station.

EXTERNAL SERVICES
- Our own server (api.whatplatform.uk) relays live data from National Rail's Darwin feeds (Live Departure Board and Service Details), licensed to us through the Rail Data Marketplace. Requests contain only a station code or a train's daily service code; the server keeps no request logs.
- Station list (NaPTAN, Department for Transport, Open Government Licence), hosted on GitHub Pages.
- Apple Core Location, only on the device to find the nearest station; the location never leaves the phone.

REGIONAL DIFFERENCES
Same everywhere; content covers Great Britain's National Rail stations.

THIRD-PARTY MATERIAL
Independent app, not affiliated with National Rail or any train operator; no rail logos or trademarks. Train data: National Rail (Darwin) via the Rail Data Marketplace under its open licence; credited on screen ("Data: National Rail"). Station locations: NaPTAN, OGL.
