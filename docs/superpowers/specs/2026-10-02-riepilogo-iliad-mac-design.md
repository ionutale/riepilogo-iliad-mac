# Riepilogo Iliad macOS — Design Spec

Date: 2026-10-02
Status: Design approved in conversation; written spec pending user review
Project path: `/Users/ionutale/developer-playground/riepilogo-iliad-mac`
Predecessor: `/Users/ionutale/developer-playground/riepilogo-iliad` (Go web app, stays as reference)

## 1. Goal

A native macOS app (SwiftUI) that shows the state of 5 Iliad Italia SIMs:

- Menu bar extra with total remaining data at a glance and a warning state
- Popover with one card per SIM: used-fill progress bar, remaining/allowance, renewal date and days, credit, per-account error/stale badge
- History window with per-SIM charts (Swift Charts) backed by the same SQLite history as the Go app
- Automatic background refresh (default 4h) with manual "Aggiorna ora"
- Native extras: notifications (low data, exhausted, renewed), launch at login

It replaces the Go web app for daily use. No web server, no open ports.

## 2. Context & motivation

The Go app works but is a browser dashboard driven by a background CLI process. The user wants a native app: menu bar presence, notifications, Keychain instead of a credentials file, and no terminal.

Hard-won knowledge carried over from the Go app:

- Iliad Italia has no official API; data comes from the Area Personale (`/account/login` form POST → `/account/consumi-e-credito` HTML).
- The portal's WAF rejects Go's default User-Agent with 403; a browser User-Agent is required.
- On some networks (Iliad mobile/hotspot CGNAT), the portal's `/account/*` paths enter an http↔https redirect loop before the app is reached. Safari is unaffected because it exits via iCloud Private Relay (verified: relay egress `172.225.96.223` vs direct `37.163.169.85`). Third-party apps cannot use Private Relay.
- Therefore the native app keeps a Safari bridge as automatic fallback: it drives Safari via AppleScript (same-origin XHR: logout → login → GET consumi), which requires Safari's "Allow JavaScript from Apple Events" (Develop menu) once.

## 3. Decisions

- Full Swift/SwiftUI rewrite. Xcode 27, Swift 6 language mode, deployment target macOS 15 (built/tested on macOS 26).
- App shell: `MenuBarExtra` (icon + total GB, warning state) + popover + separate history `Window` + Settings scene.
- Persistence: GRDB.swift (SQLite), reusing the Go app's `readings` schema so history migrates.
- Parsing: SwiftSoup port of the Go parser, with the anonymized HTML fixtures as tests.
- Fetch: `HTTPFetcher` (URLSession, ephemeral session per account) → automatic `SafariFetcher` fallback on network-class failures only.
- Credentials: Keychain. No config file; settings in `UserDefaults`.
- Import: accounts from the Go app's `config.yaml` (Yams for YAML parsing) and history from `iliad.db`, via file pickers in Settings.
- Italian UI. Bundle id `it.ionut.riepilogo-iliad`. Unsigned local build; no notarization, no App Store.
- Project generation: XcodeGen (`project.yml` committed, `.xcodeproj` generated and gitignored); build/test via `xcodebuild`.
- Dependencies (SPM): GRDB.swift, SwiftSoup, Yams.

## 4. Architecture

| Component | Responsibility |
|---|---|
| `App/RiepilogoIliadApp.swift` | App entry, scenes (MenuBarExtra, Window, Settings), wiring |
| `Core/AppModel.swift` | `@Observable` UI state: snapshot, refreshing flag, last cycle, settings |
| `Core/RefreshCoordinator.swift` | Actor: single-flight cycles, sequential accounts, persistence, snapshot publishing |
| `Core/HTTPFetcher.swift` | URLSession fetch: login POST + consumi GET, isolated cookies, browser UA |
| `Core/SafariFetcher.swift` | AppleScript bridge: logout/login/GET via Safari XHR |
| `Core/AutoFetcher.swift` | Direct first, Safari fallback on network-class errors |
| `Core/Parser.swift` | `parseAccountPage(html:now:renewalDay:)` pure function |
| `Core/Store.swift` | GRDB: insert readings, last-good, latest, history, retention |
| `Core/Models.swift` | `Account`, `AccountData`, `Reading`, `Entry`, error taxonomy |
| `Core/Keychain.swift` | Generic-password storage for account credentials |
| `Core/Notifications.swift` | Local notifications: low, exhausted, renewed |
| `Core/Settings.swift` | UserDefaults-backed settings (interval, mode, thresholds, launch at login) |

