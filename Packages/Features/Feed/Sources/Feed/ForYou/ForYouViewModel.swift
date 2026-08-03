import Foundation
import PostGrid

/// Drives the For You grid: one accumulated corpus, three format pages
/// computed from it, and a discovery ordering applied across all of them.
///
/// The pager shows neighbouring pages mid-swipe, so this always answers for
/// all three formats at once — the same rule the profile gallery follows.
@MainActor
public final class ForYouViewModel {
    public nonisolated enum PageState: Equatable, Sendable {
        case loading
        case content([GalleryPost])
        /// The combination has nothing to show; `message` names it so the
        /// blank page reads intentional, not broken.
        case empty(message: String)
        case failed(message: String)
    }

    public nonisolated struct Snapshot: Equatable, Sendable {
        public var activity: PageState
        public var media: PageState
        public var short: PageState

        public func state(for format: GalleryFilter.Format) -> PageState {
            switch format {
            case .activity: activity
            case .media: media
            case .short: short
            }
        }
    }

    public var onSnapshotChange: ((Snapshot) -> Void)?
    /// Fires when a NEXT-PAGE fetch starts and again when it settles.
    ///
    /// Separate from `onSnapshotChange` on purpose: a page landing publishes a
    /// snapshot, but a page *starting* publishes nothing, and the grid's footer
    /// spinner needs the leading edge. Also distinct from the first load, which
    /// the pages already render as skeletons.
    public var onPagingChange: ((Bool) -> Void)?
    /// Fires when a load settles, however it settled — the view closes out its
    /// refresh control on this rather than inferring it from a snapshot that
    /// may be identical to the last one.
    public var onLoadSettled: (() -> Void)?
    /// The per-format "new since you last looked" counts, for the tab
    /// capsule's badges.
    ///
    /// Published separately from the snapshot even though both are recomputed
    /// in `publish()`: a badge changes a segment's pinned width and moves the
    /// lens, so the bar has to be told explicitly rather than left to infer it
    /// from content it never sees.
    public var onUnreadChange: (([GalleryFilter.Format: Int]) -> Void)?

    private let repository: any ForYouProviding
    /// Persists the format tab only. The discovery source is session state by
    /// design: it is one screen, the tab coordinator retains it for the whole
    /// session, and a stale "Trending" from three days ago is a worse landing
    /// than the default.
    private let preferences: GalleryPreferences?
    /// The badge watermarks. Owned here rather than by the view controller
    /// because every input it needs — the loaded corpus, the active format —
    /// is already this type's, and a badge derived anywhere else would be a
    /// second copy of the same fact.
    private let unreadStore: ForYouUnreadStore

    public private(set) var format: GalleryFilter.Format = .activity
    public private(set) var source: DiscoverySource = .trending

    /// Everything loaded so far, **in the order it is displayed**. nil = the
    /// first page is still in flight (pages report loading); a failure records
    /// instead.
    ///
    /// The ordering is applied when content ARRIVES, not on every read, and an
    /// appended page is ordered among itself and added to the end. Re-sorting
    /// the whole corpus on every page would renumber tiles the viewer is
    /// already looking at — caught in-sim as the grid visibly rearranging half
    /// a second after a hero had landed on one of them, because the tab bar
    /// coming back nudged the scroll view and that asked for the next page.
    ///
    /// The cost is stated plainly: "trending" ranks within each page rather
    /// than across the whole loaded corpus, so a later page's runaway hit sits
    /// below an earlier page's modest one. That is the honest trade for a grid
    /// that holds still, and it is moot once ranking is the server's job (see
    /// `dev/BACKEND_GAPS.md` §14). A source change re-sorts everything, because
    /// there the viewer asked for exactly that.
    private var corpus: [GalleryPost]?
    private var failure: String?
    private var nextPageToken: String?
    private var load: Task<Void, Never>?
    private var pageLoad: Task<Void, Never>?

    public init(
        repository: any ForYouProviding,
        preferences: GalleryPreferences? = nil,
        unreadStore: ForYouUnreadStore = ForYouUnreadStore()
    ) {
        self.repository = repository
        self.preferences = preferences
        self.unreadStore = unreadStore
        if let preferences {
            format = preferences.format
        }
    }

    public func viewDidLoad() {
        loadFirstPage(reset: false)
    }

    /// Pull-to-refresh: drops the corpus and the cursor and starts over.
    public func refresh() {
        loadFirstPage(reset: true)
    }

    /// Where the user is — a tab tap or a settled swipe. Pure state (every
    /// page is always computed), persisted for the next launch.
    ///
    /// Landing on a tab is also *reading* it, so this clears that tab's badge.
    public func setFormat(_ format: GalleryFilter.Format) {
        self.format = format
        preferences?.format = format
        // Arriving on a tab IS reading it — and this is the one path a person
        // drives, so it is also where a debug-forced badge is allowed to clear.
        unreadStore.markSeen(format, in: posts(for: format), clearingOverride: true)
        publishUnread()
    }

    /// The ordering modifier: recomputes every page locally, no round trip.
    public func setSource(_ source: DiscoverySource) {
        guard self.source != source else { return }
        self.source = source
        // The one place the whole corpus legitimately reorders.
        corpus = corpus.map(source.ordering)
        publish()
    }

