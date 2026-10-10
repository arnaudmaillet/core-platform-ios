import Foundation

/// State for Settings → Security and Login: the account's sessions and the
/// two ways of ending them.
@MainActor
final class SecuritySettingsViewModel {
    enum Phase: Equatable {
        case loading
        case loaded([AccountSession])
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    /// A refresh over a loaded list failed. The list stays as it was (the
    /// screen says so in passing); only a failed FIRST load is `.failed`.
    var onRefreshFailed: (() -> Void)?

    private let sessions: any AccountSessionsManaging

    init(sessions: any AccountSessionsManaging) {
        self.sessions = sessions
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await sessions.activeSessions())
        } catch {
            // The sessions on screen were true a moment ago: replacing them
            // with an error row would make the list jump for a refresh the
            // viewer never asked for (the screen re-reads on every return).
            if case .loaded = phase {
                onRefreshFailed?()
            } else {
                phase = .failed
            }
        }
    }

    /// Ends one other session and drops its row. Throws so the screen can say
    /// it did not happen; the row stays until the server agrees.
    func revoke(_ session: AccountSession) async throws {
        try await sessions.revokeSession(id: session.id)
        if case .loaded(let current) = phase {
            phase = .loaded(current.filter { $0.id != session.id })
        }
    }

    /// Ends every session, this one included. The caller signs out locally
    /// once this returns.
    func revokeAll() async throws {
        try await sessions.revokeAllSessions()
    }
}
