# Riepilogo Iliad macOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native SwiftUI menu bar app that shows remaining data and days-to-renewal for 5 Iliad Italia SIMs, with history charts, notifications, and an automatic Safari fallback when the network blocks direct access.

**Architecture:** MenuBarExtra app with a popover, a history window and a settings scene. An actor-based `RefreshCoordinator` runs single-flight cycles; per account an `AutoFetcher` tries `HTTPFetcher` (URLSession, isolated cookies) then `SafariFetcher` (osascript driving Safari) on network errors; HTML is parsed by a SwiftSoup port of the Go parser; every reading is persisted with GRDB using the same SQLite schema as the Go app.

**Tech Stack:** Swift 6 (Xcode 27), SwiftUI (`MenuBarExtra`, Swift Charts), GRDB.swift, SwiftSoup, Yams, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-02-riepilogo-iliad-mac-design.md`

**Reference implementation (read-only):** `/Users/ionutale/developer-playground/riepilogo-iliad` (Go). Fixtures and the AppleScript/JS live there.

## Global Constraints

- Project root: `/Users/ionutale/developer-playground/riepilogo-iliad-mac`; module/product name `RiepilogoIliad`; bundle id `it.ionut.riepilogo-iliad`.
- Deployment target macOS 15.0; Swift 6 language mode; ad-hoc code signing (`CODE_SIGN_IDENTITY: "-"`), no sandbox, no hardened runtime.
- `LSUIElement: true` (menu bar app, no Dock icon); `NSAppleEventsUsageDescription` present in Info.plist.
- UI language: Italian. Dates `dd/mm/yyyy`, decimals with comma; "today" in `Europe/Rome`; date-only math in UTC (DST-safe).
- Credentials only in Keychain (service `riepilogo-iliad`, account = `Account.id.uuidString`). Never in UserDefaults, logs, or error messages.
- SQLite schema identical to the Go app (`readings` table, `fetched_at` RFC3339 UTC, dates `yyyy-MM-dd`); DB at `~/Library/Application Support/RiepilogoIliad/iliad.db`; retention 180 days.
- Refresh interval default 4h, minimum 1h. Single-flight refreshes; sequential accounts.
- Fetch fallback: direct first, Safari only on network-class errors; never on auth or parse errors.
- Dependencies limited to GRDB.swift, SwiftSoup, Yams. Everything else is Foundation/SwiftUI.
- Build/test through `make` targets (XcodeGen + xcodebuild); `.xcodeproj` and `build/` are gitignored.

## Review Focus

Input classes and failure modes most likely to bite, each pinned to a task test:

1. **Parser fidelity on real page variants** (Italian/English numbers, MB/TB units, missing renewal date, generic offer labels) — Task 3 tests with ported fixtures.
2. **Fallback discipline**: Safari must be used only for network-class failures; an auth failure must never cycle the Safari session — Task 6 tests.
3. **Cookie isolation between accounts**: no session bleed across SIMs — Task 4 test with a fake portal.
4. **History migration**: reading the Go app's `iliad.db` without schema drift or corruption (RFC3339/`yyyy-MM-dd` strings, WAL sidecars) — Task 7 round-trip tests; Task 12 import copies sidecars.
5. **Empty/error states**: no accounts yet, first launch with an empty DB, or all accounts failing must render a sensible menu bar/popover instead of crashing — Task 10 tests.

---

### Task 1: Project scaffold, XcodeGen pipeline, minimal menu bar app

**Files:**
- Create: `project.yml`
- Create: `Makefile`
- Create: `.gitignore`
- Create: `RiepilogoIliad/App/RiepilogoIliadApp.swift`
- Create: `RiepilogoIliadTests/ScaffoldTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `make generate`, `make build`, `make test`, `make run`; scheme `RiepilogoIliad`; app target `RiepilogoIliad` + test target `RiepilogoIliadTests`.

- [ ] **Step 1: Write `project.yml`**

```yaml
name: RiepilogoIliad
options:
  bundleIdPrefix: it.ionut
  deploymentTarget:
    macOS: "15.0"
  createIntermediateGroups: true

packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: 7.0.0
  SwiftSoup:
    url: https://github.com/scinfu/SwiftSoup
    from: 2.7.0
  Yams:
    url: https://github.com/jpsim/Yams
    from: 5.1.0

settings:
  base:
    SWIFT_VERSION: "6.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: ""
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    ENABLE_HARDENED_RUNTIME: NO

targets:
  RiepilogoIliad:
    type: application
    platform: macOS
    sources: [RiepilogoIliad]
    dependencies:
      - package: GRDB
      - package: SwiftSoup
      - package: Yams
    info:
      path: RiepilogoIliad/Info.plist
      properties:
        CFBundleDisplayName: Riepilogo Iliad
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSUIElement: true
        LSMinimumSystemVersion: "15.0"
        NSAppleEventsUsageDescription: "Serve per leggere i consumi tramite Safari quando la rete blocca il portale Iliad."
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: it.ionut.riepilogo-iliad
        GENERATE_INFOPLIST_FILE: NO

  RiepilogoIliadTests:
    type: bundle.unit-test
    platform: macOS
    sources: [RiepilogoIliadTests]
    dependencies:
      - target: RiepilogoIliad
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: it.ionut.riepilogo-iliad.tests
        GENERATE_INFOPLIST_FILE: YES

schemes:
  RiepilogoIliad:
    build:
      targets:
        RiepilogoIliad: all
    test:
      targets:
        - RiepilogoIliadTests
```

- [ ] **Step 2: Write `Makefile` and `.gitignore`**

`Makefile` (tabs, not spaces):
```makefile
.PHONY: generate build test run clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project RiepilogoIliad.xcodeproj -scheme RiepilogoIliad \
		-configuration Debug -derivedDataPath build build

test: generate
	xcodebuild -project RiepilogoIliad.xcodeproj -scheme RiepilogoIliad \
		-configuration Debug -derivedDataPath build test

run: build
	open build/Build/Products/Debug/RiepilogoIliad.app

clean:
	rm -rf build RiepilogoIliad.xcodeproj
```

`.gitignore`:
```
RiepilogoIliad.xcodeproj/
build/
DerivedData/
.DS_Store
*.xcuserstate
```

- [ ] **Step 3: Minimal app + trivial test**

`RiepilogoIliad/App/RiepilogoIliadApp.swift`:
```swift
import SwiftUI

@main
struct RiepilogoIliadApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("Riepilogo Iliad")
                .padding()
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
    }
}
```

`RiepilogoIliadTests/ScaffoldTests.swift`:
```swift
import XCTest

final class ScaffoldTests: XCTestCase {
    func testScaffoldBuilds() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 4: Generate, build, test**

```bash
make generate
make build
make test
```
Expected: project generated; `BUILD SUCCEEDED`; tests pass (`** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**

```bash
git add project.yml Makefile .gitignore RiepilogoIliad/ RiepilogoIliadTests/
git commit -m "feat: XcodeGen scaffold with minimal menu bar app"
```

---

### Task 2: Models, settings, Keychain

**Files:**
- Create: `RiepilogoIliad/Core/Models.swift`
- Create: `RiepilogoIliad/Core/Settings.swift`
- Create: `RiepilogoIliad/Core/Keychain.swift`
- Create: `RiepilogoIliadTests/ModelsTests.swift`
- Create: `RiepilogoIliadTests/SettingsTests.swift`
- Create: `RiepilogoIliadTests/KeychainTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Account`, `FetchedAccount`, `AccountData`, `Entry`, `Snapshot`, `FetchMode`, `FetchPath`, `IliadError`; `AppSettings` (UserDefaults-backed); `CredentialStore` protocol + `KeychainCredentialStore`.

- [ ] **Step 1: Write `Models.swift`**

```swift
import Foundation
import GRDB

/// A configured SIM login (password lives in Keychain, not here).
struct Account: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var name: String
    var username: String
    var renewalDay: Int? = nil // 1...28
}

/// Account plus its Keychain password, ready to fetch.
struct FetchedAccount: Identifiable, Sendable {
    var id: UUID
    var name: String
    var username: String
    var password: String
    var renewalDay: Int?
}

/// One account's parsed consumi page.
struct AccountData: Equatable, Sendable {
    var creditEUR: Double?
    var usedGB: Double?
    var remainingGB: Double?
    var allowanceGB: Double?
    var renewalDate: Date?
    var periodStart: Date?
    var periodEnd: Date?
    var phoneNumber: String
    var offerName: String
}

enum FetchMode: String, CaseIterable, Codable, Sendable {
    case auto, direct, safari

    var label: String {
        switch self {
        case .auto: "Automatico (diretto → Safari)"
        case .direct: "Solo diretto (HTTP)"
        case .safari: "Solo Safari"
        }
    }
}

enum FetchPath: String, Codable, Sendable {
    case direct, safari
}

enum IliadError: Error, Equatable, Sendable {
    case auth(String)
    case parse(String)
    case network(String)
    case safariJSSetting(String)

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }

    var userMessage: String {
        switch self {
        case .auth(let m), .parse(let m), .network(let m), .safariJSSetting(let m): m
        }
    }
}

/// RFC3339 UTC timestamp stored as TEXT (Go schema compatibility).
struct Timestamp: DatabaseValueConvertible, Equatable, Sendable {
    var date: Date

    var databaseValue: DatabaseValue { Self.format(date).databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Timestamp? {
        guard let s = String.fromDatabaseValue(dbValue), let d = parse(s) else { return nil }
        return Timestamp(date: d)
    }

    static func format(_ date: Date) -> String { date.ISO8601Format() }

    static func parse(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}

/// Date-only value stored as `yyyy-MM-dd` TEXT (Go schema compatibility).
struct Day: DatabaseValueConvertible, Equatable, Sendable {
    var date: Date // midnight UTC

    var databaseValue: DatabaseValue { Self.format(date).databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Day? {
        guard let s = String.fromDatabaseValue(dbValue), let d = parse(s) else { return nil }
        return Day(date: d)
    }

    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func parse(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return dateOnly(y: parts[0], m: parts[1], d: parts[2])
    }
}

/// One fetch attempt, matching the Go `readings` table exactly.
struct Reading: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var account: String
    var fetchedAt: Timestamp
    var ok: Bool
    var error: String?
    var phone: String?
    var offer: String?
    var usedGB: Double?
    var remainingGB: Double?
    var allowanceGB: Double?
    var creditEUR: Double?
    var renewalDate: Day?
    var periodStart: Day?
    var periodEnd: Day?

    static let databaseTableName = "readings"
}

extension Reading {
    static func success(account: String, data: AccountData, fetchedAt: Date) -> Reading {
        Reading(
            id: nil, account: account, fetchedAt: Timestamp(date: fetchedAt), ok: true,
            error: nil, phone: data.phoneNumber.isEmpty ? nil : data.phoneNumber,
            offer: data.offerName.isEmpty ? nil : data.offerName,
            usedGB: data.usedGB, remainingGB: data.remainingGB, allowanceGB: data.allowanceGB,
            creditEUR: data.creditEUR,
            renewalDate: data.renewalDate.map(Day.init(date:)),
            periodStart: data.periodStart.map(Day.init(date:)),
            periodEnd: data.periodEnd.map(Day.init(date:)))
    }

    static func failure(account: String, error: String, fetchedAt: Date) -> Reading {
        Reading(
            id: nil, account: account, fetchedAt: Timestamp(date: fetchedAt), ok: false,
            error: error, phone: nil, offer: nil, usedGB: nil, remainingGB: nil,
            allowanceGB: nil, creditEUR: nil, renewalDate: nil, periodStart: nil, periodEnd: nil)
    }
}

/// Live state of one account (kept in memory by the coordinator).
struct Entry: Sendable {
    var account: String
    var lastGood: Reading? = nil
    var lastAttempt: Date? = nil
    var lastError: String? = nil
}

/// Consistent view published to the UI.
struct Snapshot: Sendable {
    var entries: [String: Entry] = [:]
    var refreshing = false
    var lastCycle: Date?
}
```

- [ ] **Step 2: Write `Settings.swift`**

```swift
import Foundation
import Observation

/// UserDefaults-backed app settings. Accounts are JSON; passwords are Keychain.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let accounts = "accounts"
        static let refreshInterval = "refreshInterval"
        static let fetchMode = "fetchMode"
        static let lowThresholdPercent = "lowThresholdPercent"
        static let notificationsEnabled = "notificationsEnabled"
    }

    private let defaults: UserDefaults

    var accounts: [Account] {
        didSet { persist(accounts, forKey: Keys.accounts) }
    }
    var refreshInterval: TimeInterval {
        didSet {
            if refreshInterval < 3600 { refreshInterval = 3600 }
            defaults.set(refreshInterval, forKey: Keys.refreshInterval)
        }
    }
    var fetchMode: FetchMode {
        didSet { defaults.set(fetchMode.rawValue, forKey: Keys.fetchMode) }
    }
    var lowThresholdPercent: Double {
        didSet { defaults.set(lowThresholdPercent, forKey: Keys.lowThresholdPercent) }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.accounts = Self.load([Account].self, from: defaults, key: Keys.accounts) ?? []
        let stored = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = stored >= 3600 ? stored : 4 * 3600
        self.fetchMode = FetchMode(rawValue: defaults.string(forKey: Keys.fetchMode) ?? "") ?? .auto
        let threshold = defaults.double(forKey: Keys.lowThresholdPercent)
        self.lowThresholdPercent = threshold > 0 ? threshold : 10
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
```