Data flow: `RefreshCoordinator` (timer/manual) → per account `AutoFetcher` → HTML → `Parser` → one `Reading` row in GRDB → snapshot → `AppModel` (MainActor) → views. History views query GRDB directly.

## 5. Fetch engine

### HTTPFetcher
- One `URLSession` per account with `URLSessionConfiguration.ephemeral` (isolated in-memory cookies).
- `POST https://www.iliad.it/account/login` form fields `login-ident`, `login-pwd`; follow redirects; then `GET /account/consumi-e-credito`.
- Browser User-Agent header on both requests (WAF requirement).
- 20s timeout; auth detection: final URL path `/account/login` or page containing `name="login-ident"`.

### SafariFetcher
- Runs the same AppleScript as the Go app by invoking `osascript` via `Process`, passing the JS as a script argument (`osascript -e script -- js`) — this avoids embedding credentials in the script text and reuses a mechanism already proven in the Go app.
- Reuses/creates a Safari tab on `iliad.it`; JS: `GET /account/?logout=user` → `POST /account/login` → `GET /account/consumi-e-credito`; returns `responseText`.
- Detects the "Allow JavaScript from Apple Events" error and surfaces it as a distinct actionable error.
- Credentials are not stored by Safari; the bridge only performs requests.

### AutoFetcher
- Try direct; on `network`-class errors (redirect loop, HTTP 4xx/5xx, timeout) retry via Safari.
- `auth` and `parse` errors do NOT fall back (same failure everywhere; avoid cycling the Safari session).
- Records which path served each account (shown in "Verifica account" results).

### RefreshCoordinator
- Single-flight: at most one cycle at a time; manual trigger while running is a no-op.
- Sequential accounts, one `Reading` row per attempt (success or sanitized error), retention 180 days.
- In-memory `Entry` per account: last good reading, last attempt time, last error.
- Refresh on app start, on interval (default 4h, min 1h), on manual trigger, and after wake if stale (2× interval).
- Error taxonomy mirrors the Go app: `auth`, `parse`, `network`, `safariJSSetting`, plus `keychain`/`store` internal errors.

## 6. Parsing

Pure function `parseAccountPage(html: String, now: Date, renewalDay: Int?) -> AccountData` ported from Go:

- Fields: credit €, used GB, remaining GB, allowance GB, renewal date, period start/end, phone, offer name.
- Rules: Italian/English number separators (last separator wins), B/KB/MB/GB/TB normalization, used/allowance pair, `span.big.red` + sibling unit for remaining, fallbacks (remaining = allowance − used; allowance = used + remaining), explicit renewal date (numeric and Italian textual months), period-end + 1 day fallback, `renewalDay` last resort, generic offer-label filtering with scanning past "offerta mobile"-style labels.
- Date-only arithmetic in UTC (DST-safe), "today" in `Europe/Rome`.
- Fixtures ported from the Go repo (`standard`, `comma_mb`, `period_fallback`, `login`, plus offer-label and renewal-inference cases) live in `RiepilogoIliadTests/Fixtures/`.

## 7. Storage & migration

GRDB with the exact Go schema:

```sql
CREATE TABLE readings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account TEXT NOT NULL,
  fetched_at TEXT NOT NULL,   -- RFC3339 UTC
  ok INTEGER NOT NULL,
  error TEXT,
  phone TEXT, offer TEXT,
  used_gb REAL, remaining_gb REAL, allowance_gb REAL, credit_eur REAL,
  renewal_date TEXT, period_start TEXT, period_end TEXT
);
CREATE INDEX idx_readings_account_fetched ON readings(account, fetched_at);
```

