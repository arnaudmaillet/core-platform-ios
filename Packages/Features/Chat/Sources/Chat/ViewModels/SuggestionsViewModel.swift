import CoreModels
import CoreNavigation
import Foundation

/// The "Suggestions" surface's view model: accounts worth following, with the
/// follow itself performed inline.
///
/// Unlike All and Requests it owns its own loading rather than sharing the
/// inbox catalog — it reads the social graph, not the conversation list, and
/// it loads lazily so a viewer who never swipes this far never pays for it.
///
/// ⚠️ **TWO PAGES, AND THE SECOND IS THE WHOLE LIST (#644).**
/// `SuggestProfiles` has no cursor yet (backend #834): it answers the `limit`
/// best, at most `SocialConnectionsRepository.suggestionLimit`. So the first
/// page asks for `limit`, and the end of the list asks once for the most the
/// server gives; the same graph answers the same order, so the longer list
/// starts with the rows already shown. A refresh asks for as many as are held,
/// so it never takes back rows the viewer scrolled to.
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
    /// The most one ask can bring: the whole list, as far as the server goes.
    private let fullLimit: Int

    private var accounts: [SuggestedAccount] = []
    private var following: Set<ProfileID> = []
    private var dismissed: Set<ProfileID> = []
    /// Readable, because a surface's view can be built after the first phase
    /// landed (the inbox no longer loads every surface up front) and must
    /// render what is current, not `.loading`.
    public private(set) var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    /// Whether the end of the list can bring more: the first page came back
    /// full, and the whole list was not asked for yet.
    public private(set) var hasMore = false
    /// How many the list asks for: `limit`, then `fullLimit` once the viewer
    /// reached the end.
    private var reach: Int
    private var load: Task<Void, Never>?
    private var loadingMore: Task<Void, Never>?
    /// Bumped by every reload, so an answer to a superseded one is dropped.
    private var generation = 0
    private var hasLoaded = false

    public init(
        repository: any SuggestionsProviding,
        router: (any Router)? = nil,
        limit: Int = 20,
        fullLimit: Int = SocialConnectionsRepository.suggestionLimit
    ) {
        self.repository = repository
        self.router = router
        self.limit = limit
        self.fullLimit = max(fullLimit, limit)
        self.reach = limit
    }

    /// First activation loads; later ones are free. Suggestions age slowly —
    /// re-ranking the graph every time the user swipes past would spend
    /// requests to redraw the same rows.
    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// The end of the list came into view: ask once for the whole list.
    ///
    /// ⚠️ **THE SLOT IS FREED BEFORE THE ROWS ARE EMITTED** — rows that land
    /// wholly on screen ask again from `willDisplay`, and a slot still held
    /// would turn that away (`paging-slot-before-render`, #594).
    public func loadMore() {
        guard hasMore, load == nil, loadingMore == nil else { return }
        let current = generation
        let asked = fullLimit
        loadingMore = Task { [weak self] in
            guard let self else { return }
            let more = try? await self.repository.suggestions(limit: asked)
            guard current == self.generation else { return }
            self.loadingMore = nil
            // A failed ask keeps `hasMore`: the next approach asks again.
            guard let more else { return }
            self.reach = asked
            self.hasMore = false
            // The rows on screen keep their places; the server's order puts
            // them first anyway, and a graph that moved meanwhile must not
            // shuffle them under the finger.
            let held = Set(self.accounts.map(\.id))
            self.accounts += more.filter { !held.contains($0.id) }
            self.emit()
        }
    }

    private func reload() {
        load?.cancel()
        loadingMore?.cancel()
        loadingMore = nil
        generation += 1
        let current = generation
        let asked = reach
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let accounts = try await self.repository.suggestions(limit: asked)
                guard current == self.generation else { return }
                self.load = nil
                self.accounts = accounts
                self.hasMore = accounts.count >= asked && asked < self.fullLimit
                self.emit()
            } catch {
                guard current == self.generation else { return }
                self.load = nil
                if error is CancellationError { return }
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load suggestions.")
                }
            }
        }
    }

    // MARK: - Actions

    public func didSelect(_ id: ProfileID) {
        router?.route(to: .profile(id, stub: nil))
    }

    /// The Messages-tab-native quick action: skip the profile and open a DM.
    ///
    /// The row's identity rides along, so the thread opens already titled
    /// rather than resolving its header after the push has finished.
    public func message(_ id: ProfileID) {
        let account = accounts.first { $0.id == id }
        router?.route(to: .messageUser(id, stub: account.map {
            ProfileIdentityStub(handle: $0.handle, displayName: $0.displayName)
        }))
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

    /// Hides a suggestion for the session. No wire contract exists for
    /// "not interested", so the suppression is local — and honest about it:
    /// it does not survive relaunch.
    public func dismiss(_ id: ProfileID) {
        dismissed.insert(id)
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