- [ ] **Step 3: Write `Keychain.swift`**

```swift
import Foundation
import Security

/// Password storage abstraction (fakeable in tests).
protocol CredentialStore: Sendable {
    func password(for accountID: UUID) throws -> String?
    func setPassword(_ password: String, for accountID: UUID) throws
    func deletePassword(for accountID: UUID) throws
}

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

struct KeychainCredentialStore: CredentialStore {
    let service = "riepilogo-iliad"

    private func query(accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }

    func password(for accountID: UUID) throws -> String? {
        var q = query(accountID: accountID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String, for accountID: UUID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            query(accountID: accountID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var q = query(accountID: accountID)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func deletePassword(for accountID: UUID) throws {
        let status = SecItemDelete(query(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// In-memory store for tests and previews.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func password(for accountID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountID]
    }

    func setPassword(_ password: String, for accountID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountID] = password
    }

    func deletePassword(for accountID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }
}
```

- [ ] **Step 4: Write tests**

`RiepilogoIliadTests/SettingsTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

@MainActor
final class SettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaults() {
        let settings = AppSettings(defaults: freshDefaults())
        XCTAssertEqual(settings.refreshInterval, 4 * 3600)
        XCTAssertEqual(settings.fetchMode, .auto)
        XCTAssertEqual(settings.lowThresholdPercent, 10)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertTrue(settings.accounts.isEmpty)
    }

    func testRoundTripAndIntervalFloor() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.accounts = [Account(name: "SIM 1", username: "u", renewalDay: 17)]
        settings.fetchMode = .safari
        settings.refreshInterval = 60 // clamped to 1h
        settings.lowThresholdPercent = 5

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.accounts.count, 1)
        XCTAssertEqual(reloaded.accounts[0].name, "SIM 1")
        XCTAssertEqual(reloaded.accounts[0].renewalDay, 17)
        XCTAssertEqual(reloaded.fetchMode, .safari)
        XCTAssertEqual(reloaded.refreshInterval, 3600)
        XCTAssertEqual(reloaded.lowThresholdPercent, 5)
    }
}
```

`RiepilogoIliadTests/KeychainTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class KeychainTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        XCTAssertNil(try store.password(for: id))
        try store.setPassword("segreta", for: id)
        XCTAssertEqual(try store.password(for: id), "segreta")
        try store.deletePassword(for: id)
        XCTAssertNil(try store.password(for: id))
    }
}
```

`RiepilogoIliadTests/ModelsTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class ModelsTests: XCTestCase {
    func testErrorClassification() {
        XCTAssertTrue(IliadError.network("x").isNetwork)
        XCTAssertFalse(IliadError.auth("x").isNetwork)
        XCTAssertFalse(IliadError.parse("x").isNetwork)
        XCTAssertFalse(IliadError.safariJSSetting("x").isNetwork)
    }

    func testFetchModeLabels() {
        XCTAssertEqual(FetchMode.allCases.count, 3)
        XCTAssertFalse(FetchMode.auto.label.isEmpty)
    }
}
```

- [ ] **Step 5: Build and test**

```bash
make test
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add RiepilogoIliad/Core/ RiepilogoIliadTests/
git commit -m "feat: models, settings, and Keychain credential store"
```

---

### Task 3: Parser port (SwiftSoup) with fixtures

**Files:**
- Create: `RiepilogoIliad/Core/DateUtils.swift`
- Create: `RiepilogoIliad/Core/Parser.swift`
- Create: `RiepilogoIliadTests/DateUtilsTests.swift`
- Create: `RiepilogoIliadTests/ParserTests.swift`
- Create: `RiepilogoIliadTests/Fixtures/standard.html`
- Create: `RiepilogoIliadTests/Fixtures/comma_mb.html`
- Create: `RiepilogoIliadTests/Fixtures/period_fallback.html`
- Create: `RiepilogoIliadTests/Fixtures/login.html`
- Create: `RiepilogoIliadTests/Fixtures/offerta.html`

**Interfaces:**
- Consumes: `AccountData`, `IliadError`.
- Produces: `dateOnly(y:m:d:) -> Date`, `today(in:) -> Date`, `daysBetween(_:_:) -> Int`; `parseAccountPage(html:now:renewalDay:) throws -> AccountData`.

- [ ] **Step 1: Copy fixtures from the Go repo**

```bash
mkdir -p RiepilogoIliadTests/Fixtures
cp ../riepilogo-iliad/internal/iliad/testdata/standard.html RiepilogoIliadTests/Fixtures/
cp ../riepilogo-iliad/internal/iliad/testdata/comma_mb.html RiepilogoIliadTests/Fixtures/
cp ../riepilogo-iliad/internal/iliad/testdata/period_fallback.html RiepilogoIliadTests/Fixtures/
cp ../riepilogo-iliad/internal/iliad/testdata/login.html RiepilogoIliadTests/Fixtures/
```

Update `project.yml`'s `RiepilogoIliadTests` target so the fixtures ship as test resources:

```yaml
  RiepilogoIliadTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: RiepilogoIliadTests
        excludes: ["Fixtures/**"]
      - path: RiepilogoIliadTests/Fixtures
        buildPhase: resources
    dependencies:
      - target: RiepilogoIliad
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: it.ionut.riepilogo-iliad.tests
        GENERATE_INFOPLIST_FILE: YES
```

Then regenerate: `make generate`.

Create `RiepilogoIliadTests/Fixtures/offerta.html`:
```html
<!doctype html>
<html lang="it"><body>
<p>offerta mobile</p>
<h1>Offerta GIGA 200</h1>
<div class="consumi"><span class="red">2 GB / 200 GB</span></div>
<p>Credito: 4,32 €</p>
</body></html>
```

- [ ] **Step 2: Write the failing tests**

`RiepilogoIliadTests/DateUtilsTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class DateUtilsTests: XCTestCase {
    func testDaysBetweenIgnoresDST() {
        let from = dateOnly(y: 2026, m: 10, d: 24)
        let to = dateOnly(y: 2026, m: 10, d: 27) // DST fall-back on the 25th
        XCTAssertEqual(daysBetween(from, to), 3)
        XCTAssertEqual(daysBetween(to, from), -3)
        XCTAssertEqual(daysBetween(from, from), 0)
    }

    func testTodayIsUTCMidnightOfRomeDate() {
        let today = today(in: TimeZone(identifier: "Europe/Rome")!)
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.hour, in: today), 0)
        XCTAssertEqual(today.timeZone, TimeZone(identifier: "UTC")!)
    }
}
```

`RiepilogoIliadTests/ParserTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class ParserTests: XCTestCase {
    private let now = dateOnly(y: 2026, m: 10, d: 2)

    private func fixture(_ name: String) throws -> String {
        let url = Bundle(for: ParserTests.self).url(forResource: name, withExtension: "html")!
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testStandardFixture() throws {
        let data = try parseAccountPage(html: fixture("standard"), now: now, renewalDay: nil)
        XCTAssertEqual(data.usedGB, 42.10)
        XCTAssertEqual(data.allowanceGB, 100)
        XCTAssertEqual(data.remainingGB, 57.9)
        XCTAssertEqual(data.creditEUR, 12.34)
        XCTAssertEqual(data.renewalDate, dateOnly(y: 2026, m: 10, d: 17))
        XCTAssertEqual(data.periodStart, dateOnly(y: 2026, m: 9, d: 17))
        XCTAssertEqual(data.periodEnd, dateOnly(y: 2026, m: 10, d: 16))
        XCTAssertEqual(data.phoneNumber, "3511234567")
        XCTAssertEqual(data.offerName, "iliad voLTE 100GB")
    }

    func testCommaAndMBUnits() throws {
        let data = try parseAccountPage(html: fixture("comma_mb"), now: now, renewalDay: nil)
        XCTAssertEqual(data.usedGB, 0.95)
        XCTAssertEqual(data.allowanceGB, 2)
        XCTAssertEqual(data.remainingGB, 1.05)
        XCTAssertEqual(data.renewalDate, dateOnly(y: 2026, m: 11, d: 3))
    }

    func testPeriodFallbackAndGenericOfferFiltered() throws {
        let data = try parseAccountPage(html: fixture("period_fallback"), now: now, renewalDay: nil)
        XCTAssertEqual(data.remainingGB, 17.5)
        XCTAssertEqual(data.renewalDate, dateOnly(y: 2026, m: 10, d: 30))
        XCTAssertEqual(data.offerName, "")
    }

    func testLoginPageIsParseError() throws {
        XCTAssertThrowsError(try parseAccountPage(html: fixture("login"), now: now, renewalDay: nil)) { error in
            guard case IliadError.parse = error else { return XCTFail("got \(error)") }
        }
    }

    func testOfferScanningSkipsGenericLabels() throws {
        let data = try parseAccountPage(html: fixture("offerta"), now: now, renewalDay: nil)
        XCTAssertEqual(data.offerName, "GIGA 200")
    }

    func testRenewalInference() throws {
        let base = #"<html><body><span class="red">1 GB / 10 GB</span>"#
        let textual = try parseAccountPage(html: base + "<p>Si rinnova il 17 ottobre.</p></body></html>", now: now, renewalDay: nil)
        XCTAssertEqual(textual.renewalDate, dateOnly(y: 2026, m: 10, d: 17))

        let past = try parseAccountPage(html: base + "<p>Si rinnova il 1 settembre.</p></body></html>", now: now, renewalDay: nil)
        XCTAssertEqual(past.renewalDate, dateOnly(y: 2027, m: 9, d: 1))

        let override = try parseAccountPage(html: base + "</body></html>", now: now, renewalDay: 17)
        XCTAssertEqual(override.renewalDate, dateOnly(y: 2026, m: 10, d: 17))

        let nextMonth = try parseAccountPage(html: base + "</body></html>", now: now, renewalDay: 1)
        XCTAssertEqual(nextMonth.renewalDate, dateOnly(y: 2026, m: 11, d: 1))
    }

    func testNumberSeparators() {
        XCTAssertEqual(parseNumber("42,10"), 42.10)
        XCTAssertEqual(parseNumber("1.234,56"), 1234.56)
        XCTAssertEqual(parseNumber("1,234.56"), 1234.56)
        XCTAssertEqual(parseNumber("100"), 100)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'dateOnly'`, `cannot find 'parseAccountPage'`).

- [ ] **Step 4: Implement `DateUtils.swift`**

```swift
import Foundation

/// Midnight UTC of the given calendar date.
func dateOnly(y: Int, m: Int, d: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d))!
}

/// Midnight UTC of "today" in the given time zone.
func today(in timeZone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day], from: Date())
    return dateOnly(y: c.year!, m: c.month!, d: c.day!)
}

/// Whole days from one date-only value to another (negative when past).
func daysBetween(_ from: Date, _ to: Date) -> Int {
    Int((to.timeIntervalSince(from) / 86400).rounded())
}
```

- [ ] **Step 5: Implement `Parser.swift`**

