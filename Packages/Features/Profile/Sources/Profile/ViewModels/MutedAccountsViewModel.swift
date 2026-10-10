import CoreModels
import Foundation

/// State for Settings → Safety → Muted Accounts (#403).
@MainActor
final class MutedAccountsViewModel {
    enum Phase: Equatable {
        case loading
        case loaded([MutedProfile])
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let muting: any ProfileMuting

    init(muting: any ProfileMuting) {
        self.muting = muting
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await muting.mutedProfiles())
        } catch {
            phase = .failed
        }
    }

    /// Unmutes everything and drops the row once the server agrees.
    func unmute(_ profile: MutedProfile) async throws {
        try await muting.setMuteScopes(.none, for: profile.id)
        if case .loaded(let current) = phase {
            phase = .loaded(current.filter { $0.id != profile.id })
        }
    }

    /// "@ada · Posts, Messages".
    static func detail(for profile: MutedProfile) -> String {
        let scopes = profile.scopes.summary
        return scopes.isEmpty ? "@\(profile.handle)" : "@\(profile.handle) · \(scopes)"
    }
}
