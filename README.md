# Bromley Bins 2.0

Greenfield rewrite of the Bromley Bins iOS app (App Store ID 6504371978) and a
new backend. Users enter a postcode, pick their address, and see upcoming bin
collections, with evening-before reminders, Lock Screen Live Activities and
Home/Lock Screen widgets.

```
            postcode → addresses (on the phone only)
  iPhone ───────────────────────────────────────────► Bromley WasteWorks
    │  property ID, push tokens, reminder settings          ▲
    ▼                                                       │ calendar.ics
  api/ ─────────────────────────────────────────────────────┘
    │  reminder notification + push-to-start Live Activity
    ▼
  APNs ─► iPhone (works even if the app is force-quit)
```

**Privacy split:** postcode and address lookups go straight from the phone to
the council and stay on the device. The server only ever knows the council
property ID (a public reference, `recyclingservices.bromley.gov.uk/waste/<id>`),
reminder settings, hidden bin types and APNs tokens.

## Layout

| Path | What |
|---|---|
| `api/` | Node (ESM, Express 5): collections (WasteWorks calendar), device registration and the reminder push scheduler (`lib/reminders/`, APNs client in `lib/push/`). |
| `ios/BinsCore/` | Swift package shared by the app and widget: models, date-only `CollectionDay`, on-device council address lookup, API client, App Group store, reminder planning, bin illustrations. |
| `ios/BromleyBins/` | SwiftUI app: onboarding, collections, settings, push registration, local reminder fallback, background refresh. |
| `ios/BromleyBinsWidgets/` | WidgetKit extension (small, medium, Lock Screen rectangular/inline/circular). Reads App Group data only. |

## API

```
GET    /api/bins/:propertyId/collections   → { propertyId, collections: [{ date, type, label, normalizedType }], lastUpdated, stale }
PUT    /api/devices/:installationId        ← { apnsToken, liveActivityToken, environment, propertyId, reminders, hiddenTypes }
DELETE /api/devices/:installationId
POST   /api/devices/:installationId/test   (sandbox/debug registrations only) ← { items, phase, delaySeconds, send }
GET /healthcheck, GET /metrics
```

`installationId` is a random UUID the app generates; there are no accounts.
Errors are `{ error: { code, message } }` with codes `INVALID_PROPERTY_ID`,
`PROPERTY_NOT_FOUND`, `INVALID_REGISTRATION`, `INVALID_BODY`, `NOT_REGISTERED`,
`UPSTREAM_ERROR` (502), `UPSTREAM_TIMEOUT` (504), `RATE_LIMITED` (429).

Caching: collections 6 hours with 48 hours stale-if-error (`stale: true`);
concurrent misses coalesce into one upstream request. An empty calendar for a
property we already have a schedule for is treated as an upstream fault, never
as "no collections".

### Reminder pushes

Once a minute the scheduler works out, per registered device and from the
latest cached calendar, which pushes are due and haven't been sent:

| When (London time) | Push |
|---|---|
| Reminder time → midnight, the evening before a collection | Alert notification "Bins out tonight" + push-to-start "Bins out tonight" Live Activity |
| 07:00 → 18:00 on collection day | Push-to-start "Bin day today" Live Activity (the evening one ends after ~8h) |

Windows rather than exact instants mean a send missed during downtime goes out
when the server is back. Sends are recorded per device so nothing is
duplicated across restarts; dead tokens (410/Unregistered) are dropped. Devices
are stored in `$BINS_DATA_DIR/devices.json` (default
`~/.local/share/bromley-bins-api`).

```bash
cd api && npm install && npm test          # unit + fixture tests
cd api && npm run test:live                # opt-in smoke test against WasteWorks (property 3642936)
cd api && PORT=3040 npm start
```

Config (env): `PORT` (3040), `HOST`, `BINS_COUNCIL` (bromley),
`BINS_UPSTREAM_TIMEOUT_MS` (10000), `BINS_COLLECTION_RATE_LIMIT` (60/min/IP),
`BINS_REGISTRATION_RATE_LIMIT` (20), `BINS_TEST_RATE_LIMIT` (10),
`BINS_DATA_DIR`, `BINS_TRUST_PROXY` (loopback).

Push (estate-standard names): `APNS_KEY_ID`, `APNS_TEAM_ID`, and
`APNS_AUTH_KEY_PATH` (or `APNS_AUTH_KEY`). Without them the API serves
collections but sends no reminders, and the app falls back to local reminders.
Each device registers as `sandbox` (debug builds) or `production`, and is
pushed via the matching APNs host.

## Deploying the API

The API takes over the `bromley-bins` deploy entry and the existing
`/bromley-bins` route. The old 1.0.3 backend no longer exists on `sky`, and that
route was forwarding to port 3013, which is now the top-scores scraper. The app
is built against:

```
https://api.skynolimit.dev/bromley-bins
```

`server-tooling` changes:

