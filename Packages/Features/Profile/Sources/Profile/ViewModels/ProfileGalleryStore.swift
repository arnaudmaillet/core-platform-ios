import CoreModels
import CoreNetworking
import Foundation
import PostGrid

/// The profile gallery's source of truth (#846): the two corpora it reads
/// (the authored fetch that Posts and Reposts split, and the tagged fetch),
/// where each one's paging stands, why a page failed, the page on screen's
/// source, and the pages a snapshot is built from.
///
/// Pure state and derivation — no fetching, no tasks, no publishing. The view
/// model fetches and hands each answer here, then publishes `snapshot`; this
/// type decides what the answer means for every page. Testable on its own.
///
/// ⚠️ TILES ARE MEMOIZED PER (FORMAT, SOURCE). A render asks for the same
/// combination several times (each page's state, the empty-tab fill, the
/// paging loop's before/after count) and each ask used to re-filter both
/// corpora. The tiles are a pure function of the corpora and the tokens (the
/// All frontier reads them), so the memo is dropped whenever either changes
/// and can never answer for an older state.
@MainActor
final class ProfileGalleryStore {
    typealias PageState = ProfileViewModel.GalleryPageState

    /// The tray's format and the stored source; the view model persists it.
    var filter = GalleryFilter()
    /// The page on screen's source (`gallerySource`), on every profile (#772).
    var pageSource: GalleryFilter.Source = .posts

    /// The authored fetch (Posts + Reposts split it) and the tagged fetch,
    /// cached so selector/kind changes recompute locally without round trips.
    /// nil = in flight (page shows loading); a failure records instead.
    private(set) var authored: [GalleryPost]? { didSet { tileMemo.removeAll() } }
    private(set) var tagged: [GalleryPost]? { didSet { tileMemo.removeAll() } }
    private(set) var authoredFailed = false
    private(set) var taggedFailed = false
    /// Why each first page failed, kept beside the flags (#794): the fetches
    /// used to be `try?`, so a failed page could only say "Couldn't load",
    /// offline or not. Nil when it did not come from the network.
    private(set) var authoredFailure: NetworkFailure?
    private(set) var taggedFailure: NetworkFailure?
    /// Where each corpus's next page starts; nil when it has no more, or
    /// before its first page answered (#634).
    private(set) var authoredToken: String? { didSet { tileMemo.removeAll() } }
    private(set) var taggedToken: String? { didSet { tileMemo.removeAll() } }
    /// Pages beyond the first are loaded: a revalidation merges its first
    /// page over them rather than cutting the corpus back to one page.
    private(set) var authoredHasLaterPages = false
    private(set) var taggedHasLaterPages = false
    /// The last next-page round failed: the grid stops asking on its own
    /// (an empty tab would otherwise retry in a tight loop) until the viewer
    /// approaches the end again, or pulls to refresh.
    private(set) var isPausedByFailure = false
    /// Why that round failed (#794), for the tab it leaves empty.
    private(set) var moreFailure: NetworkFailure?

    /// The saved pile's tiles, once hydrated. Held because the pile can change
    /// while the screen is up (a post unsaved from the feed underneath) and the
    /// snapshot is rebuilt from parts.
    var saved: PageState = .empty(message: "Nothing saved yet.")

    private struct TileKey: Hashable {
        let format: GalleryFilter.Format
        let source: GalleryFilter.Source
    }

    private var tileMemo: [TileKey: [GalleryPost]] = [:]

    /// Internal for tests: how many times the corpora were actually filtered.
    private(set) var tileComputations = 0

    // MARK: - Mutations

    /// Forgets both corpora — another profile, or a load that starts over.
    /// A reset lands on Posts — the only page shown while the sources reload
    /// (#742) — so the source goes back with it (#772).
    func reset() {
        pageSource = .posts
        authored = nil
        tagged = nil
        authoredFailed = false
        taggedFailed = false
        authoredFailure = nil
        taggedFailure = nil
        authoredToken = nil
        taggedToken = nil
        authoredHasLaterPages = false
        taggedHasLaterPages = false
    }

    /// The viewer asks again (an approach to the end, a load): a failed round
    /// stops holding the grid back.
    func resumePaging() {
        isPausedByFailure = false
        moreFailure = nil
    }

    /// Both first pages answered. The two fetches fail independently: one
    /// page family degrading must not blank the other. Each keeps WHY it
    /// failed (#794).
    ///
    /// A revalidation over pages beyond the first merges into them — and,
    /// failing, leaves them as they are rather than blanking them.
    func applyFirstPages(
        authored authoredPage: GalleryPage?, authoredFailure: NetworkFailure?,
        tagged taggedPage: GalleryPage?, taggedFailure: NetworkFailure?
    ) {
        if authoredHasLaterPages, let shown = authored {
            if let authoredPage { authored = Self.mergingGallery(firstPage: authoredPage.posts, over: shown) }
        } else {
            authored = authoredPage?.posts
            authoredFailed = authoredPage == nil
            self.authoredFailure = authoredFailure
            authoredToken = authoredPage?.nextPageToken
        }
        if taggedHasLaterPages, let shown = tagged {
            if let taggedPage { tagged = Self.mergingGallery(firstPage: taggedPage.posts, over: shown) }
        } else {
            tagged = taggedPage?.posts
            taggedFailed = taggedPage == nil
            self.taggedFailure = taggedFailure
            taggedToken = taggedPage?.nextPageToken
        }
    }

