import CoreModels
import CoreNetworking
import Foundation

/// State for Settings → Safety → Blocked Accounts (#389).
@MainActor
final class BlockedAccountsViewModel {
    enum Phase: Equatable {
        case loading
        case loaded([BlockedProfile])
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private(set) var failure: NetworkFailure?
    var onChange: (() -> Void)?

    private let blocks: any BlockedAccountsManaging

    init(blocks: any BlockedAccountsManaging) {
        self.blocks = blocks
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await blocks.blockedProfiles())
        } catch {
            failure = NetworkFailure.of(error)
            phase = .failed
        }
    }

    /// Unblocks and drops the row once the server agrees.
    func unblock(_ profile: BlockedProfile) async throws {
        try await blocks.unblock(profile.id)
        if case .loaded(let current) = phase {
            phase = .loaded(current.filter { $0.id != profile.id })
        }
    }
}