1. `deploy/config/node_projects.json`, replace the `bromley-bins` entry with:
   ```json
   {
       "name": "bromley-bins",
       "aliases": ["bromley-bins-api"],
       "path": "/Users/mwagstaff/dev/bromley-bins/api",
       "remote_dir": "~/dev/bromley-bins-api",
       "sync_env_local": false,
       "start_command": "npm start",
       "startup_port": 3040,
       "metrics_port": 3040,
       "healthcheck_path": "/healthcheck",
       "service_label": "com.bromley-bins.api",
       "service_description": "Bromley Bins API Service",
       "static_env": {
           "PORT": "3040",
           "TZ": "Europe/London",
           "BINS_DATA_DIR": "/home/mwagstaff/.local/share/bromley-bins-api",
           "APNS_AUTH_KEY_PATH": "/home/mwagstaff/dev/bromley-bins-api/certs/APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8"
       },
       "required_bitwarden_env": ["APNS_KEY_ID", "APNS_TEAM_ID"]
   }
   ```
   (`bromley-bins sky` is already in `PROJECT_DEFAULT_HOSTS`. The deploy links
   `<remote>/certs` to the host's shared `~/.certs`, so tube-track's APNs key is
   reused. `BINS_DATA_DIR` sits outside the deploy folder so registrations
   survive full redeploys.)
2. `caddy/setup-caddy-cloudflare-tunnel.zsh`: in `handle_path /bromley-bins*`, change `127.0.0.1:3013` to `127.0.0.1:3040`, then re-run the Caddy setup.
3. `deploy/tailscale-funnel-apply.sh` and `tailscale/resources/tailscale-funnel-apply.sh`: `apply_route /bromley-bins http://127.0.0.1:3040`.
4. Deploy with `./deploy/node_project.zsh bromley-bins`, then verify with
   `curl https://api.skynolimit.dev/bromley-bins/api/bins/3642936/collections`.

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

### Bin icons

`BinsCore/BinIllustration.swift` holds original vector drawings of the
containers Bromley's bin pages show: green food caddy, green mixed-recycling
box, black paper box, black refuse sack, and black garden bin with a brown lid.
They're deliberately not the council/FixMyStreet PNGs, which are AGPL-3.0.
The monochrome Lock Screen widgets keep SF Symbols, because iOS renders those
as silhouettes.

### Reminders and Live Activities

Reminders are sent by the server (see "Reminder pushes" above), so they arrive
even if the app hasn't run for weeks or was force-quit:

- **"Bins out tonight"**: a notification plus a Lock Screen / Dynamic Island
  Live Activity at the reminder time the evening before.
- **"Bin day today"**: a fresh Live Activity at 07:00 on collection day.

Two activities are needed because iOS keeps a Live Activity active for only
about 8 hours (then up to ~4 more on the Lock Screen). Either can be swiped
away. The activity's own alert uses `silence.caf` so the notification is the
only sound.

The app registers on launch and whenever settings or tokens change
(`PushRegistrar`), re-confirming daily. Until the server has confirmed a
registration (offline, push denied, server down), the app falls back to
scheduling local notifications and on-device scheduled Live Activities, and it
stands those down for whatever the server confirms, so nothing is duplicated.

### Debug-only reminder testing

Debug builds add **Settings → Debug → Test reminders**: pick any bins, choose
evening or collection-day style, pick a delay, and send a notification, a
Live Activity or both. **Send via server push** (on by default) asks the
server to send real sandbox APNs pushes, so you can force-quit the app during
the delay and check delivery. Turn it off to test the on-device path instead.
It also shows what the server has confirmed and lists pending local reminders
and activities. The same actions are available by URL, for Safari, Shortcuts or
`xcrun simctl openurl booted …`:

```
bromleybins://debug/reminder?bins=food,recycling&delay=10&phase=evening&send=both
bromleybins://debug/end
```

`bins`: food, recycling, paper, refuse, garden, other. `phase`: evening or day.
`send`: both, notification or activity. Add `via=server` for a real push.
Release builds ignore these URLs.

Push needs a real device: the simulator receives `xcrun simctl push` alert
payloads, but can't route a Live Activity push-to-start (that needs APNs's
`apns-push-type: liveactivity` header).

### Before submitting 2.0

- **Team**: set to `SJ8X4DLAN9` (as TubeTrack). Confirm that's the team that owns the live app.
- **Build number**: `CURRENT_PROJECT_VERSION = 100`. Must be higher than every build ever uploaded for 1.x — check App Store Connect.
- **App icon**: `ios/BromleyBins/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is a generated placeholder; replace with the real icon.
- **App Group**: register `group.dev.skynolimit.bromleybins` (automatic signing will offer to) for both app and widget.
- **Deploy the API first**, with APNs configured. Release builds always use the production URL.
- **Push Notifications capability**: enable it for the app ID (automatic signing will offer to). `aps-environment` comes from `APS_ENVIRONMENT` (development for Debug, production for Release).
- App Store: new screenshots (old ones show the copy-the-URL onboarding), "What's New" text telling existing users to re-enter their postcode, and App Privacy answers: postcode and address are not collected (on-device only); a device identifier / push token and the council property reference are sent to our server to provide reminders.
