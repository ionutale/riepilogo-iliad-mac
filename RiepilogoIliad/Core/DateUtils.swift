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
