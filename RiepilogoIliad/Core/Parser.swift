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
