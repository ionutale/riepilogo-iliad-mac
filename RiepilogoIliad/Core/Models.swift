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

/// What a refresh cycle decided to notify about. `.none` means "say nothing";
/// the other cases map one-to-one to the user-facing alerts.
enum NotificationDecision: Equatable, Sendable {
    case none, low, exhausted, renewed
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
struct Timestamp: DatabaseValueConvertible, Codable, Equatable, Sendable {
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
struct Day: DatabaseValueConvertible, Codable, Equatable, Sendable {
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

    /// The Go app stores snake_case columns; GRDB maps coding keys straight to
    /// column names, so the names must be spelled out. GRDB's own
    /// `.convertFromSnakeCase` is not an option: it would ask for `usedGb`,
    /// not `usedGB`.
    enum CodingKeys: String, CodingKey {
        case id, account, ok, error, phone, offer
        case fetchedAt = "fetched_at"
        case usedGB = "used_gb"
        case remainingGB = "remaining_gb"
        case allowanceGB = "allowance_gb"
        case creditEUR = "credit_eur"
        case renewalDate = "renewal_date"
        case periodStart = "period_start"
        case periodEnd = "period_end"
    }
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