```swift
import Foundation
import SwiftSoup

// MARK: - Numbers

/// Accepts Italian ("42,10", "1.234,56") and English ("1,234.56") forms;
/// the rightmost separator wins.
func parseNumber(_ s: String) -> Double? {
    var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    guard !t.isEmpty else { return nil }
    let lastComma = t.lastIndex(of: ",")
    let lastDot = t.lastIndex(of: ".")
    if let c = lastComma, let d = lastDot {
        if c > d { // Italian: 1.234,56
            t = t.replacingOccurrences(of: ".", with: "")
            t = t.replacingOccurrences(of: ",", with: ".")
        } else { // English: 1,234.56
            t = t.replacingOccurrences(of: ",", with: "")
        }
    } else if lastComma != nil {
        t = t.replacingOccurrences(of: ",", with: ".")
    }
    return Double(t)
}

func sizeToGB(_ value: Double, unit: String) -> Double {
    switch unit.uppercased() {
    case "B": value / 1e9
    case "KB": value / 1e6
    case "MB": value / 1e3
    case "TB": value * 1e3
    default: value
    }
}

// MARK: - Regex helpers

private let sizePairRegex = try! NSRegularExpression(
    pattern: #"(?i)(\d+[\d.,]*)\s*(B|KB|MB|GB|TB)\s*/\s*(\d+[\d.,]*)\s*(B|KB|MB|GB|TB)"#)
private let numberRegex = try! NSRegularExpression(pattern: #"([\d.,]+)"#)
private let unitRegex = try! NSRegularExpression(pattern: #"(?i)\b(B|KB|MB|GB|TB)\b"#)
private let creditRegex = try! NSRegularExpression(pattern: #"([\d.,]+)\s*€"#)
private let renewalNumRegex = try! NSRegularExpression(
    pattern: #"(?i)(?:si\s+)?rinnov\w*\s+(?:il\s+)?(\d{1,2})[/.\-](\d{1,2})(?:[/.\-](\d{2,4}))?\b"#)
private let renewalTextRegex = try! NSRegularExpression(
    pattern: #"(?i)(?:si\s+)?rinnov\w*\s+(?:il\s+)?(\d{1,2})\s+(gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre)(?:\s+(\d{4}))?"#)
private let textualDateRegex = try! NSRegularExpression(
    pattern: #"(?i)\b(\d{1,2})\s+(gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre)(?:\s+(\d{4}))?\b"#)
private let periodMarkerRegex = try! NSRegularExpression(
    pattern: #"(?i)periodo\s+di\s+riferimento\s+dal\s+"#)
private let phoneRegex = try! NSRegularExpression(
    pattern: #"(?i)\bLinea\s*:\s*(\+?[0-9][0-9 .\-]{4,24})"#)

private let monthNames: [String: Int] = [
    "gennaio": 1, "febbraio": 2, "marzo": 3, "aprile": 4, "maggio": 5, "giugno": 6,
    "luglio": 7, "agosto": 8, "settembre": 9, "ottobre": 10, "novembre": 11, "dicembre": 12,
]

private func nsRange(_ text: String) -> NSRange {
    NSRange(text.startIndex..., in: text)
}

private func firstMatch(_ regex: NSRegularExpression, in text: String) -> [String]? {
    guard let m = regex.firstMatch(in: text, range: nsRange(text)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return "" }
        return String(text[swiftRange])
    }
}

// MARK: - Dates

private func fixedDate(day: Int, month: Int, year: Int) -> Date? {
    guard (1...31).contains(day), (1...12).contains(month) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let d = dateOnly(y: year, m: month, d: day)
    let c = calendar.dateComponents([.year, .month, .day], from: d)
    guard c.year == year, c.month == month, c.day == day else { return nil }
    return d
}

private func nextDate(day: Int, month: Int, now: Date) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let year = calendar.component(.year, from: now)
    guard let d = fixedDate(day: day, month: month, year: year) else { return nil }
    if d < now { return fixedDate(day: day, month: month, year: year + 1) }
    return d
}

private func nextDayOfMonth(_ day: Int, now: Date) -> Date? {
    guard (1...28).contains(day) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let c = calendar.dateComponents([.year, .month], from: now)
    let thisMonth = dateOnly(y: c.year!, m: c.month!, d: day)
    if thisMonth < now {
        let next = calendar.date(byAdding: .month, value: 1, to: thisMonth)!
        return next
    }
    return thisMonth
}

private func dateFromTextualMatch(_ m: [String], now: Date) -> Date? {
    guard let day = Int(m[1]), let month = monthNames[m[2].lowercased()] else { return nil }
    if !m[3].isEmpty, let year = Int(m[3]) {
        return fixedDate(day: day, month: month, year: year)
    }
    return nextDate(day: day, month: month, now: now)
}

private func parseRenewalDate(text: String, now: Date, periodEnd: Date?, renewalDay: Int?) -> Date? {
    if let m = firstMatch(renewalNumRegex, in: text) {
        let day = Int(m[1]) ?? 0
        let month = Int(m[2]) ?? 0
        if !m[3].isEmpty, var year = Int(m[3]) {
            if year < 100 { year += 2000 }
            if let d = fixedDate(day: day, month: month, year: year) { return d }
        } else if let d = nextDate(day: day, month: month, now: now) {
            return d
        }
    }
    if let m = firstMatch(renewalTextRegex, in: text), let d = dateFromTextualMatch(m, now: now) {
        return d
    }
    if let end = periodEnd {
        return Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: end)
    }
    if let day = renewalDay {
        return nextDayOfMonth(day, now: now)
    }
    return nil
}

private func parsePeriod(text: String, now: Date) -> (start: Date?, end: Date?) {
    guard let marker = periodMarkerRegex.firstMatch(in: text, range: nsRange(text)) else {
        return (nil, nil)
    }
    let rest = String(text[Range(marker.range, in: text)!.upperBound...])
    let window = String(rest.prefix(200))
    let matches = textualDateRegex.matches(in: window, range: nsRange(window))
    guard matches.count >= 2 else { return (nil, nil) }

    func groups(_ m: NSTextCheckingResult) -> [String] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: window) else { return "" }
            return String(window[swiftRange])
        }
    }
    guard var start = dateFromTextualMatch(groups(matches[0]), now: now),
          let end = dateFromTextualMatch(groups(matches[1]), now: now) else { return (nil, nil) }
    if start > end {
        start = Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: start)!
    }
    return (start, end)
}

// MARK: - Phone & offer

private func parsePhone(text: String) -> String {
    guard let m = firstMatch(phoneRegex, in: text) else { return "" }
    let raw = m[1].trimmingCharacters(in: .whitespaces)
    let hasPlus = raw.hasPrefix("+")
    let digits = raw.filter(\.isNumber)
    guard digits.count >= 6 else { return "" }
    return hasPlus ? "+\(digits)" : digits
}

private func parseOfferName(text: String) -> String {
    let genericPrefixes = ["mobile", "la tua", "dettaglio", "l'offerta", "consumi", "credito"]
    let lower = text.lowercased()
    var searchStart = lower.startIndex
    while let range = lower.range(of: "offerta", range: searchStart..<lower.endIndex) {
        searchStart = range.upperBound
        var candidate = String(text[range.upperBound...].prefix(120))
        if let next = candidate.lowercased().range(of: "offerta") {
            candidate = String(candidate[..<next.lowerBound])
        }
        var cut = candidate.endIndex
        if let pair = sizePairRegex.firstMatch(in: candidate, range: nsRange(candidate)),
           let r = Range(pair.range, in: candidate) {
            cut = min(cut, r.lowerBound)
        }
        for sep in ["●", "•", "·", "|"] {
            if let r = candidate.range(of: sep) { cut = min(cut, r.lowerBound) }
        }
        let candidateLower = candidate.lowercased()
        for stop in ["credito", "si rinnova", "periodo di riferimento"] {
            if let r = candidateLower.range(of: stop) { cut = min(cut, r.lowerBound) }
        }
        var value = String(candidate[..<cut]).trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—●•·|/"))
        let valueLower = value.lowercased()
        guard value.count >= 3, value.count <= 60 else { continue }
        guard !genericPrefixes.contains(where: { valueLower.hasPrefix($0) }) else { continue }
        return value
    }
    return ""
}

// MARK: - Entry point

/// Parses an Iliad consumi-e-credito page.
/// `now` must be a date-only value (`today(in:)` / `dateOnly`).
func parseAccountPage(html: String, now: Date, renewalDay: Int?) throws -> AccountData {
    guard let doc = try? SwiftSoup.parse(html) else {
        throw IliadError.parse("pagina del portale non riconosciuta")
    }
    let text = (try? doc.text()) ?? ""
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

    var data = AccountData(
        creditEUR: nil, usedGB: nil, remainingGB: nil, allowanceGB: nil,
        renewalDate: nil, periodStart: nil, periodEnd: nil,
        phoneNumber: "", offerName: ""
    )

    if let node = try? doc.select("b.red[data-cs-mask]").first(), let nodeText = try? node.text(),
       let m = firstMatch(creditRegex, in: nodeText), let v = parseNumber(m[1]) {
        data.creditEUR = v
    }

    if let m = firstMatch(sizePairRegex, in: normalized),
       let used = parseNumber(m[1]), let allowance = parseNumber(m[3]) {
        data.usedGB = sizeToGB(used, unit: m[2])
        data.allowanceGB = sizeToGB(allowance, unit: m[4])
    }

    if let node = try? doc.select("span.big.red").first(), let nodeText = try? node.text(),
       let m = firstMatch(numberRegex, in: nodeText), let v = parseNumber(m[1]) {
        var unit = "GB"
        if let sibling = try? node.nextElementSibling(), let siblingText = try? sibling.text(),
           let um = firstMatch(unitRegex, in: siblingText.uppercased()) {
            unit = um[1]
        }
        data.remainingGB = sizeToGB(v, unit: unit)
    }

    if data.remainingGB == nil, let used = data.usedGB, let allowance = data.allowanceGB {
        data.remainingGB = max(0, allowance - used)
    }
    if data.allowanceGB == nil, let used = data.usedGB, let remaining = data.remainingGB {
        data.allowanceGB = used + remaining
    }

    let period = parsePeriod(text: normalized, now: now)
    data.periodStart = period.start
    data.periodEnd = period.end
    data.renewalDate = parseRenewalDate(text: normalized, now: now, periodEnd: period.end, renewalDay: renewalDay)
    data.phoneNumber = parsePhone(text: normalized)
    data.offerName = parseOfferName(text: normalized)

    guard data.creditEUR != nil || data.usedGB != nil || data.remainingGB != nil else {
        throw IliadError.parse("nessun dato consumi trovato nella pagina")
    }
    return data
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test`
Expected: all parser/date tests pass.

- [ ] **Step 7: Commit**

```bash
git add RiepilogoIliad/Core/ RiepilogoIliadTests/
git commit -m "feat: SwiftSoup parser port with Go fixtures"
```

---

### Task 4: HTTPFetcher with isolated cookies

**Files:**
- Create: `RiepilogoIliad/Core/Fetchers.swift`
- Create: `RiepilogoIliadTests/TestSupport.swift`
- Create: `RiepilogoIliadTests/HTTPFetcherTests.swift`

**Interfaces:**
- Consumes: `FetchedAccount`, `IliadError`.
- Produces: `protocol HTMLFetcher: Sendable { func fetchHTML(for account: FetchedAccount) async throws -> String }`; `HTTPFetcher(baseURL:timeout:configuration:)`.

- [ ] **Step 1: Write the failing tests**

Create `RiepilogoIliadTests/TestSupport.swift`:
```swift
import Foundation

/// Thread-safe holder for observations made inside @Sendable closures
/// (Swift 6 forbids capturing mutable local state in them).
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
```

`RiepilogoIliadTests/HTTPFetcherTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

/// Fake portal served through URLProtocol; mimics the real WAF and cookies.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPFetcherTests: XCTestCase {
    private func makeFetcher() -> HTTPFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return HTTPFetcher(baseURL: URL(string: "https://example.test")!, timeout: 5, configuration: config)
    }

    private func account(name: String = "SIM 1") -> FetchedAccount {
        FetchedAccount(id: UUID(), name: name, username: "user", password: "pass", renewalDay: nil)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSuccessFollowsCookieSession() async throws {
        MockURLProtocol.handler = { request in
            let page = #"<html><body><span class="red">1 GB / 10 GB</span></body></html>"#
            if request.url!.path == "/account/login" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), browserUserAgent)
                XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") ?? false)
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "https://example.test/account/consumi-e-credito",
                                                       "Set-Cookie": "session=abc; Path=/"])!, Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(page.utf8))
        }
        let html = try await makeFetcher().fetchHTML(for: account())
        XCTAssertTrue(html.contains("1 GB / 10 GB"))
    }

    func testLoginPageMeansAuthError() async {
        MockURLProtocol.handler = { request in
            let page = #"<form><input name="login-ident"></form>"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(page.utf8))
        }
        do {
            _ = try await makeFetcher().fetchHTML(for: account())
            XCTFail("expected auth error")
        } catch let error as IliadError {
            guard case .auth = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testHTTPErrorIsNetworkError() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeFetcher().fetchHTML(for: account())
            XCTFail("expected network error")
        } catch let error as IliadError {
            guard case .network = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testSessionsAreIsolatedPerAccount() async throws {
        let seenCookies = Box<[String: String]>([:])
        MockURLProtocol.handler = { request in
            let host = request.url!.host!
            if request.url!.path == "/account/login" {
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": "https://\(host)/account/consumi-e-credito",
                                                       "Set-Cookie": "session=\(host); Path=/"])!, Data())
            }
            seenCookies.value[host] = request.value(forHTTPHeaderField: "Cookie")
            let page = #"<html><body><span class="red">1 GB / 10 GB</span></body></html>"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(page.utf8))
        }
        let alice = HTTPFetcher(baseURL: URL(string: "https://alice.test")!, timeout: 5, configuration: mockConfig())
        let bob = HTTPFetcher(baseURL: URL(string: "https://bob.test")!, timeout: 5, configuration: mockConfig())
        _ = try await alice.fetchHTML(for: account())
        _ = try await bob.fetchHTML(for: account())
        XCTAssertEqual(seenCookies.value["alice.test"], "session=alice.test")
        XCTAssertEqual(seenCookies.value["bob.test"], "session=bob.test")
    }
}
```

Note: `Box<T>` is a small thread-safe holder defined in `RiepilogoIliadTests/TestSupport.swift` (created in this step); it lets `@Sendable` test closures record observations without Swift 6 concurrency errors. Add the `mockConfig()` helper used above:

```swift
private func mockConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return config
}
```
and use it in `makeFetcher` too.

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'HTTPFetcher'`).

- [ ] **Step 3: Implement `Fetchers.swift`**

```swift
import Foundation

/// Browser User-Agent required by Iliad's WAF (Go's default UA gets 403).
let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

protocol HTMLFetcher: Sendable {
    func fetchHTML(for account: FetchedAccount) async throws -> String
}

/// Direct HTTP fetch: login POST + consumi GET with an ephemeral,
/// per-fetch session (cookies never leak between accounts).
struct HTTPFetcher: HTMLFetcher {
    let baseURL: URL
    let timeout: TimeInterval
    let configuration: URLSessionConfiguration

