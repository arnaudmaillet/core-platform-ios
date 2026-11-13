import CoreModels
import CoreNetworking
import Foundation

/// State for Settings → Safety → Muted Accounts (#403).
@MainActor
package final class MutedAccountsViewModel {
    package enum Phase: Equatable {
        case loading
        case loaded([MutedProfile])
        case failed
    }

    package private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    package private(set) var failure: NetworkFailure?
    package var onChange: (() -> Void)?

    private let muting: any ProfileMuting

    package init(muting: any ProfileMuting) {
        self.muting = muting
    }

    package func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await muting.mutedProfiles())
        } catch {
            failure = NetworkFailure.of(error)
            phase = .failed
        }
    }

    /// Unmutes everything and drops the row once the server agrees.
    package func unmute(_ profile: MutedProfile) async throws {
        try await muting.setMuteScopes(.none, for: profile.id)
        if case .loaded(let current) = phase {
            phase = .loaded(current.filter { $0.id != profile.id })
        }
    }

    /// "@ada · Posts, Messages".
    package static func detail(for profile: MutedProfile) -> String {
        let scopes = profile.scopes.summary
        return scopes.isEmpty ? "@\(profile.handle)" : "@\(profile.handle) · \(scopes)"
    }
}
