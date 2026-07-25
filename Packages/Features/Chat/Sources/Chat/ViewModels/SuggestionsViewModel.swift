import CoreModels
import CoreNavigation
import Foundation

/// The "Suggestions" surface's view model: accounts worth following, with the
/// follow itself performed inline.
///
/// Unlike All and Requests it owns its own loading rather than sharing the
/// inbox catalog — it reads the social graph, not the conversation list, and
/// it loads lazily so a viewer who never swipes this far never pays for the
/// fan-out.
@MainActor
public final class SuggestionsViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([SuggestionDisplayModel])
        case empty
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    private let repository: any SuggestionsProviding
    private let router: (any Router)?
    private let limit: Int

    private var accounts: [SuggestedAccount] = []
    private var following: Set<ProfileID> = []
    private var dismissed: Set<ProfileID> = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var load: Task<Void, Never>?
    private var hasLoaded = false

    public init(
        repository: any SuggestionsProviding,
        router: (any Router)? = nil,
        limit: Int = 20
    ) {
        self.repository = repository
        self.router = router
        self.limit = limit
    }

    /// First activation loads; later ones are free. Suggestions age slowly —
    /// re-ranking the graph every time the user swipes past would spend a
    /// fan-out of requests to redraw the same rows.
    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            defer { self.load = nil }
            do {
                self.accounts = try await self.repository.suggestions(limit: self.limit)
                self.emit()
            } catch is CancellationError {
                // Superseded.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load suggestions. Pull to retry.")
                }
            }
        }
    }

    // MARK: - Actions

    public func didSelect(_ id: ProfileID) {
        router?.route(to: .profile(id, stub: nil))
    }

    /// The Messages-tab-native quick action: skip the profile and open a DM.
    public func message(_ id: ProfileID) {
        router?.route(to: .messageUser(id))
    }

    /// Optimistic follow/unfollow: the row flips immediately and rolls back if
    /// the call fails, because a follow button that waits on the network reads
    /// as broken well before it reads as careful.
    public func toggleFollow(_ id: ProfileID) {
        let wasFollowing = following.contains(id)
        following.formSymmetricDifference([id])
        emit()
        Task { [weak self] in
            guard let self else { return }
            do {
                if wasFollowing {
                    try await self.repository.unfollow(id)
                } else {
                    try await self.repository.follow(id)
                }
            } catch {
                self.following.formSymmetricDifference([id])
                self.emit()
            }
        }
    }

    /// Follows every id that isn't already followed — the batch action, which
    /// unlike `toggleFollow` has one direction so a mixed selection can't
    /// half-undo itself.
    public func follow(_ ids: [ProfileID]) {
        for id in ids where !following.contains(id) {
            toggleFollow(id)
        }
    }

    /// Hides a suggestion for the session. No wire contract exists for
    /// "not interested", so the suppression is local — and honest about it:
    /// it does not survive relaunch.
    public func dismiss(_ id: ProfileID) {
        dismissed.insert(id)
        emit()
    }

    /// Batch dismiss: one projection for the whole selection rather than one
    /// per row, so the table animates a single change.
    public func dismiss(_ ids: [ProfileID]) {
        guard !ids.isEmpty else { return }
        dismissed.formUnion(ids)
        emit()
    }

    public func isFollowing(_ id: ProfileID) -> Bool { following.contains(id) }

    private func emit() {
        let visible = accounts.filter { !dismissed.contains($0.id) }
        guard !visible.isEmpty else {
            phase = .empty
            return
        }
        phase = .content(visible.map {
            SuggestionDisplayModel(account: $0, isFollowing: following.contains($0.id))
        })
    }
}
