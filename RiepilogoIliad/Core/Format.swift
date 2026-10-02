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