    /// One next-page round answered, for the `tokens` it asked with. A page
    /// is taken only while its corpus still stands at the token it followed;
    /// a failure (or a token asked with no answer) pauses the paging.
    ///
    /// Returns whether the round failed.
    @discardableResult
    func applyNextPages(
        tokens: (authored: String?, tagged: String?),
        authored authoredResult: Result<GalleryPage, any Error>?,
        tagged taggedResult: Result<GalleryPage, any Error>?
    ) -> Bool {
        var failed = false
        var failure: NetworkFailure?
        if let token = tokens.authored {
            switch authoredResult {
            case .success(let page)?:
                if authoredToken == token {
                    authoredToken = page.nextPageToken
                    if let grown = Self.appending(page.posts, to: authored) {
                        authored = grown
                        authoredHasLaterPages = true
                    }
                }
            case .failure(let error)?:
                failed = true
                failure = NetworkFailure.of(error)
            case nil:
                failed = true
            }
        }
        if let token = tokens.tagged {
            switch taggedResult {
            case .success(let page)?:
                if taggedToken == token {
                    taggedToken = page.nextPageToken
                    if let grown = Self.appending(page.posts, to: tagged) {
                        tagged = grown
                        taggedHasLaterPages = true
                    }
                }
            case .failure(let error)?:
                failed = true
                failure = Self.likelierCause(failure, NetworkFailure.of(error))
            case nil:
                failed = true
            }
        }
        if failed {
            isPausedByFailure = true
            moreFailure = failure
        }
        return failed
    }

    /// A post deleted by the viewer leaves the authored corpus.
    func removeAuthoredPost(_ postID: PostID) {
        authored?.removeAll { $0.id == postID }
    }

    // MARK: - Derived

    /// The tokens the active source reads through: authored for Posts and
    /// Reposts, tagged for Tagged, both for All.
    func tokensToFollow(
        _ source: GalleryFilter.Source? = nil
    ) -> (authored: String?, tagged: String?) {
        let source = source ?? pageSource
        return (
            source == .tagged ? nil : authoredToken,
            source == .all || source == .tagged ? taggedToken : nil
        )
    }

    /// Whether `source` has every page it will get.
    func isComplete(_ source: GalleryFilter.Source? = nil) -> Bool {
        tokensToFollow(source) == (nil, nil)
    }

    /// The tiles a tab shows under the active source.
    ///
    /// ⚠️ ALL STOPS AT THE FRONTIER. It merges two corpora that page on their
    /// own; a post older than what one of them has reached may still be
    /// followed by newer ones from it, and showing it now would have the next
    /// page land ABOVE tiles already on screen. So All shows only down to the
    /// later of the unfinished corpora's oldest posts — where both are known
    /// — and every page from then on only adds below.
    func tiles(
        _ format: GalleryFilter.Format, source: GalleryFilter.Source? = nil
    ) -> [GalleryPost] {
        let source = source ?? pageSource
        let key = TileKey(format: format, source: source)
        if let memo = tileMemo[key] { return memo }
        tileComputations += 1
        let filter = GalleryFilter(format: format, source: source)
        var tiles = filter.tiles(authored: authored ?? [], tagged: tagged ?? [])
        if source == .all, let frontier = allFrontier {
            tiles = tiles.filter { $0.publishedAtMS >= frontier }
        }
        tileMemo[key] = tiles
        return tiles
    }

    /// The later of the unfinished corpora's oldest loaded posts; nil when
    /// neither has more to load.
    private var allFrontier: Int64? {
        [(authoredToken, authored), (taggedToken, tagged)]
            .compactMap { token, cache in token == nil ? nil : cache?.map(\.publishedAtMS).min() }
            .max()
    }