    /// Called as the active page nears its end. A no-op when a page is
    /// already in flight, when the corpus is exhausted, or before the first
    /// page has landed.
    public func loadNextPageIfNeeded() {
        guard pageLoad == nil, load == nil, corpus != nil, let token = nextPageToken else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[foryou-page] fetch after=\(token)")
        }
        #endif
        pageLoad = Task { [weak self] in
            guard let self else { return }
            defer {
                self.pageLoad = nil
                self.onPagingChange?(false)
            }
            guard let page = try? await repository.page(after: token), !Task.isCancelled else { return }
            // Append, never reorder: the new page is ranked among ITSELF and
            // added to the end, so a page landing cannot renumber what is
            // already on screen.
            //
            // Deduplicated against everything already loaded, as a second
            // line of defense behind the announcement ordering below: a
            // re-served row is never trusted into the corpus, whoever serves
            // it — a re-entrant fetch like the one found here, or a real
            // server re-serving a boundary row after the timeline grew under
            // its cursor. A repeated id is not cosmetic — every id-keyed
            // structure downstream assumes uniqueness, and the first one (the
            // snap feed seeding `Dictionary(uniqueKeysWithValues:)` from a
            // tapped tile's slice) took the whole app down when a duplicate
            // reached it.
            let existing = Set((corpus ?? []).map(\.id))
            let fresh = page.posts.filter { !existing.contains($0.id) }
            #if DEBUG
            if fresh.count != page.posts.count,
               ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                let repeated = page.posts.filter { existing.contains($0.id) }.map(\.id.rawValue)
                print("[foryou-page] token=\(token) re-served \(repeated)")
            }
            #endif
            corpus = (corpus ?? []) + source.ordering(fresh)
            nextPageToken = page.nextPageToken
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[foryou-page] appended fresh=\(fresh.count) corpus=\(corpus?.count ?? 0) next=\(page.nextPageToken ?? "nil")")
            }
            #endif
            publish()
            onLoadSettled?()
        }
        // Announced only past the guard (the common case is a scroll reaching
        // the end of an exhausted corpus, and a spinner for a fetch that never
        // starts would sit there forever) — and only AFTER `pageLoad` is
        // assigned. Showing the footer runs a layout pass, a layout pass can
        // fire `onNearEnd`, and a re-entrant call arriving before the
        // assignment passed the `pageLoad == nil` guard and started a SECOND
        // fetch with the same token. Measured live, triggered by a hero
        // flight's staging layout: two `page(after: 20)` fetches back to
        // back, the whole second page appended twice, and the next tile tap
        // trapping on the duplicate id.
        onPagingChange?(true)
    }

    private func loadFirstPage(reset: Bool) {
        if reset {
            load?.cancel()
            if pageLoad != nil {
                pageLoad?.cancel()
                // A cancelled task's `defer` does not run, so the footer would
                // be left spinning for a fetch that was thrown away.
                onPagingChange?(false)
            }
            pageLoad = nil
            corpus = nil
            failure = nil
            nextPageToken = nil
        }
        guard load == nil else { return }
        publish() // all pages report loading
        load = Task { [weak self] in
            guard let self else { return }
            defer { self.load = nil }
            do {
                let page = try await repository.firstPage()
                guard !Task.isCancelled else { return }
                corpus = source.ordering(page.posts)
                failure = nil
                nextPageToken = page.nextPageToken
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print("[foryou-page] first count=\(page.posts.count) next=\(page.nextPageToken ?? "nil") reset=\(reset)")
                }
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                failure = "Couldn't load. Pull to retry."
            }
            publish()
            onLoadSettled?()
        }
    }

    /// The corpus under the active ordering and a given format — what a page
    /// renders, and the ordered set a tile tap seeds its feed from.
    public func posts(for format: GalleryFilter.Format) -> [GalleryPost] {
        // `corpus` is already in display order — see its note. Reading is a
        // pure filter, so nothing can reorder behind the viewer's back.
        format.filtering(corpus ?? [])
    }

    private func publish() {
        func page(_ format: GalleryFilter.Format) -> PageState {
            if let failure { return .failed(message: failure) }
            guard corpus != nil else { return .loading }
            let posts = posts(for: format)
            return posts.isEmpty ? .empty(message: Self.emptyMessage(format: format, source: source)) : .content(posts)
        }
        onSnapshotChange?(Snapshot(activity: page(.activity), media: page(.media), short: page(.short)))
        publishUnread()
    }

    /// Recomputes every tab's badge from the corpus in hand.
    ///
    /// The active tab's watermark is advanced FIRST, before anything is
    /// counted. The viewer is looking at that page, so a fetch landing under
    /// their eyes has been seen by definition — and advancing it here means the
    /// active tab reads zero through the same derivation as every other tab
    /// rather than being special-cased to it. It also means leaving the tab
    /// later cannot badge content that was on screen the whole time.
    private func publishUnread() {
        guard corpus != nil else { return }
        unreadStore.markSeen(format, in: posts(for: format))
        var counts: [GalleryFilter.Format: Int] = [:]
        for page in GalleryFilter.Format.allCases {
            counts[page] = unreadStore.count(for: page, in: posts(for: page))
        }
        onUnreadChange?(counts)
    }

    /// Names the empty combination so the blank page reads as an answer.
    nonisolated static func emptyMessage(format: GalleryFilter.Format, source: DiscoverySource) -> String {
        let what = switch format {
        case .activity: "activity"
        case .media: "media"
        case .short: "short posts"
        }
        // The source phrase sits in a different slot per case — "trending" and
        // "recent" qualify the noun, "from people you follow" trails it.
        return switch source {
        case .trending: "No trending \(what) yet."
        case .recent: "No recent \(what) yet."
        case .following: "No \(what) from people you follow yet."
        }
    }
}