- DB lives at `~/Library/Application Support/RiepilogoIliad/iliad.db`.
- First-launch migration: Settings offers "Importa storico" (file picker → copy the Go app's `iliad.db`, plus its `-wal`/`-shm` sidecars when present) and "Importa account da config.yaml" (Yams → Keychain; `refresh_interval` is imported into settings, web-only keys are ignored). Both optional; the app works with a fresh DB.
- History view: last 30 days, one point per local day (latest successful reading of that day) — same as Go.

## 8. UI

### Menu bar
- `MenuBarExtra` label: total remaining GB (e.g. `603 GB`) over accounts with data, `—` when none; SF Symbol icon (e.g. `antenna.radiowaves.left.and.right`); warning state when any SIM is exhausted or below the low threshold.

### Popover
- Header: "Ti restano X GB su Y GB (Z%)", next renewal ("tra N giorni (SIM n)"), excluded-SIMs warning.
- One card per SIM sorted by days-to-renewal: name, phone, offer, used-fill progress bar (green <70% used, yellow 70–90%, red >90%), remaining/allowance, used with percentage, renewal date + days, credit, 7-day sparkline, stale/error badge (last-good values kept).
- Footer: last update, "Aggiorna ora", gear (Settings), "Storico" (window).

### History window
- SIM picker; Swift Charts line chart of remaining GB over 30 days; table of the last 14 daily readings.

### Settings
- Accounts: list, add/edit/remove (name, username, password in SecureField, optional renewal day). Passwords only in Keychain.
- Refresh interval (default 4h, min 1h), fetch mode (auto/direct/safari), low-data threshold (default 10%), launch at login toggle, notifications toggle.
- "Verifica account": runs one fetch per account and shows results (path used, values, errors) — the native equivalent of `make check`.
- "Importa account da config.yaml", "Importa storico da iliad.db".

### Notifications
- Low: remaining ≤ threshold (default 10% of allowance).
- Exhausted: remaining = 0.
- Renewed: remaining increased substantially since the previous reading (new cycle).
- Permission requested on first enable; no notifications while notifications are off.

### Launch at login
- `SMAppService.mainApp` register/unregister from the Settings toggle.

## 9. Security & permissions

- Credentials only in Keychain (`kSecClassGenericPassword`, service `riepilogo-iliad`, account = SIM name).
- No HTTP server, nothing listens on any port.
- Non-sandboxed personal app: macOS prompts once for Apple Events control of Safari (TCC); Safari's "Allow JavaScript from Apple Events" is required only for the fallback path.
- Credentials never logged; error messages sanitized; no analytics, no third-party services.
- Notifications permission via `UserNotifications`.

## 10. Project layout & build

```
riepilogo-iliad-mac/
  project.yml                  # XcodeGen
  Makefile                     # generate / build / test / run
  .gitignore                   # .xcodeproj, DerivedData, build artifacts
  RiepilogoIliad/
    App/        RiepilogoIliadApp.swift, MenuBarLabel.swift, PopoverView.swift,
                HistoryWindow.swift, SettingsView.swift, AccountsSettings.swift
    Core/       AppModel.swift, RefreshCoordinator.swift, HTTPFetcher.swift,
                SafariFetcher.swift, AutoFetcher.swift, Parser.swift, Store.swift,
                Models.swift, Keychain.swift, Notifications.swift, Settings.swift
    Resources/  Assets.xcassets
  RiepilogoIliadTests/
    Fixtures/   *.html
    ParserTests.swift, HTTPFetcherTests.swift, SafariFetcherTests.swift,
    AutoFetcherTests.swift, StoreTests.swift, CoordinatorTests.swift, KeychainTests.swift
  docs/superpowers/specs/2026-10-02-riepilogo-iliad-mac-design.md
```

- `make generate` → `xcodegen generate`; `make build` → `xcodebuild -scheme RiepilogoIliad build`; `make test` → `xcodebuild test`; `make run` → build + open the app.
- Dependencies pinned by XcodeGen `packages:` (GRDB.swift, SwiftSoup, Yams).
- Tests use XCTest.

## 11. Testing

- Parser: fixture-driven XCTest cases ported 1:1 from the Go suite (all fields, fallbacks, offer filtering, renewal inference).
- HTTPFetcher: fake portal via custom `URLProtocol` — cookie session behavior, WAF UA rejection (403 for the Go default UA), auth failure, redirect handling.
- AutoFetcher: direct success (Safari untouched), direct network failure → Safari used, direct auth failure → no fallback.
- SafariFetcher: script-runner protocol with a fake (success, login page → auth error, JS-setting error, escaping of credential values).
- Store: temp-file GRDB tests (insert/latest/last-good/history/retention).
- Coordinator: fake fetchers; single-flight; last-good kept on failure; persistence verified.
- Keychain: wrapper behind a protocol; real implementation smoke-tested manually (unit tests use an in-memory fake).
- Manual acceptance: run the app on the hotspot (Safari fallback) and on a normal network (direct), verify menu bar, popover, history, notifications, launch at login.

## 12. Rollout

1. Native app built and tested in parallel with the Go app (separate DB copy; both can fetch).
2. Import accounts and history via Settings.
3. After a few days of parity, stop using the Go app (`pkill riepilogo-iliad`); its repo remains as reference.
4. Optional future: proxy support (`direct → proxy → Safari`) if the user adopts a VPN; the Go app's `fetch_mode` semantics carry over.

## 13. Out of scope

- App Store distribution, notarization, sandboxing.
- iOS/iPadOS app.
- Proxy/VPN support (v1 is direct + Safari fallback).
- Localization beyond Italian.
- Roaming breakdown, per-call/SMS detail, billing history.

## 14. Open questions

None outstanding — design approved 2026-10-02.
