import Foundation

/// Rejects an account name that cannot be used as a key.
///
/// Two SIMs sharing a name collapse into one `Entry` (the snapshot is keyed by
/// name) and into one `readings.account` series, so a duplicate silently merges
/// two SIMs into a single card whose quota is one card's worth and whose history
/// interleaves both accounts. `SIM 1` — the editor's own placeholder — makes the
/// collision easy to produce. A blank name yields a nameless card and an
/// unusable entry in the History picker.
///
/// Matching is case-insensitive because the names are labels for the user, not
/// identifiers: `sim 1` and `SIM 1` are the same SIM to a human, and the Go app
/// it replaces requires unique SIM names too.
enum AccountName {
    static let emptyMessage = "Il nome della SIM non può essere vuoto."
    static let duplicateMessage = "Esiste già una SIM con questo nome."

    /// Trims surrounding whitespace so `" SIM 1 "` cannot become a third
    /// spelling of an existing name.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when the name is acceptable, otherwise the Italian message to show
    /// inline. `excludingID` is the account being edited: keeping its own name
    /// must not trip the duplicate check.
    static func validate(_ name: String, existing: [Account], excludingID: UUID? = nil) -> String? {
        let trimmed = normalized(name)
        guard !trimmed.isEmpty else { return emptyMessage }
        let duplicate = existing.contains { account in
            guard account.id != excludingID else { return false }
            return normalized(account.name).compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        return duplicate ? duplicateMessage : nil
    }
}
