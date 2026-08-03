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

    /// The tabs this screen has, in the pager's order. Stated here rather than
    /// read from `ForYouPagerView.pageOrder` because that static is `@MainActor`
    /// by inference (a `UIView` subclass's are) and this type answers off it in
    /// tests; `ForYouTabOrderTests` pins the two together.
    nonisolated static let tabs: [GalleryFilter.Format] = [.media, .activity]

    /// Where the screen opens. Discover — the media grid — is the landing tab.
    nonisolated static let defaultFormat: GalleryFilter.Format = .media

    public private(set) var format: GalleryFilter.Format = ForYouViewModel.defaultFormat
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
        // Two conditions, and both were learned the hard way.
        //
        // `hasStoredFormat` — because `preferences.format` answers `.activity`
        // when NOTHING has been stored, which is indistinguishable from a
        // viewer who chose Following. Without this every fresh install opened
        // on Following rather than on Discover (seen in-sim after a clean
        // reinstall, which is the only way to see it at all).
        //
        // `tabs.contains` — because an install that last sat on Short has a
        // stored format this screen no longer has a tab for, and paging to a
        // page the pager does not own would leave the capsule pointing at
        // nothing.
        if let preferences, preferences.hasStoredFormat, Self.tabs.contains(preferences.format) {
            format = preferences.format
        }
        #if DEBUG
        // The mock stages unread on FOLLOWING, and the tab you are looking at
        // can never have unread by construction — everything on it has been
        // seen. So the demo lands on Discover, which is what makes the badge it
        // stages honest rather than a contradiction the code has to special-
        // case. Not persisted: this is a launch argument's opinion, not the
        // viewer's.
        if ProcessInfo.processInfo.arguments.contains("-foryou-mock-new-activity"),
           format == Self.badgedTab {
            format = Self.defaultFormat
        }
        #endif
    }

    /// The tab that carries the unread badge: Following, where new posts from
    /// the accounts you follow land. Discover is a ranked surface with no
    /// "since you last looked" to speak of, so it is not badged.
    nonisolated static let badgedTab: GalleryFilter.Format = .activity

    public func viewDidLoad() {
        loadFirstPage(reset: false)
    }

    /// Pull-to-refresh: drops the corpus and the cursor and starts over.
    public func refresh() {
        rearmMockNewActivity()
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
        applyMockNewActivityIfNeeded()
        unreadStore.markSeen(format, in: posts(for: format))
        // Only the tabs this screen HAS, not every case of the shared enum —
        // `.short` has no tab here, and publishing a count for it would invite
        // a badge with nowhere to sit.
        var counts: [GalleryFilter.Format: Int] = [:]
        for page in Self.tabs {
            // Discover carries no badge by product decision, not by accident:
            // a ranked feed has no "since you last looked" to count against.
            counts[page] = page == Self.badgedTab
                ? unreadStore.count(for: page, in: posts(for: page))
                : 0
        }
        onUnreadChange?(counts)
    }

    #if DEBUG
    /// `-foryou-mock-new-activity [n]` (n defaults to 3): back-dates the
    /// Activity watermark so the n newest activity posts read as new.
    ///
    /// Armed once per LOAD, not once per publish — every page that lands would
    /// otherwise re-back-date and the badge would never settle. A pull-to-refresh
    /// re-arms it, which is the point: pull, and three new things are waiting.
    ///
    /// The badge it produces is a real derived count, so tapping Activity clears
    /// it through `markSeen` exactly as a genuine one would.
    private var hasArmedMockActivity = false

    private func applyMockNewActivityIfNeeded() {
        guard !hasArmedMockActivity else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-foryou-mock-new-activity") else { return }
        let count = position + 1 < arguments.count ? Int(arguments[position + 1]) ?? 3 : 3
        hasArmedMockActivity = true
        // Belt and braces: `init` already moves the landing tab off Following
        // for exactly this reason, so reaching here on Following means someone
        // navigated there — in which case the posts really have been seen and
        // staging them as new would be a lie the badge tells.
        guard format != Self.badgedTab else { return }
        unreadStore.stageUnread(count, for: Self.badgedTab, in: posts(for: Self.badgedTab))
    }

    /// Re-arms the mock so a pull produces a fresh badge.
    private func rearmMockNewActivity() {
        hasArmedMockActivity = false
    }
    #else
    private func applyMockNewActivityIfNeeded() {}
    private func rearmMockNewActivity() {}
    #endif

    /// Names the empty combination so the blank page reads as an answer.
    nonisolated static func emptyMessage(format: GalleryFilter.Format, source: DiscoverySource) -> String {
        let what = switch format {
        case .activity: "activity"
        case .media: "media"
        case .short: "short posts"
        }
        // Both surviving sources are adjectives that qualify the noun. The
        // removed `.following` case was the one that needed a trailing phrase
        // ("...from people you follow"), which is why this used to have two
        // shapes; if a source that is not an adjective returns, it will need
        // its own slot again rather than being forced into this one.
        return switch source {
        case .trending: "No trending \(what) yet."
        case .recent: "No recent \(what) yet."
        }
    }
}
