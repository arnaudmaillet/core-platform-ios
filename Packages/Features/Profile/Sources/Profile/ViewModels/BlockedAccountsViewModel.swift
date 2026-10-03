import CoreModels
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

    /// The row's initials: display name first, the handle when there is none.
    static func monogram(for profile: BlockedProfile) -> String {
        let source = profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? profile.handle : profile.displayName
        let initials: [String] = source.split(separator: " ").prefix(2).compactMap { word in word.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }
}