    init(baseURL: URL = URL(string: "https://www.iliad.it")!,
         timeout: TimeInterval = 20,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.configuration = configuration
    }

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "login-ident", value: account.username),
            URLQueryItem(name: "login-pwd", value: account.password),
        ]
        var login = URLRequest(url: baseURL.appendingPathComponent("/account/login"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        login.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        do {
            let (_, response) = try await session.data(for: login)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                throw IliadError.network("login HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
        } catch let error as IliadError {
            throw error
        } catch {
            throw IliadError.network("login: \(error.localizedDescription)")
        }

        var consumi = URLRequest(url: baseURL.appendingPathComponent("/account/consumi-e-credito"))
        consumi.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: consumi)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                throw IliadError.network("consumi HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let page = String(decoding: data, as: UTF8.self)
            if http.url?.path == "/account/login" || page.contains("name=\"login-ident\"") {
                throw IliadError.auth("credenziali non valide o sessione non autenticata")
            }
            return page
        } catch let error as IliadError {
            throw error
        } catch {
            throw IliadError.network("consumi: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all HTTP fetcher tests pass.

- [ ] **Step 5: Commit**

```bash
git add RiepilogoIliad/Core/Fetchers.swift RiepilogoIliadTests/HTTPFetcherTests.swift
git commit -m "feat: direct HTTP fetcher with isolated sessions"
```

---

### Task 5: SafariFetcher (osascript bridge)

**Files:**
- Create: `RiepilogoIliad/Core/SafariFetcher.swift`
- Create: `RiepilogoIliadTests/SafariFetcherTests.swift`

**Interfaces:**
- Consumes: `HTMLFetcher`, `FetchedAccount`, `IliadError`.
- Produces: `typealias ScriptRunner = @Sendable (_ script: String, _ args: [String]) async throws -> String`; `SafariFetcher(runner:)`; `SafariFetcher.defaultRunner`.

- [ ] **Step 1: Write the failing tests**

`RiepilogoIliadTests/SafariFetcherTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class SafariFetcherTests: XCTestCase {
    private func account() -> FetchedAccount {
        FetchedAccount(id: UUID(), name: "SIM 1", username: "user@example.com", password: "secret", renewalDay: nil)
    }

    func testSuccessParsesPage() async throws {
        let capturedScript = Box("")
        let capturedArgs = Box<[String]>([])
        let runner: ScriptRunner = { script, args in
            capturedScript.value = script
            capturedArgs.value = args
            return #"<html><body><span class="red">1 GB / 10 GB</span><span class="big red">9</span><span class="small red">GB</span></body></html>"#
        }
        let fetcher = SafariFetcher(runner: runner)
        let html = try await fetcher.fetchHTML(for: account())
        XCTAssertTrue(html.contains("9"))
        XCTAssertTrue(capturedScript.value.contains("tell application \"Safari\""))
        XCTAssertEqual(capturedArgs.value.count, 1)
        let js = capturedArgs.value[0]
        XCTAssertTrue(js.contains("/account/?logout=user"))
        XCTAssertTrue(js.contains("/account/login"))
        XCTAssertTrue(js.contains("/account/consumi-e-credito"))
        XCTAssertTrue(js.contains("\"user@example.com\"")) // JSON literal
    }

    func testCredentialsAreJSONEscaped() async throws {
        let capturedArgs = Box<[String]>([])
        let runner: ScriptRunner = { _, args in
            capturedArgs.value = args
            return #"<html><body><span class="red">1 GB / 10 GB</span></body></html>"#
        }
        let fetcher = SafariFetcher(runner: runner)
        _ = try await fetcher.fetchHTML(for: FetchedAccount(
            id: UUID(), name: "X", username: "u\"ser", password: "p'wd\\", renewalDay: nil))
        let js = capturedArgs.value[0]
        XCTAssertTrue(js.contains(#""u\"ser""#))
        XCTAssertTrue(js.contains(#""p'wd\\""#))
    }

    func testLoginPageMeansAuthError() async {
        let runner: ScriptRunner = { _, _ in
            #"<form><input name="login-ident"></form>"#
        }
        do {
            _ = try await SafariFetcher(runner: runner).fetchHTML(for: account())
            XCTFail("expected auth error")
        } catch let error as IliadError {
            guard case .auth = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testJSSettingErrorIsActionable() async {
        let runner: ScriptRunner = { _, _ in
            throw IliadError.network("You must enable 'Allow JavaScript from Apple Events' in the Developer section of Safari Settings")
        }
        do {
            _ = try await SafariFetcher(runner: runner).fetchHTML(for: account())
            XCTFail("expected safariJSSetting error")
        } catch let error as IliadError {
            guard case .safariJSSetting = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testRunnerFailureIsNetworkError() async {
        let runner: ScriptRunner = { _, _ in throw IliadError.network("boom") }
        do {
            _ = try await SafariFetcher(runner: runner).fetchHTML(for: account())
            XCTFail("expected network error")
        } catch let error as IliadError {
            guard case .network = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'SafariFetcher'`).

- [ ] **Step 3: Implement `SafariFetcher.swift`**

```swift
import Foundation

/// Runs an AppleScript and returns its stdout.
typealias ScriptRunner = @Sendable (_ script: String, _ args: [String]) async throws -> String

/// Fetches the consumi page through Safari (same-origin XHR), for networks
/// that block direct access. Requires Safari's "Allow JavaScript from Apple
/// Events" setting.
struct SafariFetcher: HTMLFetcher {
    let runner: ScriptRunner

    init(runner: @escaping ScriptRunner = SafariFetcher.defaultRunner) {
        self.runner = runner
    }

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        let js = Self.javaScript(username: account.username, password: account.password)
        let out: String
        do {
            out = try await runner(Self.appleScript, [js])
        } catch let error as IliadError {
            if case .network(let message) = error,
               message.contains("Allow JavaScript from Apple Events") ||
               message.contains("JavaScript dagli eventi Apple") {
                throw IliadError.safariJSSetting(
                    "abilita in Safari: Impostazioni > Avanzate > \"Mostra funzioni per sviluppatori web\", poi menu Sviluppo > \"Consenti JavaScript dagli eventi Apple\"")
            }
            throw error
        } catch {
            throw IliadError.network("safari: \(error.localizedDescription)")
        }
        if out.contains("name=\"login-ident\"") {
            throw IliadError.auth("login Safari non riuscito per questo account")
        }
        return out
    }

    // MARK: - Scripts

    static let appleScript = #"""
    on run argv
        set js to item 1 of argv
        tell application "Safari"
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (URL of t) starts with "https://www.iliad.it" then
                            set targetTab to t
                            exit repeat
                        end if
                    end try
                end repeat
                if targetTab is not missing value then exit repeat
            end repeat
            if targetTab is missing value then
                set newWin to make new document with properties {URL:"https://www.iliad.it/account/login"}
                delay 4
                set targetTab to current tab of newWin
            end if
            return do JavaScript js in targetTab
        end tell
    end run
    """#

    static func javaScript(username: String, password: String) -> String {
        func literal(_ value: String) -> String {
            let data = try! JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8)!
        }
        return """
        (function () {
          function xhr(method, url, body) {
            var x = new XMLHttpRequest();
            x.open(method, url, false);
            if (body) { x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded'); }
            x.send(body || null);
            return x;
          }
          xhr('GET', '/account/?logout=user');
          xhr('POST', '/account/login', 'login-ident=' + encodeURIComponent(\(literal(username))) + '&login-pwd=' + encodeURIComponent(\(literal(password))));
          return xhr('GET', '/account/consumi-e-credito').responseText;
        })()
        """
    }

    /// Runs osascript with the script and the JS as an argument.
    static let defaultRunner: ScriptRunner = { script, args in
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script, "--"] + args
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: IliadError.network("osascript: \(error.localizedDescription)"))
                    return
                }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let message = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
                    continuation.resume(throwing: IliadError.network(message))
                    return
                }
                continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all Safari fetcher tests pass.

- [ ] **Step 5: Commit**

```bash
git add RiepilogoIliad/Core/SafariFetcher.swift RiepilogoIliadTests/SafariFetcherTests.swift
git commit -m "feat: Safari osascript bridge fetcher"
```

---

### Task 6: AutoFetcher (fallback discipline)

**Files:**
- Create: `RiepilogoIliad/Core/AutoFetcher.swift`
- Create: `RiepilogoIliadTests/AutoFetcherTests.swift`

**Interfaces:**
- Consumes: `HTMLFetcher`, `FetchMode`, `FetchPath`, `IliadError`.
- Produces: `struct FetchOutcome { let html: String; let path: FetchPath }`; `AutoFetcher(direct:safari:mode:)` with `fetchHTML(for:) async throws -> FetchOutcome`.

- [ ] **Step 1: Write the failing tests**

`RiepilogoIliadTests/AutoFetcherTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

struct StubFetcher: HTMLFetcher {
    let result: @Sendable () throws -> String
    func fetchHTML(for account: FetchedAccount) async throws -> String { try result() }
}

final class AutoFetcherTests: XCTestCase {
    private func account() -> FetchedAccount {
        FetchedAccount(id: UUID(), name: "SIM 1", username: "u", password: "p", renewalDay: nil)
    }

    func testDirectSuccessDoesNotTouchSafari() async throws {
        let safariUsed = Box(false)
        let direct = StubFetcher { "<html>ok</html>" }
        let safari = StubFetcher {
            safariUsed.value = true
            return "<html>safari</html>"
        }
        let auto = AutoFetcher(direct: direct, safari: safari, mode: .auto)
        let outcome = try await auto.fetchHTML(for: account())
        XCTAssertEqual(outcome.path, .direct)
        XCTAssertFalse(safariUsed.value)
    }

    func testNetworkErrorFallsBackToSafari() async throws {
        let direct = StubFetcher { throw IliadError.network("redirect loop") }
        let safari = StubFetcher { "<html>safari</html>" }
        let auto = AutoFetcher(direct: direct, safari: safari, mode: .auto)
        let outcome = try await auto.fetchHTML(for: account())
        XCTAssertEqual(outcome.path, .safari)
        XCTAssertEqual(outcome.html, "<html>safari</html>")
    }

    func testAuthErrorDoesNotFallBack() async {
        let safariUsed = Box(false)
        let direct = StubFetcher { throw IliadError.auth("bad credentials") }
        let safari = StubFetcher {
            safariUsed.value = true
            return "<html>safari</html>"
        }
        let auto = AutoFetcher(direct: direct, safari: safari, mode: .auto)
        do {
            _ = try await auto.fetchHTML(for: account())
            XCTFail("expected auth error")
        } catch let error as IliadError {
            guard case .auth = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
        XCTAssertFalse(safariUsed.value)
    }

    func testForcedModes() async throws {
        let direct = StubFetcher { "<html>direct</html>" }
        let safari = StubFetcher { "<html>safari</html>" }
        let safariOnly = AutoFetcher(direct: direct, safari: safari, mode: .safari)
        XCTAssertEqual(try await safariOnly.fetchHTML(for: account()).path, .safari)

        let directOnly = AutoFetcher(direct: direct, safari: safari, mode: .direct)
        XCTAssertEqual(try await directOnly.fetchHTML(for: account()).path, .direct)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'AutoFetcher'`).

- [ ] **Step 3: Implement `AutoFetcher.swift`**

```swift
import Foundation

struct FetchOutcome: Sendable {
    let html: String
    let path: FetchPath
}

/// Chooses the transport: direct first, Safari only when the network blocks
/// direct access. Auth and parse errors never fall back (they would fail the
/// same way and needlessly cycle the Safari session).
struct AutoFetcher: Sendable {
    let direct: any HTMLFetcher
    let safari: any HTMLFetcher
    let mode: FetchMode

    func fetchHTML(for account: FetchedAccount) async throws -> FetchOutcome {
        switch mode {
        case .direct:
            return FetchOutcome(html: try await direct.fetchHTML(for: account), path: .direct)
        case .safari:
            return FetchOutcome(html: try await safari.fetchHTML(for: account), path: .safari)
        case .auto:
            do {
                return FetchOutcome(html: try await direct.fetchHTML(for: account), path: .direct)
            } catch let error as IliadError where error.isNetwork {
                return FetchOutcome(html: try await safari.fetchHTML(for: account), path: .safari)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all AutoFetcher tests pass.

- [ ] **Step 5: Commit**

```bash
git add RiepilogoIliad/Core/AutoFetcher.swift RiepilogoIliadTests/AutoFetcherTests.swift
git commit -m "feat: auto fetcher with Safari fallback discipline"
```

---

### Task 7: GRDB store with Go-schema compatibility

**Files:**
- Create: `RiepilogoIliad/Core/Store.swift`
- Create: `RiepilogoIliadTests/StoreTests.swift`

**Interfaces:**
- Consumes: `Reading`, `Timestamp`, `Day`.
- Produces: `Store(path:)`, `Store.defaultURL()`, `insert(_:)`, `latestPerAccount()`, `lastGoodPerAccount()`, `history(account:since:)`, `deleteOlderThan(_:)`.

- [ ] **Step 1: Write the failing tests**

`RiepilogoIliadTests/StoreTests.swift`:
```swift
import GRDB
import XCTest
@testable import RiepilogoIliad

final class StoreTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString).db").path
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 8) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testInsertLatestAndLastGood() throws {
        let store = try Store(path: tempPath())
        let data = AccountData(creditEUR: 4.32, usedGB: 1, remainingGB: 9, allowanceGB: 10,
                               renewalDate: dateOnly(y: 2026, m: 10, d: 17), periodStart: nil, periodEnd: nil,
                               phoneNumber: "3511112222", offerName: "GIGA 200")
        try store.insert(Reading.success(account: "SIM 1", data: data, fetchedAt: date(2026, 10, 1)))
        try store.insert(Reading.failure(account: "SIM 1", error: "rete giù", fetchedAt: date(2026, 10, 1, hour: 9)))

        let latest = try store.latestPerAccount()
        XCTAssertEqual(latest["SIM 1"]?.ok, false)
        XCTAssertEqual(latest["SIM 1"]?.error, "rete giù")

        let good = try store.lastGoodPerAccount()
        XCTAssertEqual(good["SIM 1"]?.phone, "3511112222")
        XCTAssertEqual(good["SIM 1"]?.renewalDate?.date, dateOnly(y: 2026, m: 10, d: 17))
    }

    func testHistoryIsAscendingAndOKOnly() throws {
        let store = try Store(path: tempPath())
        for i in 0..<3 {
            let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: Double(9 - i), allowanceGB: 10,
                                   renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
            try store.insert(Reading.success(account: "A", data: data, fetchedAt: date(2026, 10, 1 + i)))
        }
        try store.insert(Reading.failure(account: "A", error: "x", fetchedAt: date(2026, 10, 5)))

        let history = try store.history(account: "A", since: date(2026, 10, 1))
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0].remainingGB, 9)
        XCTAssertEqual(history[2].remainingGB, 7)
    }

    func testDeleteOlderThan() throws {
        let store = try Store(path: tempPath())
        try store.insert(Reading.failure(account: "A", error: "old", fetchedAt: date(2025, 1, 1)))
        try store.insert(Reading.failure(account: "A", error: "new", fetchedAt: date(2026, 10, 1)))
        let deleted = try store.deleteOlderThan(date(2026, 1, 1))
        XCTAssertEqual(deleted, 1)
    }

    /// Review Focus #4: a DB written with the Go app's raw schema must read back
    /// with correct date/timestamp parsing.
    func testReadsGoSchemaDatabase() throws {
        let path = tempPath()
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE readings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account TEXT NOT NULL, fetched_at TEXT NOT NULL, ok INTEGER NOT NULL,
                    error TEXT, phone TEXT, offer TEXT,
                    used_gb REAL, remaining_gb REAL, allowance_gb REAL, credit_eur REAL,
                    renewal_date TEXT, period_start TEXT, period_end TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO readings
                (account, fetched_at, ok, error, phone, offer, used_gb, remaining_gb, allowance_gb,
                 credit_eur, renewal_date, period_start, period_end)
                VALUES ('SIM 1', '2026-10-01T08:00:00Z', 1, NULL, '3330000000', 'GIGA 200',
                        2.29, 197.0, 200.0, 4.32, '2026-11-02', '2026-10-01', '2026-11-01')
                """)
        }
        let store = try Store(path: path) // migrator is idempotent
        let latest = try store.latestPerAccount()
        let reading = try XCTUnwrap(latest["SIM 1"])
        XCTAssertEqual(reading.remainingGB, 197)
        XCTAssertEqual(reading.renewalDate?.date, dateOnly(y: 2026, m: 11, d: 2))
        XCTAssertEqual(reading.periodStart?.date, dateOnly(y: 2026, m: 10, d: 1))
        XCTAssertEqual(reading.fetchedAt.date, date(2026, 10, 1))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'Store'`).

- [ ] **Step 3: Implement `Store.swift`**

```swift
import Foundation
import GRDB

/// SQLite persistence with the exact schema of the Go app, so history
/// migrates without conversion.
final class Store: Sendable {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("RiepilogoIliad", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("iliad.db")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "readings", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account", .text).notNull()
                t.column("fetched_at", .text).notNull()
                t.column("ok", .integer).notNull()
                t.column("error", .text)
                t.column("phone", .text)
                t.column("offer", .text)
                t.column("used_gb", .double)
                t.column("remaining_gb", .double)
                t.column("allowance_gb", .double)
                t.column("credit_eur", .double)
                t.column("renewal_date", .text)
                t.column("period_start", .text)
                t.column("period_end", .text)
            }
            try db.create(index: "idx_readings_account_fetched", on: "readings",
                          columns: ["account", "fetched_at"], ifNotExists: true)
        }
        return migrator
    }

    func insert(_ reading: Reading) throws {
        var record = reading
        try dbQueue.write { db in try record.insert(db) }
    }

    func latestPerAccount() throws -> [String: Reading] {
        let sql = """
        SELECT * FROM readings r
        WHERE r.id = (SELECT MAX(id) FROM readings WHERE account = r.account)
        """
        return try dbQueue.read { db in
            let rows = try Reading.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.account, $0) })
        }
    }

    func lastGoodPerAccount() throws -> [String: Reading] {
        let sql = """
        SELECT * FROM readings r
        WHERE r.id = (SELECT MAX(id) FROM readings WHERE account = r.account AND ok = 1)
        """
        return try dbQueue.read { db in
            let rows = try Reading.fetchAll(db, sql: sql)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.account, $0) })
        }
    }

    func history(account: String, since: Date) throws -> [Reading] {
        try dbQueue.read { db in
            try Reading
                .filter(Column("account") == account && Column("ok") == true &&
                        Column("fetched_at") >= Timestamp(date: since).databaseValue)
                .order(Column("fetched_at").asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func deleteOlderThan(_ date: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM readings WHERE fetched_at < ?",
                           arguments: [Timestamp(date: date)])
            return db.changesCount
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all store tests pass, including the Go-schema compatibility test.

- [ ] **Step 5: Commit**

```bash
git add RiepilogoIliad/Core/Store.swift RiepilogoIliadTests/StoreTests.swift
git commit -m "feat: GRDB store compatible with the Go app's schema"
```

---

### Task 8: RefreshCoordinator (single-flight, persistence, hydration)

**Files:**
- Create: `RiepilogoIliad/Core/RefreshCoordinator.swift`
- Create: `RiepilogoIliadTests/RefreshCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Store`, `AutoFetcher`, `CredentialStore`, `parseAccountPage`, `Reading`, `Entry`, `Snapshot`, `NotificationDecider` (Task 9 provides the decider; this task takes a protocol so it compiles before Task 9 — see below).
- Produces: `actor RefreshCoordinator` with `snapshot()`, `refreshOnce() async -> Bool`, `checkAccounts() async -> [CheckResult]`; `struct CheckResult`.

Because Task 9 adds notifications, this task depends on a minimal protocol defined here and implemented there:

```swift
protocol NotificationDeciding: Sendable {
    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision
    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async
}
```
`NotificationDecision` is defined in Task 9; for this task, add it to `Models.swift` now:

```swift
enum NotificationDecision: Equatable, Sendable {
    case none, low, exhausted, renewed
}
```

- [ ] **Step 1: Write the failing tests**

`RiepilogoIliadTests/RefreshCoordinatorTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

private struct BlockingFetcher: HTMLFetcher {
    let gate: AsyncStream<Void>?
    let result: @Sendable () throws -> String

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        if let gate {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        return try result()
    }
}

private final class FakeNotifier: NotificationDeciding, @unchecked Sendable {
    var decisions: [NotificationDecision] = []
    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision { .none }
    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async {
        decisions.append(decision)
    }
}

final class RefreshCoordinatorTests: XCTestCase {
    private let page = #"<html><body><span class="red">2 GB / 200 GB</span><span class="big red">198</span><span class="small red">GB</span><p>Si rinnova il 17/10/2026.</p></body></html>"#

    private func makeCoordinator(
        store: Store,
        direct: any HTMLFetcher,
        safari: any HTMLFetcher = HTTPFetcher(baseURL: URL(string: "https://never.test")!)
    ) throws -> RefreshCoordinator {
        let account = Account(name: "SIM 1", username: "u", renewalDay: nil)
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("p", for: account.id)
        return try RefreshCoordinator(
            store: store,
            fetcher: AutoFetcher(direct: direct, safari: safari, mode: .auto),
            credentials: credentials,
            accounts: { [account] },
            notifier: FakeNotifier(),
            retentionDays: 180)
    }

    func testRefreshPersistsAndCaches() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let coordinator = try makeCoordinator(store: store, direct: StubFetcher { page })
        let ran = await coordinator.refreshOnce()
        XCTAssertTrue(ran)
        let snapshot = await coordinator.snapshot()
        let entry = try XCTUnwrap(snapshot.entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 198)
        XCTAssertNil(entry.lastError)
        XCTAssertEqual(try store.latestPerAccount()["SIM 1"]?.ok, true)
    }

    func testFailureKeepsLastGood() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let shouldFail = Box(false)
        let direct = StubFetcher {
            if shouldFail.value { throw IliadError.auth("credenziali non valide") }
            return page
        }
        let coordinator = try makeCoordinator(store: store, direct: direct)
        _ = await coordinator.refreshOnce()
        shouldFail.value = true
        _ = await coordinator.refreshOnce()
        let entry = try XCTUnwrap(await coordinator.snapshot().entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 198)
        XCTAssertEqual(entry.lastError, "credenziali non valide")
        XCTAssertEqual(try store.latestPerAccount()["SIM 1"]?.ok, false)
    }

    func testSingleFlight() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let coordinator = try makeCoordinator(store: store, direct: BlockingFetcher(gate: stream) { page })
        async let first = coordinator.refreshOnce()
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = await coordinator.refreshOnce()
        XCTAssertFalse(second)
        continuation.finish()
        XCTAssertTrue(await first)
    }

    func testHydratesFromStore() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: 7, allowanceGB: 10,
                               renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
        try store.insert(Reading.success(account: "SIM 1", data: data, fetchedAt: Date()))
        let coordinator = try makeCoordinator(store: store, direct: StubFetcher { page })
        let entry = try XCTUnwrap(await coordinator.snapshot().entries["SIM 1"])
        XCTAssertEqual(entry.lastGood?.remainingGB, 7)
    }

    func testCheckAccountsReportsPath() async throws {
        let store = try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).db").path)
        let coordinator = try makeCoordinator(
            store: store,
            direct: StubFetcher { throw IliadError.network("redirect loop") },
            safari: StubFetcher { page })
        let results = await coordinator.checkAccounts()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].ok)
        XCTAssertEqual(results[0].path, .safari)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'RefreshCoordinator'`).

- [ ] **Step 3: Implement `RefreshCoordinator.swift`**

```swift
import Foundation

struct CheckResult: Sendable {
    var account: String
    var ok: Bool
    var path: FetchPath?
    var usedGB: Double?
    var remainingGB: Double?
    var allowanceGB: Double?
    var renewalDate: Date?
    var daysToRenewal: Int?
    var error: String?
}

/// Runs single-flight refresh cycles and keeps the UI snapshot.
actor RefreshCoordinator {
    private let store: Store
    private let fetcher: AutoFetcher
    private let credentials: CredentialStore
    private let accounts: @Sendable () -> [Account]
    private let notifier: NotificationDeciding
    private let retentionDays: Int

    private var entries: [String: Entry] = [:]
    private var refreshing = false
    private var lastCycle: Date?

    init(store: Store,
         fetcher: AutoFetcher,
         credentials: CredentialStore,
         accounts: @escaping @Sendable () -> [Account],
         notifier: NotificationDeciding,
         retentionDays: Int = 180) throws {
        self.store = store
        self.fetcher = fetcher
        self.credentials = credentials
        self.accounts = accounts
        self.notifier = notifier
        self.retentionDays = retentionDays

        let latest = try store.latestPerAccount()
        let lastGood = try store.lastGoodPerAccount()
        for account in accounts() {
            var entry = Entry(account: account.name)
            if let row = latest[account.name] {
                entry.lastAttempt = row.fetchedAt.date
                if !row.ok { entry.lastError = row.error }
            }
            entry.lastGood = lastGood[account.name]
            entries[account.name] = entry
        }
        _ = try? store.deleteOlderThan(Date().addingTimeInterval(-Double(retentionDays) * 86400))
    }

    func snapshot() -> Snapshot {
        Snapshot(entries: entries, refreshing: refreshing, lastCycle: lastCycle)
    }

    func refreshOnce() async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        defer {
            refreshing = false
            lastCycle = Date()
        }
        for account in accounts() {
            await refresh(account: account)
        }
        return true
    }

    func checkAccounts() async -> [CheckResult] {
        var results: [CheckResult] = []
        for account in accounts() {
            let now = Date()
            do {
                guard let password = try credentials.password(for: account.id) else {
                    throw IliadError.auth("password mancante nel Portachiavi")
                }
                let fetched = FetchedAccount(id: account.id, name: account.name,
                                             username: account.username, password: password,
                                             renewalDay: account.renewalDay)
                let outcome = try await fetcher.fetchHTML(for: fetched)
                let data = try parseAccountPage(html: outcome.html, now: todayNow(), renewalDay: account.renewalDay)
                results.append(CheckResult(
                    account: account.name, ok: true, path: outcome.path,
                    usedGB: data.usedGB, remainingGB: data.remainingGB, allowanceGB: data.allowanceGB,
                    renewalDate: data.renewalDate,
                    daysToRenewal: data.renewalDate.map { daysBetween(todayNow(), $0) },
                    error: nil))
            } catch {
                let message = (error as? IliadError)?.userMessage ?? error.localizedDescription
                results.append(CheckResult(account: account.name, ok: false, path: nil,
                                           usedGB: nil, remainingGB: nil, allowanceGB: nil,
                                           renewalDate: nil, daysToRenewal: nil, error: message))
            }
        }
        return results
    }

    private func refresh(account: Account) async {
        let now = Date()
        do {
            guard let password = try credentials.password(for: account.id) else {
                throw IliadError.auth("password mancante nel Portachiavi")
            }
            let fetched = FetchedAccount(id: account.id, name: account.name,
                                         username: account.username, password: password,
                                         renewalDay: account.renewalDay)
            let outcome = try await fetcher.fetchHTML(for: fetched)
            let data = try parseAccountPage(html: outcome.html, now: todayNow(), renewalDay: account.renewalDay)
            let reading = Reading.success(account: account.name, data: data, fetchedAt: now)
            try store.insert(reading)

            let previous = entries[account.name]?.lastGood?.accountData
            entries[account.name] = Entry(account: account.name, lastGood: reading,
                                          lastAttempt: now, lastError: nil)
            let decision = notifier.decide(previous: previous, current: data, account: account)
            await notifier.post(decision, account: account, data: data)
        } catch {
            let message = (error as? IliadError)?.userMessage ?? error.localizedDescription
            try? store.insert(Reading.failure(account: account.name, error: message, fetchedAt: now))
            var entry = entries[account.name] ?? Entry(account: account.name)
            entry.lastAttempt = now
            entry.lastError = message
            entries[account.name] = entry
        }
    }

    private func todayNow() -> Date {
        today(in: TimeZone(identifier: "Europe/Rome") ?? .current)
    }
}

extension Reading {
    /// Converts a stored reading back into parsed account data (for notification decisions).
    var accountData: AccountData {
        AccountData(
            creditEUR: creditEUR, usedGB: usedGB, remainingGB: remainingGB,
            allowanceGB: allowanceGB,
            renewalDate: renewalDate?.date, periodStart: periodStart?.date, periodEnd: periodEnd?.date,
            phoneNumber: phone ?? "", offerName: offer ?? "")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all coordinator tests pass.

- [ ] **Step 5: Commit**

```bash
git add RiepilogoIliad/Core/ RiepilogoIliadTests/
git commit -m "feat: single-flight refresh coordinator with persistence"
```

---

### Task 9: Notifications

**Files:**
- Create: `RiepilogoIliad/Core/Notifications.swift`
- Create: `RiepilogoIliadTests/NotificationsTests.swift`

**Interfaces:**
- Consumes: `NotificationDecision`, `NotificationDeciding`, `Account`, `AccountData`.
- Produces: `NotificationDecider` (threshold-based decisions), `SystemNotificationPoster`.

- [ ] **Step 1: Write the failing tests**

`RiepilogoIliadTests/NotificationsTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class NotificationsTests: XCTestCase {
    private let account = Account(name: "SIM 1", username: "u")
    private let decider = NotificationDecider()

    private func data(remaining: Double?, allowance: Double? = 200) -> AccountData {
        AccountData(creditEUR: nil, usedGB: nil, remainingGB: remaining, allowanceGB: allowance,
                    renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
    }

    func testExhausted() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 0), account: account), .exhausted)
    }

    func testLowThreshold() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 15), account: account), .low)
        XCTAssertEqual(decider.decide(previous: data(remaining: 50), current: data(remaining: 30), account: account), .none)
    }

    func testRenewed() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 2), current: data(remaining: 195), account: account), .renewed)
    }

    func testRenewedBeatsLow() {
        XCTAssertEqual(decider.decide(previous: data(remaining: 0), current: data(remaining: 195), account: account), .renewed)
    }

    func testNoPreviousMeansNoRenewed() {
        XCTAssertEqual(decider.decide(previous: nil, current: data(remaining: 195), account: account), .none)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'NotificationDecider'`).

- [ ] **Step 3: Implement `Notifications.swift`**

```swift
import Foundation
import UserNotifications

/// Pure decision logic: low data, exhausted, renewed cycle.
/// Providers keep thresholds and the enabled flag live without rebuilding.
struct NotificationDecider: NotificationDeciding {
    var thresholdProvider: @Sendable () -> Double
    var enabledProvider: @Sendable () -> Bool

    init(thresholdPercent: Double = 10, enabled: @escaping @Sendable () -> Bool = { true }) {
        self.thresholdProvider = { thresholdPercent }
        self.enabledProvider = enabled
    }

    init(thresholdProvider: @escaping @Sendable () -> Double,
         enabledProvider: @escaping @Sendable () -> Bool = { true }) {
        self.thresholdProvider = thresholdProvider
        self.enabledProvider = enabledProvider
    }

    func decide(previous: AccountData?, current: AccountData, account: Account) -> NotificationDecision {
        guard enabledProvider() else { return .none }
        let thresholdPercent = thresholdProvider()
        guard let remaining = current.remainingGB else { return .none }

        if let old = previous?.remainingGB, old >= 0, remaining > old + 1, remaining > old * 2 {
            return .renewed
        }
        if remaining == 0 { return .exhausted }
        if let allowance = current.allowanceGB, allowance > 0,
           remaining / allowance * 100 <= thresholdPercent {
            return .low
        }
        return .none
    }

    func post(_ decision: NotificationDecision, account: Account, data: AccountData) async {
        guard decision != .none else { return }
        let body: String
        switch decision {
        case .low: body = "Restano \(formatGB(data.remainingGB ?? 0)) sulla \(account.name)."
        case .exhausted: body = "Dati esauriti sulla \(account.name)."
        case .renewed: body = "Nuovo ciclo dati sulla \(account.name): \(formatGB(data.remainingGB ?? 0))."
        case .none: return
        }
        await SystemNotificationPoster.shared.post(
            title: "Riepilogo Iliad", body: body,
            id: "\(account.id)-\(decision)")
    }
}

/// Sends local notifications via UNUserNotificationCenter.
final class SystemNotificationPoster: @unchecked Sendable {
    static let shared = SystemNotificationPoster()

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func post(title: String, body: String, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
```

`formatGB` is added in Task 10 (`Format.swift`). To keep this task compiling before Task 10, add the helper now to `Notifications.swift` as a private fallback, then remove it in Task 10:

```swift
/// Temporary formatting helper; Task 10 moves this to Format.swift.
func formatGB(_ value: Double) -> String {
    var s = String(format: "%.1f", value)
    s = s.replacingOccurrences(of: ".", with: ",")
    if s.hasSuffix(",0") { s.removeLast(2) }
    return s + " GB"
}
```
(When Task 10 lands, delete this function from `Notifications.swift`; the shared one in `Format.swift` is identical.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: notification tests pass.

- [ ] **Step 5: Commit**

```bash
git add RiepilogoIliad/Core/Notifications.swift RiepilogoIliadTests/NotificationsTests.swift
git commit -m "feat: low/exhausted/renewed notifications"
```

---

### Task 10: App shell, formatting, AppModel, menu bar + popover

**Files:**
- Create: `RiepilogoIliad/Core/Format.swift`
- Create: `RiepilogoIliad/Core/AppModel.swift`
- Create: `RiepilogoIliad/App/MenuBarLabel.swift`
- Create: `RiepilogoIliad/App/PopoverView.swift`
- Modify: `RiepilogoIliad/App/RiepilogoIliadApp.swift`
- Modify: `RiepilogoIliad/Core/Notifications.swift` (delete the temporary `formatGB`)
- Modify: `RiepilogoIliad/Core/Settings.swift` (own a `RuntimeConfig`)
- Create: `RiepilogoIliadTests/FormatTests.swift`
- Create: `RiepilogoIliadTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppSettings`, `RefreshCoordinator`, `Entry`, `Snapshot`, `formatGB` (shared).
- Produces: `formatGB/formatEUR/formatPct/formatDate/formatDateTime/formatDays/barClass`; `RuntimeConfig`; `Totals`; `computeTotals(entries:)`; `sortEntries(_:)`; `AppModel`; `MenuBarLabel`; `PopoverView`.

- [ ] **Step 1: Write the failing tests**

`RiepilogoIliadTests/FormatTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class FormatTests: XCTestCase {
    func testFormatGB() {
        XCTAssertEqual(formatGB(43.25), "43,2 GB")
        XCTAssertEqual(formatGB(100), "100 GB")
        XCTAssertEqual(formatGB(0), "0 GB")
    }

    func testBarClass() {
        XCTAssertEqual(barClass(usedPct: 0), "ok")
        XCTAssertEqual(barClass(usedPct: 69.9), "ok")
        XCTAssertEqual(barClass(usedPct: 70), "warn")
        XCTAssertEqual(barClass(usedPct: 90), "warn")
        XCTAssertEqual(barClass(usedPct: 90.1), "danger")
    }

    func testFormatDays() {
        XCTAssertEqual(formatDays(-2), "2 giorni fa")
        XCTAssertEqual(formatDays(0), "oggi")
        XCTAssertEqual(formatDays(1), "domani")
        XCTAssertEqual(formatDays(6), "tra 6 giorni")
    }

    func testFormatDate() {
        XCTAssertEqual(formatDate(dateOnly(y: 2026, m: 10, d: 7)), "07/10/2026")
    }
}
```

`RiepilogoIliadTests/AppModelTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class AppModelTests: XCTestCase {
    private func entry(name: String, remaining: Double?, allowance: Double?, renewal: Date?) -> Entry {
        let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: remaining, allowanceGB: allowance,
                               renewalDate: renewal, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
        var entry = Entry(account: name)
        entry.lastGood = Reading.success(account: name, data: data, fetchedAt: Date())
        return entry
    }

    func testTotalsExcludeMissingAndComputeNextRenewal() {
        let entries = [
            entry(name: "A", remaining: 57.5, allowance: 100, renewal: dateOnly(y: 2026, m: 10, d: 17)),
            entry(name: "B", remaining: 5, allowance: 5, renewal: dateOnly(y: 2026, m: 10, d: 7)),
            Entry(account: "C"),
        ]
        let totals = computeTotals(entries: entries)
        XCTAssertEqual(totals.remainingGB, 62.5)
        XCTAssertEqual(totals.allowanceGB, 105)
        XCTAssertEqual(totals.excluded, 1)
        XCTAssertEqual(totals.nextName, "B")
        XCTAssertTrue(totals.hasData)
    }

    func testSortByDaysToRenewal() {
        let today = dateOnly(y: 2026, m: 10, d: 2)
        let entries = [
            entry(name: "later", remaining: 1, allowance: 10, renewal: dateOnly(y: 2026, m: 10, d: 30)),
            entry(name: "sooner", remaining: 1, allowance: 10, renewal: dateOnly(y: 2026, m: 10, d: 7)),
            Entry(account: "no-renewal"),
        ]
        let sorted = sortEntries(entries, today: today)
        XCTAssertEqual(sorted.map(\.account), ["sooner", "later", "no-renewal"])
    }

    func testEmptyTotals() {
        let totals = computeTotals(entries: [])
        XCTAssertFalse(totals.hasData)
        XCTAssertEqual(totals.excluded, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'formatGB'` / `computeTotals`).

- [ ] **Step 3: Implement `Format.swift`**

```swift
import Foundation

func formatGB(_ value: Double) -> String {
    var s = String(format: "%.1f", value)
    s = s.replacingOccurrences(of: ".", with: ",")
    if s.hasSuffix(",0") { s.removeLast(2) }
    return s + " GB"
}

func formatEUR(_ value: Double) -> String {
    String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",") + " €"
}

func formatPct(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

func formatDate(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
    let c = calendar.dateComponents([.day, .month, .year], from: date)
    return String(format: "%02d/%02d/%04d", c.day!, c.month!, c.year!)
}

func formatDateTime(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
    let c = calendar.dateComponents([.day, .month, .year, .hour, .minute], from: date)
    return String(format: "%02d/%02d/%04d %02d:%02d", c.day!, c.month!, c.year!, c.hour!, c.minute!)
}

func formatDays(_ days: Int) -> String {
    switch days {
    case ..<0: "\(-days) giorni fa"
    case 0: "oggi"
    case 1: "domani"
    default: "tra \(days) giorni"
    }
}

func barClass(usedPct: Double) -> String {
    if usedPct > 90 { return "danger" }
    if usedPct >= 70 { return "warn" }
    return "ok"
}
```

Delete the temporary `formatGB` from `Notifications.swift`.

- [ ] **Step 4: Add `RuntimeConfig` to `Settings.swift` and update it on changes**

Add to `Settings.swift`:
```swift
/// Thread-safe snapshot the coordinator reads from background actors.
final class RuntimeConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var _accounts: [Account] = []
    private var _fetchMode: FetchMode = .auto
    private var _lowThresholdPercent: Double = 10
    private var _notificationsEnabled = false

    var accounts: [Account] { lock.lock(); defer { lock.unlock() }; return _accounts }
    var fetchMode: FetchMode { lock.lock(); defer { lock.unlock() }; return _fetchMode }
    var lowThresholdPercent: Double { lock.lock(); defer { lock.unlock() }; return _lowThresholdPercent }
    var notificationsEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _notificationsEnabled }

    func update(accounts: [Account], fetchMode: FetchMode, lowThresholdPercent: Double,
                notificationsEnabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        _accounts = accounts
        _fetchMode = fetchMode
        _lowThresholdPercent = lowThresholdPercent
        _notificationsEnabled = notificationsEnabled
    }
}
```
In `AppSettings`: add `let runtime = RuntimeConfig()`, and in `init` after loading call `syncRuntime()`. Add `private func syncRuntime() { runtime.update(accounts: accounts, fetchMode: fetchMode, lowThresholdPercent: lowThresholdPercent, notificationsEnabled: notificationsEnabled) }` and call it from every `didSet`.

- [ ] **Step 5: Implement `AppModel.swift`**

```swift
import Foundation
import Observation

struct Totals: Equatable {
    var remainingGB = 0.0
    var allowanceGB = 0.0
    var pct = 0.0
    var excluded = 0
    var nextName: String?
    var nextDays: Int?
    var hasData = false
}

func computeTotals(entries: [Entry], today: Date = today(in: TimeZone(identifier: "Europe/Rome")!)) -> Totals {
    var totals = Totals()
    for entry in entries {
        guard let good = entry.lastGood,
              let remaining = good.remainingGB,
              let allowance = good.allowanceGB, allowance > 0 else {
            totals.excluded += 1
            continue
        }
        totals.remainingGB += remaining
        totals.allowanceGB += allowance
        if let renewal = good.renewalDate?.date {
            let days = daysBetween(today, renewal)
            if totals.nextDays == nil || days < totals.nextDays! {
                totals.nextDays = days
                totals.nextName = entry.account
            }
        }
    }
    totals.hasData = totals.allowanceGB > 0
    if totals.hasData {
        totals.pct = totals.remainingGB / totals.allowanceGB * 100
    }
    return totals
}

func sortEntries(_ entries: [Entry], today: Date = today(in: TimeZone(identifier: "Europe/Rome")!)) -> [Entry] {
    entries.sorted { lhs, rhs in
        let l = lhs.lastGood?.renewalDate.map { daysBetween(today, $0.date) }
        let r = rhs.lastGood?.renewalDate.map { daysBetween(today, $0.date) }
        switch (l, r) {
        case let (l?, r?): return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.account < rhs.account
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var snapshot = Snapshot()
    var bootstrapError: String?
    let settings: AppSettings
    let coordinator: RefreshCoordinator
    private var timerTask: Task<Void, Never>?

    init(settings: AppSettings, coordinator: RefreshCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    var totals: Totals { computeTotals(entries: Array(snapshot.entries.values)) }
    var cards: [Entry] { sortEntries(Array(snapshot.entries.values)) }
    var hasWarning: Bool {
        cards.contains { entry in
            guard let remaining = entry.lastGood?.remainingGB else { return false }
            if remaining == 0 { return true }
            if let allowance = entry.lastGood?.allowanceGB, allowance > 0 {
                return remaining / allowance * 100 <= settings.lowThresholdPercent
            }
            return false
        }
    }

    func start() {
        Task {
            await reload()
            _ = await coordinator.refreshOnce()
            await reload()
        }
        timerTask = Task { [settings] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(settings.refreshInterval))
                _ = await coordinator.refreshOnce()
                await self.reload()
            }
        }
    }

    func refreshNow() {
        Task {
            _ = await coordinator.refreshOnce()
            await reload()
        }
    }

    func reload() async {
        snapshot = await coordinator.snapshot()
    }

    func historyPoints(account: String, days: Int = 30) -> [HistoryPoint] {
        guard let store = coordinator.storeHandle else { return [] }
        let readings = (try? store.history(account: account, since: Date().addingTimeInterval(-Double(days) * 86400))) ?? []
        return dailyHistoryPoints(readings: readings, timeZone: TimeZone(identifier: "Europe/Rome") ?? .current)
    }
}
```
`HistoryPoint`/`dailyHistoryPoints` are defined in Task 11; to keep this task compiling, add a stub in `AppModel.swift` now and replace it in Task 11:

```swift
/// Replaced with the real implementation in Task 11.
struct HistoryPoint: Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var remainingGB: Double
}

/// Replaced with the real implementation in Task 11.
func dailyHistoryPoints(readings: [Reading], timeZone: TimeZone) -> [HistoryPoint] { [] }
```
Add `nonisolated var storeHandle: Store? { nil }` to `RefreshCoordinator` now, and replace it in Task 11 with `nonisolated var storeHandle: Store { store }` (Swift 6: an actor-isolated accessor cannot be read from the main actor). Also replaced in Task 11: `AppModel.historyPoints` becomes `async` and reads the store off the main actor. (These are small, explicit edits; the plan carries them forward.)

- [ ] **Step 6: Implement views**

`RiepilogoIliad/App/MenuBarLabel.swift`:
```swift
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: (model?.hasWarning ?? false)
                  ? "exclamationmark.triangle.fill"
                  : "antenna.radiowaves.left.and.right")
            if let totals = model?.totals, totals.hasData {
                Text(formatGB(totals.remainingGB))
            }
        }
    }
}
```

`RiepilogoIliad/App/PopoverView.swift`:
```swift
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.cards.isEmpty {
                Text("Nessun account configurato. Apri le impostazioni per aggiungere le SIM.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.cards, id: \.account) { entry in
                SimCardView(entry: entry, threshold: model.settings.lowThresholdPercent)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.totals.hasData {
                Text("Ti restano \(formatGB(model.totals.remainingGB)) su \(formatGB(model.totals.allowanceGB)) (\(formatPct(model.totals.pct)))")
                    .font(.headline)
                if let name = model.totals.nextName, let days = model.totals.nextDays {
                    Text("Prossimo rinnovo: \(formatDays(days)) (\(name))")
                        .foregroundStyle(.secondary)
                }
                if model.totals.excluded > 0 {
                    Text("\(model.totals.excluded) SIM senza dati (escluse dal totale)")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Nessun dato ancora — attendo il primo aggiornamento")
                    .font(.headline)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Aggiorna ora") { model.refreshNow() }
                .disabled(model.snapshot.refreshing)
            if model.snapshot.refreshing { ProgressView().controlSize(.small) }
            Spacer()
            Button("Storico") { openWindow(id: "history") }
            SettingsLink { Image(systemName: "gearshape") }
        }
    }
}

struct SimCardView: View {
    let entry: Entry
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.account).font(.subheadline.bold())
                Spacer()
                if entry.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if let good = entry.lastGood, let remaining = good.remainingGB, let allowance = good.allowanceGB {
                let used = good.usedGB ?? max(0, allowance - remaining)
                let usedPct = allowance > 0 ? used / allowance * 100 : 0
                Text("Restano \(formatGB(remaining)) su \(formatGB(allowance))")
                ProgressView(value: min(usedPct, 100), total: 100)
                    .tint(color(for: barClass(usedPct: usedPct)))
                Text("\(formatGB(used)) usati (\(formatPct(usedPct)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let renewal = good.renewalDate?.date {
                    Text("Rinnovo: \(formatDate(renewal)) — \(formatDays(daysBetween(today(in: TimeZone(identifier: "Europe/Rome")!), renewal)))")
                        .font(.caption)
                }
                if let credit = good.creditEUR {
                    Text("Credito: \(formatEUR(credit))").font(.caption)
                }
            } else {
                Text("Errore: \(entry.lastError ?? "nessun dato")")
                    .foregroundStyle(.red).font(.caption)
            }
            if let error = entry.lastError, entry.lastGood != nil {
                Text("Ultimo aggiornamento fallito: \(error)")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(for barClass: String) -> Color {
        switch barClass {
        case "warn": .yellow
        case "danger": .red
        default: .green
        }
    }
}
```

Replace `RiepilogoIliad/App/RiepilogoIliadApp.swift`:
```swift
import SwiftUI

@main
struct RiepilogoIliadApp: App {
    @State private var model: AppModel?
    @State private var bootstrapError: String?

    init() {
        do {
            let settings = AppSettings()
            let runtime = settings.runtime
            let store = try Store(path: Store.defaultURL().path)
            let fetcher = AutoFetcher(direct: HTTPFetcher(), safari: SafariFetcher(),
                                      modeProvider: { runtime.fetchMode })
            let notifier = NotificationDecider(
                thresholdProvider: { runtime.lowThresholdPercent },
                enabledProvider: { runtime.notificationsEnabled })
            let coordinator = try RefreshCoordinator(
                store: store, fetcher: fetcher, credentials: KeychainCredentialStore(),
                accounts: { runtime.accounts }, notifier: notifier)
            let appModel = AppModel(settings: settings, coordinator: coordinator)
            appModel.start()
            _model = State(initialValue: appModel)
        } catch {
            _bootstrapError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let model {
                PopoverView().environment(model)
            } else {
                Text("Errore avvio: \(bootstrapError ?? "sconosciuto")").padding()
            }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // The history Window scene is added in Task 11; the Settings scene in Task 12.
    }
}
```

- [ ] **Step 7: Amend `AutoFetcher` for a runtime mode provider**

In `AutoFetcher.swift`, replace the stored `mode` with a provider and add both initializers:
```swift
struct AutoFetcher: Sendable {
    let direct: any HTMLFetcher
    let safari: any HTMLFetcher
    private let modeProvider: @Sendable () -> FetchMode

    init(direct: any HTMLFetcher, safari: any HTMLFetcher, mode: FetchMode) {
        self.init(direct: direct, safari: safari, modeProvider: { mode })
    }

    init(direct: any HTMLFetcher, safari: any HTMLFetcher,
         modeProvider: @escaping @Sendable () -> FetchMode) {
        self.direct = direct
        self.safari = safari
        self.modeProvider = modeProvider
    }

    func fetchHTML(for account: FetchedAccount) async throws -> FetchOutcome {
        switch modeProvider() { /* same body as before */ }
    }
}
```
`NotificationDecider` is already provider-based (Task 9); the app bootstrap wires both providers.

- [ ] **Step 8: Run tests and build**

Run: `make test && make build`
Expected: all tests pass; `BUILD SUCCEEDED`.

- [ ] **Step 9: Commit**

```bash
git add RiepilogoIliad/ RiepilogoIliadTests/
git commit -m "feat: app shell with menu bar, popover, and formatting"
```

---

### Task 11: History window with Swift Charts

**Files:**
- Create: `RiepilogoIliad/App/HistoryWindow.swift`
- Modify: `RiepilogoIliad/App/RiepilogoIliadApp.swift` (add the history Window scene)
- Modify: `RiepilogoIliad/Core/AppModel.swift` (real `dailyHistoryPoints`, real `storeHandle`)
- Modify: `RiepilogoIliad/Core/RefreshCoordinator.swift` (expose `storeHandle`)
- Create: `RiepilogoIliadTests/HistoryTests.swift`

**Interfaces:**
- Consumes: `Store.history`, `Reading`, `HistoryPoint`.
- Produces: `dailyHistoryPoints(readings:timeZone:)`; `HistoryWindow`.

- [ ] **Step 1: Write the failing test**

`RiepilogoIliadTests/HistoryTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class HistoryTests: XCTestCase {
    func testDailyDedupeKeepsLatestPerLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let day1a = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 8))!
        let day1b = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 20))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!

        func reading(_ at: Date, _ remaining: Double) -> Reading {
            let data = AccountData(creditEUR: nil, usedGB: nil, remainingGB: remaining, allowanceGB: 10,
                                   renewalDate: nil, periodStart: nil, periodEnd: nil, phoneNumber: "", offerName: "")
            return Reading.success(account: "A", data: data, fetchedAt: at)
        }

        let points = dailyHistoryPoints(
            readings: [reading(day1a, 9), reading(day1b, 8), reading(day2, 7)],
            timeZone: calendar.timeZone)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].remainingGB, 8) // latest of day 1
        XCTAssertEqual(points[1].remainingGB, 7)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — stub returns `[]`.

- [ ] **Step 3: Replace the stubs**

In `AppModel.swift`, replace the stub `dailyHistoryPoints`:
```swift
func dailyHistoryPoints(readings: [Reading], timeZone: TimeZone) -> [HistoryPoint] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var byDay: [Date: Reading] = [:]
    var order: [Date] = []
    for reading in readings {
        let day = calendar.startOfDay(for: reading.fetchedAt.date)
        if byDay[day] == nil { order.append(day) }
        byDay[day] = reading
    }
    return order.compactMap { day in
        guard let reading = byDay[day], let remaining = reading.remainingGB else { return nil }
        return HistoryPoint(date: day, remainingGB: remaining)
    }
}
```

In `RefreshCoordinator.swift`, replace the stub with:
```swift
nonisolated var storeHandle: Store { store }
```

In `AppModel.swift`, replace the stub `historyPoints` (currently `guard let store = coordinator.storeHandle` + a synchronous read) with an async, off-main-actor read:
```swift
func historyPoints(account: String, days: Int = 30) async -> [HistoryPoint] {
    let store = coordinator.storeHandle
    let since = Date().addingTimeInterval(-Double(days) * 86400)
    let readings = (try? await Task.detached { try store.history(account: account, since: since) }.value) ?? []
    return dailyHistoryPoints(readings: readings, timeZone: TimeZone(identifier: "Europe/Rome") ?? .current)
}
```

- [ ] **Step 4: Implement `HistoryWindow.swift`**

```swift
import Charts
import SwiftUI

struct HistoryWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String = ""

    private var accounts: [String] { model.cards.map(\.account) }
    @State private var points: [HistoryPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("SIM", selection: $selected) {
                ForEach(accounts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .onAppear { if selected.isEmpty { selected = accounts.first ?? "" } }

            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(x: .value("Data", point.date), y: .value("Restanti", point.remainingGB))
                }
                .chartYAxisLabel("GB rimasti")
                .frame(minHeight: 220)
            } else {
                Text("Storico insufficiente per un grafico (servono almeno 2 giorni di dati).")
                    .foregroundStyle(.secondary)
            }

            Table(points.suffix(14)) {
                TableColumn("Data") { Text(formatDate($0.date)) }
                TableColumn("Restanti") { Text(formatGB($0.remainingGB)) }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .task(id: selected) { points = await model.historyPoints(account: selected) }
    }
}
```

Add the Window scene to `RiepilogoIliadApp.swift` (inside `body`):
```swift
        Window("Storico", id: "history") {
            if let model { HistoryWindow().environment(model) }
        }
```

- [ ] **Step 5: Run tests and build**

Run: `make test && make build`
Expected: history test passes; build succeeds.

- [ ] **Step 6: Commit**

```bash
git add RiepilogoIliad/ RiepilogoIliadTests/
git commit -m "feat: history window with Swift Charts"
```

---

### Task 12: Settings, account management, imports, "Verifica account"

**Files:**
- Create: `RiepilogoIliad/Core/Import.swift`
- Create: `RiepilogoIliad/App/SettingsView.swift`
- Create: `RiepilogoIliad/App/AccountEditorView.swift`
- Modify: `RiepilogoIliad/App/RiepilogoIliadApp.swift` (add the Settings scene)
- Create: `RiepilogoIliadTests/ImportTests.swift`

**Interfaces:**
- Consumes: `AppSettings`, `KeychainCredentialStore`, `RefreshCoordinator.checkAccounts()`, Yams.
- Produces: `importAccounts(fromYAML:) throws -> [ImportedAccount]`; `importDatabase(from:to:) throws`; `SettingsView`; `AccountEditorView`.

- [ ] **Step 1: Write the failing tests**

`RiepilogoIliadTests/ImportTests.swift`:
```swift
import XCTest
@testable import RiepilogoIliad

final class ImportTests: XCTestCase {
    func testImportAccountsFromYAML() throws {
        let yaml = """
        listen: 127.0.0.1:8787
        refresh_interval: 4h
        fetch_mode: safari
        accounts:
          - name: SIM 1
            username: user1
            password: pass1
            renewal_day: 17
          - name: SIM 2
            username: user2
            password: pass2
        """
        let imported = try importAccounts(fromYAML: yaml)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0].name, "SIM 1")
        XCTAssertEqual(imported[0].username, "user1")
        XCTAssertEqual(imported[0].password, "pass1")
        XCTAssertEqual(imported[0].renewalDay, 17)
        XCTAssertNil(imported[1].renewalDay)
    }

    func testImportDatabaseCopiesSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("iliad.db")
        try Data("db".utf8).write(to: source)
        try Data("wal".utf8).write(to: dir.appendingPathComponent("iliad.db-wal"))
        let destination = dir.appendingPathComponent("dest/iliad.db")

        try importDatabase(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("db".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.deletingLastPathComponent()
            .appendingPathComponent("iliad.db-wal")), Data("wal".utf8))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile failure (`cannot find 'importAccounts'`).

- [ ] **Step 3: Implement `Import.swift`**

```swift
import Foundation
import Yams

struct ImportedAccount: Sendable {
    var name: String
    var username: String
    var password: String
    var renewalDay: Int?
}

private struct GoConfig: Decodable {
    struct GoAccount: Decodable {
        var name: String
        var username: String
        var password: String
        var renewal_day: Int?
    }
    var accounts: [GoAccount]
}

/// Parses the Go app's config.yaml.
func importAccounts(fromYAML yaml: String) throws -> [ImportedAccount] {
    let config = try YAMLDecoder().decode(GoConfig.self, from: yaml)
    return config.accounts.map {
        ImportedAccount(name: $0.name, username: $0.username,
                        password: $0.password, renewalDay: $0.renewal_day)
    }
}

/// Copies a Go `iliad.db` (plus WAL/SHM sidecars) to the destination path.
func importDatabase(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
        let sourceFile = URL(fileURLWithPath: source.path + suffix)
        let destinationFile = URL(fileURLWithPath: destination.path + suffix)
        if fileManager.fileExists(atPath: sourceFile.path) {
            if fileManager.fileExists(atPath: destinationFile.path) {
                try fileManager.removeItem(at: destinationFile)
            }
            try fileManager.copyItem(at: sourceFile, to: destinationFile)
        }
    }
}
```

- [ ] **Step 4: Implement `AccountEditorView.swift`**

```swift
import SwiftUI

struct AccountEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var renewalDay = 0

    let account: Account? // nil = new

    var body: some View {
        Form {
            TextField("Nome (es. SIM 1)", text: $name)
            TextField("ID utente / username", text: $username)
            SecureField("Password", text: $password)
            Stepper("Giorno rinnovo (opzionale): \(renewalDay == 0 ? "—" : "\(renewalDay)")",
                    value: $renewalDay, in: 0...28)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            if let account {
                name = account.name
                username = account.username
                renewalDay = account.renewalDay ?? 0
                password = (try? KeychainCredentialStore().password(for: account.id)) ?? ""
            }
        }
        .toolbar {
            Button("Salva") { save() }
            Button("Annulla") { dismiss() }
        }
    }

    private func save() {
        let credentials = KeychainCredentialStore()
        if var existing = account {
            existing.name = name
            existing.username = username
            existing.renewalDay = renewalDay == 0 ? nil : renewalDay
            if let index = model.settings.accounts.firstIndex(where: { $0.id == existing.id }) {
                model.settings.accounts[index] = existing
            }
            try? credentials.setPassword(password, for: existing.id)
        } else {
            let new = Account(name: name, username: username,
                              renewalDay: renewalDay == 0 ? nil : renewalDay)
            model.settings.accounts.append(new)
            try? credentials.setPassword(password, for: new.id)
        }
        dismiss()
    }
}
```

- [ ] **Step 5: Implement `SettingsView.swift`**

```swift
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditingAccount?
    @State private var checkResults: [CheckResult]?
    @State private var importMessage: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Account") {
                ForEach(model.settings.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            Text(account.username).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Modifica") { editing = EditingAccount(account: account) }
                        Button(role: .destructive) { remove(account) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                Button("Aggiungi SIM") { editing = EditingAccount(account: nil) }
            }

            Section("Aggiornamento") {
                Picker("Intervallo", selection: Bindable(model.settings).refreshInterval) {
                    Text("1 ora").tag(TimeInterval(3600))
                    Text("2 ore").tag(TimeInterval(7200))
                    Text("4 ore").tag(TimeInterval(14400))
                    Text("8 ore").tag(TimeInterval(28800))
                    Text("24 ore").tag(TimeInterval(86400))
                }
                Picker("Modalità", selection: Bindable(model.settings).fetchMode) {
                    ForEach(FetchMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper("Soglia dati bassi: \(Int(model.settings.lowThresholdPercent))%",
                        value: Bindable(model.settings).lowThresholdPercent, in: 5...50, step: 5)
            }

            Section("Sistema") {
                Toggle("Notifiche", isOn: Bindable(model.settings).notificationsEnabled)
                    .onChange(of: model.settings.notificationsEnabled) { _, enabled in
                        if enabled { Task { await SystemNotificationPoster.shared.requestAuthorization() } }
                    }
                Toggle("Apri al login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }

            Section("Diagnostica") {
                Button("Verifica account") {
                    Task { checkResults = await model.coordinator.checkAccounts() }
                }
                Button("Importa account da config.yaml") { importAccountsFromFile() }
                Button("Importa storico da iliad.db") { importHistoryFromFile() }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .sheet(item: $editing) { editing in
            AccountEditorView(account: editing.account)
                .environment(model)
        }
        .sheet(item: Binding(
            get: { checkResults.map(CheckResultsBox.init) },
            set: { if $0 == nil { checkResults = nil } })) { box in
            CheckResultsView(results: box.results).environment(model)
        }
    }

    private func remove(_ account: Account) {
        model.settings.accounts.removeAll { $0.id == account.id }
        try? KeychainCredentialStore().deletePassword(for: account.id)
    }

    private func importAccountsFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url,
              let yaml = try? String(contentsOf: url, encoding: .utf8),
              let imported = try? importAccounts(fromYAML: yaml) else { return }
        let credentials = KeychainCredentialStore()
        for item in imported {
            let account = Account(name: item.name, username: item.username, renewalDay: item.renewalDay)
            model.settings.accounts.append(account)
            try? credentials.setPassword(item.password, for: account.id)
        }
        importMessage = "Importate \(imported.count) SIM."
    }

    private func importHistoryFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database]
        guard panel.runModal() == .OK, let url = panel.url,
              let destination = try? Store.defaultURL() else { return }
        do {
            try importDatabase(from: url, to: destination)
            importMessage = "Storico importato. Riavvia l'app per vederlo."
        } catch {
            importMessage = "Import non riuscito: \(error.localizedDescription)"
        }
    }
}

struct CheckResultsBox: Identifiable {
    let id = UUID()
    let results: [CheckResult]
}

struct CheckResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let results: [CheckResult]

    var body: some View {
        Table(results, id: \.account) {
            TableColumn("SIM", value: \.account)
            TableColumn("Esito") { Text($0.ok ? "OK" : "KO") }
            TableColumn("Via") { Text($0.path?.rawValue ?? "—") }
            TableColumn("Restanti") { Text($0.remainingGB.map(formatGB) ?? "—") }
            TableColumn("Rinnovo") { Text($0.renewalDate.map(formatDate) ?? "—") }
            TableColumn("Errore") { Text($0.error ?? "") }
        }
        .frame(width: 640, height: 260)
        .toolbar { Button("Chiudi") { dismiss() } }
    }
}
```

`Account` conforms to `Identifiable`; the editor sheet uses a wrapper so "new account" is representable:

```swift
struct EditingAccount: Identifiable {
    let id = UUID()
    let account: Account? // nil = new
}
```

Add the Settings scene to `RiepilogoIliadApp.swift` (inside `body`):
```swift
        Settings {
            if let model { SettingsView().environment(model) }
        }
```

- [ ] **Step 6: Run tests and build**

Run: `make test && make build`
Expected: import tests pass; build succeeds.

- [ ] **Step 7: Commit**

```bash
git add RiepilogoIliad/ RiepilogoIliadTests/
git commit -m "feat: settings, account management, imports, account check"
```

---

### Task 13: Manual acceptance and README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: runnable app; documented setup.

- [ ] **Step 1: Write `README.md`**

```markdown
# Riepilogo Iliad (macOS)

App nativa per macOS che mostra quanto traffico resta alle SIM Iliad Italia, con notifiche e storico.

## Build e avvio

1. `make generate && make build`
2. `make run` (oppure apri `build/Build/Products/Debug/RiepilogoIliad.app`)

## Prima configurazione

1. Apri il popover dall'icona nella barra dei menu → ingranaggio (Impostazioni).
2. Aggiungi le SIM (nome, ID utente, password). Le password finiscono nel Portachiavi.
3. (Opzionale) "Importa account da config.yaml" e "Importa storico da iliad.db" per migrare dalla app Go.
4. Attiva "Apri al login" e "Notifiche" se vuoi.

## Rete bloccata (hotspot Iliad)

La modalità automatica prova prima la connessione diretta e, se bloccata, passa da Safari.
Per il fallback serve una volta sola: Safari → Impostazioni → Avanzate → "Mostra funzioni per sviluppatori web",
poi menu Sviluppo → "Consenti JavaScript dagli eventi Apple". Al primo uso macOS chiederà il permesso di controllare Safari.

## Note

- Nessun server locale: l'app parla solo con iliad.it (direttamente o tramite Safari).
- Progetto non affiliato a Iliad Italia S.p.A.
```

- [ ] **Step 2: Manual acceptance checklist (run on the Mac)**

1. `make run` → menu bar icon appears; popover shows the SIMs (after the first refresh).
2. On the hotspot: first refresh falls back to Safari (a Safari tab on iliad.it appears/activates), data appears.
3. On a normal network (or with `fetch_mode: direct`): refresh uses direct HTTP, Safari untouched.
4. "Verifica account" shows 5 rows with the transport used (`direct`/`safari`).
5. Force a low reading (or set the threshold to 50%) → a notification appears.
6. Toggle "Apri al login" → app appears in System Settings → General → Login Items.
7. "Importa storico" copies `iliad.db` and the history chart shows the Go app's data.
8. Quit and relaunch → last data shown immediately (hydrated), refresh happens in background.

Record the results in the commit message.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with setup, permissions, and migration"
```

---

## Self-Review Notes

- **Spec coverage:** menu bar/popover/history/settings (§8) Tasks 10–12; fetchers + fallback (§5) Tasks 4–6; parser (§6) Task 3; storage + migration (§7) Tasks 7, 12; notifications/login item (§8) Tasks 9, 12; security (§9) Tasks 2, 5, 12; layout/build (§10) Task 1; testing (§11) every task; rollout (§12) Tasks 12–13.
- **Cross-task amendments the plan carries forward:** Task 10 Step 7 amends `AutoFetcher` (mode provider) and `NotificationDecider` (threshold provider); Task 10 Step 5 adds temporary stubs for `HistoryPoint`/`dailyHistoryPoints`/`storeHandle` that Task 11 replaces; Task 10 Step 3 removes the temporary `formatGB` from Task 9.
- **Type consistency:** `Account`/`FetchedAccount`/`AccountData`/`Reading`/`Entry`/`Snapshot`/`FetchMode`/`FetchPath`/`IliadError` are used with the same field names across tasks; `NotificationDeciding` matches Task 8's consumer and Task 9's implementation; `CheckResult` is produced in Task 8 and consumed in Task 12.
- **Known practical notes for the executor:** the first build downloads SPM packages; Keychain prompts may reappear after rebuilds with ad-hoc signing (expected); the app is `LSUIElement`, so windows need `NSApp.activate` if they don't come forward (add in Task 10 if observed).

