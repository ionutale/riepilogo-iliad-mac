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
        switch modeProvider() {
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
