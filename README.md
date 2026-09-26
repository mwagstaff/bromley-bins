# Bromley Bins 2.0

Greenfield rewrite of the Bromley Bins iOS app (App Store ID 6504371978) and a
new backend. Users enter a postcode, pick their address, and see upcoming bin
collections, with evening-before reminders and Home/Lock Screen widgets.

```
Bromley WasteWorks  →  api/ (WasteWorks adapter + normalised JSON)  →  ios/ (app + widgets)
```

The iOS app never talks to or parses the council site; only `api/` does.

## Layout

| Path | What |
|---|---|
| `api/` | Node (ESM, Express 5) API. WasteWorks specifics live only in `lib/bins/wasteworks-provider.js` and the two parsers. |
| `ios/BinsCore/` | Swift package shared by the app and widget: models, date-only `CollectionDay`, API client, App Group store, reminder planning, bin styling. |
| `ios/BromleyBins/` | SwiftUI app: onboarding, collections, settings, reminders, background refresh. |
| `ios/BromleyBinsWidgets/` | WidgetKit extension (small, medium, Lock Screen rectangular/inline/circular). Reads App Group data only. |

## API

```
GET /api/bins/addresses?postcode=BR1%201AA   → { postcode, addresses: [{ propertyId, address }] }
GET /api/bins/:propertyId/collections        → { propertyId, collections: [{ date, type, label, normalizedType }], lastUpdated, stale }
GET /api/bins/uprn/:uprn                     → { uprn, propertyId }
GET /healthcheck, GET /metrics
```

Errors are `{ error: { code, message } }` with codes `INVALID_POSTCODE`,
`NO_ADDRESSES_FOUND`, `INVALID_PROPERTY_ID`, `PROPERTY_NOT_FOUND`,
`UPSTREAM_ERROR` (502), `UPSTREAM_TIMEOUT` (504), `RATE_LIMITED` (429).

Caching: addresses 7 days; collections 6 hours with 48 hours stale-if-error
(`stale: true`); concurrent misses coalesce into one upstream request. An empty
calendar for a property we already have a schedule for is treated as an
upstream fault, never as "no collections".

```bash
cd api && npm install && npm test          # unit + fixture tests
cd api && npm run test:live                # opt-in smoke test against WasteWorks (property 3642936)
cd api && PORT=3040 npm start
```

Config (env): `PORT` (3040), `HOST`, `BINS_COUNCIL` (bromley),
`BINS_UPSTREAM_TIMEOUT_MS` (10000), `BINS_ADDRESS_RATE_LIMIT` (20/min/IP),
`BINS_COLLECTION_RATE_LIMIT` (60/min/IP), `BINS_TRUST_PROXY` (loopback).

## Deploying the API (not done yet — needs server-tooling changes)

Runs **alongside** the old 1.0.3 backend (port 3013, `/bromley-bins`), which
must keep running for users who haven't updated. The new route must not start
with `/bromley-bins`, because Caddy's existing `handle_path /bromley-bins*`
would swallow it. The app is built against:

```
https://api.skynolimit.dev/bin-collections
```

1. `server-tooling/deploy/config/node_projects.json`:
   ```json
   {
       "name": "bin-collections-api",
       "aliases": ["bromley-bins-api"],
       "path": "/Users/mwagstaff/dev/bromley-bins/api",
       "start_command": "npm start",
       "startup_port": 3040,
       "metrics_port": 3040,
       "healthcheck_path": "/healthcheck",
       "service_label": "com.bin-collections.api",
       "service_description": "Bromley Bins 2 API",
       "static_env": { "PORT": "3040", "TZ": "Europe/London" }
   }
   ```
2. `server-tooling/deploy/node_project.zsh`: add `bin-collections-api sky` to `PROJECT_DEFAULT_HOSTS`.
3. `server-tooling/caddy/setup-caddy-cloudflare-tunnel.zsh`: add
   ```
   handle_path /bin-collections* {
     reverse_proxy http://127.0.0.1:3040 {
       header_up Host 127.0.0.1
       header_up X-Forwarded-Host {host}
       header_up X-Forwarded-Proto https
     }
   }
   ```
4. Verify: `curl https://api.skynolimit.dev/bin-collections/api/bins/3642936/collections`

## iOS

Xcode 27, iOS 26+, Swift 6 strict concurrency, universal (iPhone + iPad).
Bundle ID `dev.skynolimit.bromleybins` (same as the live app so this ships as
an update), widget `dev.skynolimit.bromleybins.widgets`, App Group
`group.dev.skynolimit.bromleybins`, version 2.0.0.

```bash
cd ios/BinsCore && swift test
cd ios && xcodebuild -project BromleyBins.xcodeproj -scheme BromleyBins -destination 'generic/platform=iOS Simulator' build
```

Debug builds can target a local API: set the `BINS_API_BASE_URL` environment
variable in the scheme (e.g. `http://127.0.0.1:3040`).

### Before submitting 2.0

- **Team**: set to `SJ8X4DLAN9` (as TubeTrack). Confirm that's the team that owns the live app.
- **Build number**: `CURRENT_PROJECT_VERSION = 100`. Must be higher than every build ever uploaded for 1.x — check App Store Connect.
- **App icon**: `ios/BromleyBins/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is a generated placeholder; replace with the real icon.
- **App Group**: register `group.dev.skynolimit.bromleybins` (automatic signing will offer to) for both app and widget.
- **Deploy the API first** — release builds always use the production URL.
- App Store: new screenshots (old ones show the copy-the-URL onboarding), "What's New" text telling existing users to re-enter their postcode, and review the App Privacy answers (postcode is sent to our API; the address stays on device).