    /// One page's state. Which fetches a source depends on: All needs both,
    /// Tagged its own, Posts/Reposts the authored one. A page is
    /// loading/failed only when a fetch it actually reads is.
    func page(
        _ format: GalleryFilter.Format, _ source: GalleryFilter.Source, emptyMessage: String? = nil
    ) -> PageState {
        let readsAuthored = source != .tagged
        let readsTagged = source == .all || source == .tagged
        if (readsAuthored && authoredFailed) || (readsTagged && taggedFailed) {
            let failure = Self.likelierCause(
                readsAuthored && authoredFailed ? authoredFailure : nil,
                readsTagged && taggedFailed ? taggedFailure : nil
            )
            return .failed(message: Self.galleryFailureMessage(failure))
        }
        if (readsAuthored && authored == nil) || (readsTagged && tagged == nil) {
            return .loading
        }
        let filter = GalleryFilter(format: format, source: source)
        let tiles = tiles(format, source: source)
        guard tiles.isEmpty else { return .content(tiles) }
        // Nothing YET is not nothing: with pages still to load, a tab
        // that none of the loaded posts fill is still loading — or, its
        // last page having failed, says so.
        if isComplete(source) {
            return .empty(message: emptyMessage ?? Self.emptyMessage(for: filter))
        }
        return isPausedByFailure
            ? .failed(message: Self.galleryFailureMessage(moreFailure))
            : .loading
    }

    /// Every page at once, from the caches.
    ///
    /// Three pages, three sources (#696), on every profile since #772; the
    /// media "View all" pushes is the page on screen's. The empty pages let
    /// their tab speak (`ProfileTab.emptyState`), Posts saying what it
    /// holds here. Saved is your own profile's alone.
    func snapshot(isOwnProfile: Bool) -> ProfileViewModel.GallerySnapshot {
        ProfileViewModel.GallerySnapshot(
            activity: page(.activity, .posts, emptyMessage: "Posts will appear here."),
            media: page(.media, pageSource),
            isComplete: isComplete(.posts),
            saved: isOwnProfile ? saved : .empty(message: ""),
            reposts: page(.activity, .reposts, emptyMessage: ""),
            tagged: page(.activity, .tagged, emptyMessage: ""),
            repostsComplete: isComplete(.reposts),
            taggedComplete: isComplete(.tagged)
        )
    }

    // MARK: - Pure helpers

    /// Of two fetches' failures, the one worth naming: offline first (the
    /// one cause the viewer can fix), then a timeout, then either.
    nonisolated static func likelierCause(_ first: NetworkFailure?, _ second: NetworkFailure?) -> NetworkFailure? {
        if first == .offline || second == .offline { return .offline }
        if first == .timeout || second == .timeout { return .timeout }
        return first ?? second
    }

    /// A failed gallery page's words (#794): "You’re offline…" or "That took
    /// too long…" when that is why; otherwise the pull it offers, since the
    /// gallery is what the pull refreshes.
    nonisolated static func galleryFailureMessage(_ failure: NetworkFailure?) -> String {
        FailureCopy.message(for: failure, fallback: "Couldn't load. Pull to retry.")
    }

    /// `shown` with the page's new posts below it, or nil when it brings
    /// none — a post can sit on both sides of a page boundary.
    nonisolated static func appending(_ page: [GalleryPost], to shown: [GalleryPost]?) -> [GalleryPost]? {
        let known = Set((shown ?? []).map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        return fresh.isEmpty ? nil : (shown ?? []) + fresh
    }

    /// A revalidated first page over a corpus that runs past it: the page
    /// replaces every post at least as recent as its oldest, and every older
    /// post stays. Both corpora page newest first, so a post missing from the
    /// fresh page either slid down (older: kept) or went away (newer:
    /// dropped). Pure, for tests.
    nonisolated static func mergingGallery(firstPage: [GalleryPost], over shown: [GalleryPost]) -> [GalleryPost] {
        guard let oldest = firstPage.map(\.publishedAtMS).min() else { return shown }
        let fresh = Set(firstPage.map(\.id))
        return firstPage + shown.filter { !fresh.contains($0.id) && $0.publishedAtMS < oldest }
    }

    /// Names the empty combination so the blank page reads as an answer.
    ///
    /// ⚠️ Empty means "nothing to add", not "nothing to say". Unfiltered, this
    /// page is empty because the profile has nothing of that kind — which the
    /// TAB already says better than a generated sentence can, with a glyph and
    /// a headline. It is the FILTER that this knows and the tab cannot: "no
    /// media in reposts" explains why the page is narrower than the profile,
    /// and that is worth overriding the tab's own line for.
    nonisolated static func emptyMessage(for filter: GalleryFilter) -> String {
        guard filter.source != .all else { return "" }
        // Posts (#631) is every kind, so the source alone names what is
        // missing: "No reposts yet", not "No activity in reposts yet".
        if filter.format == .activity {
            return switch filter.source {
            case .all, .posts: "No posts yet."
            case .reposts: "No reposts yet."
            case .tagged: "No tagged posts yet."
            }
        }
        let format = switch filter.format {
        case .activity: "posts"
        case .media: "media"
        case .short: "short posts"
        }
        let source = switch filter.source {
        case .all: ""
        case .posts: " in posts"
        case .reposts: " in reposts"
        case .tagged: " in tagged posts"
        }
        return "No \(format)\(source) yet."
    }
}
