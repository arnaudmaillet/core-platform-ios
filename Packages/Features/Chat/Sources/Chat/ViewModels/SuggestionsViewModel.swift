import CoreModels
import CoreNavigation
import CoreNetworking
import Foundation

/// The "Suggestions" surface's view model: accounts worth following, with the
/// follow itself performed inline.
///
/// Unlike All and Requests it owns its own loading rather than sharing the
/// inbox catalog — it reads the social graph, not the conversation list, and
/// it loads lazily so a viewer who never swipes this far never pays for it.
///
/// ⚠️ **PAGE BY PAGE, FOLLOWING THE TOKEN (#644).** `SuggestProfiles` pages
/// with `page_token` (backend #834): the first page asks for `limit`, and
/// each approach to the end of the list asks once for the next `pageLimit`,
/// until the server's token is empty. Three rules the contract sets:
/// - a page filtered down to little or nothing still carries a token, so a
///   short page never ends the list, and an EMPTY one is walked through at
///   once (at most `maxEmptyPagesInARow` in a row) — no new row would reach
///   the end to ask again;
/// - the ranking is recomputed per page, so a profile can come back on a
///   later page: rows are de-duplicated by profile id, the first place kept;
/// - a refresh with later pages on screen replaces only the first page's
///   rows and keeps the rest and the cursor past them, so it never takes
///   back rows the viewer scrolled to.
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
    /// The first page's size.
    private let limit: Int
    /// Every later page's size: the most one ask brings.
    private let pageLimit: Int

    private var accounts: [SuggestedAccount] = []
    /// Rows that came from pages after the first: what a refresh keeps.
    private var laterPageIDs: Set<ProfileID> = []
    private var following: Set<ProfileID> = []
    private var dismissed: Set<ProfileID> = []
    /// Readable, because a surface's view can be built after the first phase
    /// landed (the inbox no longer loads every surface up front) and must
    /// render what is current, not `.loading`.
    public private(set) var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    /// Where the next page starts; nil once the server said the list ended.
    private var nextPageToken: String?
    /// Whether the end of the list can bring more: the server's last page
    /// carried a token.
    public var hasMore: Bool { nextPageToken != nil }
    private var load: Task<Void, Never>?
    private var loadingMore: Task<Void, Never>?
    /// Bumped by every reload, so an answer to a superseded one is dropped.
    private var generation = 0
    private var hasLoaded = false

    /// A page filtered down to nothing still carries a token; this many in a
    /// row are walked through before waiting for the next approach.
    static let maxEmptyPagesInARow = 5
    /// While no row is visible, empty pages are walked on — no row can reach
    /// the end to ask — up to this many in a row before the list says it is
    /// empty. The first load walks them in one go.
    static let maxEmptyPagesWithNothingShown = 20
    /// Pages in a row that added no row, since the last that did.
    private var emptyPagesInARow = 0
    /// Why the last ask at the end failed; nil once one succeeds.
    private var lastAskError: Error?

    /// Whether the list may ask for its next page without the viewer moving
    /// it — when the end is already in view: there is more, the last ask did
    /// not fail (a failed one waits for the viewer, or every render would
    /// ask again at once), and the empty pages in a row are within bounds.
    public var canPageOnItsOwn: Bool {
        hasMore && lastAskError == nil && emptyPagesInARow < Self.maxEmptyPagesWithNothingShown
    }

    public init(
        repository: any SuggestionsProviding,
        router: (any Router)? = nil,
        limit: Int = 20,
        pageLimit: Int = SocialConnectionsRepository.suggestionLimit
    ) {
        self.repository = repository
        self.router = router
        self.limit = limit
        self.pageLimit = max(pageLimit, 1)
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

    /// The end of the list came into view: the next page, if there is one
    /// and none is already on its way. Appended, never reordering what is
    /// shown; a failure keeps the cursor, and the next approach asks again.
    ///
    /// ⚠️ **THE SLOT IS FREED BEFORE THE ROWS ARE EMITTED** — rows that land
    /// wholly on screen ask again from `willDisplay`, and a slot still held
    /// would turn that away (`paging-slot-before-render`, #594).
    public func loadMore() {
        guard let token = nextPageToken, load == nil, loadingMore == nil else { return }
        let current = generation
        let size = pageLimit
        let known = Set(accounts.map(\.id))
        loadingMore = Task { [weak self] in
            guard let self else { return }
            let walked: Walk
            do {
                walked = try await self.pages(after: token, size: size, known: known, upTo: Self.maxEmptyPagesInARow)
            } catch {
                // A reload replaced the list meanwhile, and freed the slot.
                guard current == self.generation else { return }
                self.loadingMore = nil
                // The footer stops turning on the emit; the next approach
                // asks again from the same cursor.
                self.lastAskError = error
                self.emit()
                return
            }
            guard current == self.generation else { return }
            self.loadingMore = nil
            self.lastAskError = nil
            self.adopt(walked)
            let held = Set(self.accounts.map(\.id))
            let fresh = walked.page.accounts.filter { !held.contains($0.id) }
            self.laterPageIDs.formUnion(fresh.map(\.id))
            self.accounts += fresh
            self.emit()
        }
    }

    /// What one walk of pages brought: the rows, the next cursor, and how
    /// many of its pages added nothing.
    private struct Walk {
        let page: SuggestionsPage
        let emptyPages: Int
    }

    /// The page `token` starts (nil: the first) and, while it adds nothing
    /// `known` lacks and still carries a token, the ones after it — at most
    /// `maxPages`. Answers the rows they add, and where the next page starts.
    private func pages(after token: String?, size: Int, known: Set<ProfileID>, upTo maxPages: Int) async throws -> Walk {
        var cursor = token
        var seen = known
        var fresh: [SuggestedAccount] = []
        var emptyPages = 0
        for _ in 0..<maxPages {
            let page = try await repository.suggestions(limit: size, after: cursor)
            // A profile can sit on both sides of a page boundary: the first
            // place it took is kept.
            fresh = page.accounts.filter { seen.insert($0.id).inserted }
            cursor = page.nextPageToken
            guard fresh.isEmpty else { break }
            emptyPages += 1
            guard cursor != nil else { break }
        }
        return Walk(page: SuggestionsPage(accounts: fresh, nextPageToken: cursor), emptyPages: emptyPages)
    }

    /// A walk's cursor and its count of pages that added nothing.
    private func adopt(_ walked: Walk) {
        nextPageToken = walked.page.nextPageToken
        emptyPagesInARow = walked.page.accounts.isEmpty ? emptyPagesInARow + walked.emptyPages : 0
    }

    private func reload() {
        load?.cancel()
        loadingMore?.cancel()
        loadingMore = nil
        generation += 1
        let current = generation
        let size = limit
        load = Task { [weak self] in
            guard let self else { return }
            do {
                // Walked on until a row or the end: before any row, nothing
                // on screen can reach the end to ask.
                let first = try await self.pages(
                    after: nil, size: size, known: [], upTo: Self.maxEmptyPagesWithNothingShown
                )
                guard current == self.generation else { return }
                self.load = nil
                self.lastAskError = nil
                self.adopt(firstPage: first)
                self.emit()
            } catch {
                guard current == self.generation else { return }
                self.load = nil
                if error is CancellationError { return }
                if case .content = self.phase {} else {
                    // "You're offline" when that is why (#794).
                    self.phase = .failed(message: FailureCopy.message(for: error, fallback: "Couldn't load suggestions."))
                }
            }
        }
    }

    /// A first page landing: the list — or, with later pages on screen, the
    /// first page's rows replaced and the later ones kept below it, with the
    /// cursor past them.
    ///
    /// ⚠️ The trade-off of keeping them: a later-page row the server would
    /// now leave out (followed elsewhere, gone private) stays until the next
    /// full load, and the ranking below the first page is the one it had
    /// when it was read — better than taking rows back from under the viewer.
    private func adopt(firstPage walked: Walk) {
        let page = walked.page
        guard !laterPageIDs.isEmpty else {
            accounts = page.accounts
            emptyPagesInARow = 0
            adopt(walked)
            return
        }
        let fresh = Set(page.accounts.map(\.id))
        let kept = accounts.filter { laterPageIDs.contains($0.id) && !fresh.contains($0.id) }
        laterPageIDs = Set(kept.map(\.id))
        accounts = page.accounts + kept
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
    ///
    /// ⚠️ ONE CHANGE IN FLIGHT PER PROFILE (#802). A double tap used to send a
    /// follow AND an unfollow, racing on the wire, with the row showing
    /// whichever flip came last — and a failed one rolled back silently. A tap
    /// while that profile's change is on its way is ignored, and a refusal
    /// rolls back AND says so through `onFollowFailure`.
    public func toggleFollow(_ id: ProfileID) {
        guard !followsInFlight.contains(id) else { return }
        followsInFlight.insert(id)
        let wasFollowing = following.contains(id)
        following.formSymmetricDifference([id])
        emit()
        let handle = accounts.first { $0.id == id }?.handle
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
                self.onFollowFailure?(Self.followFailureMessage(handle: handle, unfollow: wasFollowing))
            }
            self.followsInFlight.remove(id)
        }
    }

    /// A refused follow or unfollow, already rolled back on the row: the
    /// words for a failure toast (#802).
    public var onFollowFailure: ((String) -> Void)?

    /// Short, no period — the toast's rule.
    nonisolated static func followFailureMessage(handle: String?, unfollow: Bool) -> String {
        let verb = unfollow ? "unfollow" : "follow"
        guard let handle, !handle.isEmpty else { return "Couldn't \(verb)" }
        return "Couldn't \(verb) @\(handle)"
    }

    /// Profiles whose follow change is on its way to the server.
    private var followsInFlight: Set<ProfileID> = []

    /// Hides a suggestion for the session. No wire contract exists for
    /// "not interested", so the suppression is local — and honest about it:
    /// it does not survive relaunch.
    public func dismiss(_ id: ProfileID) {
        dismissed.insert(id)
        emit()
    }

    public func isFollowing(_ id: ProfileID) -> Bool { following.contains(id) }

    /// ⚠️ **NO ROW SHOWN IS NOT "EMPTY" WHILE THE TOKEN SAYS MORE.** A first
    /// load past its empty pages, or a list the viewer dismissed row by row,
    /// has no row left to reach the end and ask — so it asks here, waiting
    /// on the skeleton, until a row comes or the empty pages run out
    /// (`maxEmptyPagesWithNothingShown`). A failed ask is said, with its
    /// retry, rather than asked again at once.
    private func emit() {
        let visible = accounts.filter { !dismissed.contains($0.id) }
        guard !visible.isEmpty else {
            if canPageOnItsOwn {
                if phase != .loading { phase = .loading }
                loadMore()
            } else if hasMore, let lastAskError {
                phase = .failed(message: FailureCopy.message(for: lastAskError, fallback: "Couldn't load suggestions."))
            } else {
                phase = .empty
            }
            return
        }
        phase = .content(visible.map {
            SuggestionDisplayModel(account: $0, isFollowing: following.contains($0.id))
        })
    }
}
