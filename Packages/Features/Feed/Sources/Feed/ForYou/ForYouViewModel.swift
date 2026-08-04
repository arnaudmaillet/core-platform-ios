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
        /// The combination has nothing to show, said in two parts so the page
        /// reads intentional rather than broken.
        case empty(EmptyState)
        case failed(message: String)
    }

    /// An empty page, in the two pieces the viewer needs separately.
    ///
    /// The split is not cosmetic. The TITLE is the finding — "No activity yet"
    /// — and is true regardless of how the viewer got here. The SUBTITLE is the
    /// reason the page might be narrower than they expected, and it is the only
    /// part that tells them there is something they can change. Running them
    /// into one sentence made the actionable half look like punctuation.
    public nonisolated struct EmptyState: Equatable, Sendable {
        public let title: String
        /// Absent when nothing is narrowing the page — an unfiltered surface
        /// with no content has no explanation to offer, and inventing one would
        /// be noise.
        public let subtitle: String?

        public init(title: String, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
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
    /// Every context's count, for the menu that offers them.
    ///
    /// The menu names five modes, and the whole point of putting a number
    /// beside each is that a viewer can see where the activity is WITHOUT
    /// switching to find out. So this answers for all of them at once, against
    /// the same session baseline the active one is counted against — the
    /// selected mode's entry and the tab badge are then the same number
    /// arriving by the same route.
    public var onContextCountsChange: (([ContentContext: Int]) -> Void)?
    /// How many of the badged tab's posts lead the list as "new", so the page
    /// can put them under their own header.
    ///
    /// The SAME number the badge shows, published from the same place, because
    /// "the first section and the badge agree" is not a thing worth keeping in
    /// step — it is a thing worth making true once.
    public var onNewCountChange: ((Int) -> Void)?
    /// Fires immediately BEFORE a publish whose corpus was re-derived rather
    /// than extended — a lens change or a re-ordering.
    ///
    /// ⚠️ The pages cannot work this out for themselves, and trying to crashed
    /// the app. A page treats "same posts plus some new ones" as an append and
    /// expresses it as an insert, which is what keeps the mosaic from
    /// reshuffling when Trending re-ranks a landing page. Widening the lens
    /// produces exactly that shape — every Work post is still there, plus
    /// thirty more — but it is NOT an append: the newcomers belong all through
    /// the list, not after it. Inserted at the end they mis-order the timeline,
    /// and when the sectioning moves in the same pass `performBatchUpdates`
    /// takes the whole app down with an inconsistency exception.
    ///
    /// So the distinction is stated by the only type that knows which it is.
    public var onCorpusReset: (() -> Void)?

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
    /// Persists the context lens. Optional so a test can run without touching
    /// the simulator's defaults.
    private let contextStore: ContentContextStore?

    /// The tabs this screen has, in the pager's order. Stated here rather than
    /// read from `ForYouPagerView.pageOrder` because that static is `@MainActor`
    /// by inference (a `UIView` subclass's are) and this type answers off it in
    /// tests; `ForYouTabOrderTests` pins the two together.
    nonisolated static let tabs: [GalleryFilter.Format] = [.media, .activity]

    /// Where the screen opens. Discover — the media grid — is the landing tab.
    nonisolated static let defaultFormat: GalleryFilter.Format = .media

    public private(set) var format: GalleryFilter.Format = ForYouViewModel.defaultFormat
    public private(set) var source: DiscoverySource = .trending
    /// The active lens. Restored from the store at init, so the surface opens
    /// where the viewer left it.
    public private(set) var context: ContentContext = .all

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
    /// The instant this session counts from, frozen the first time a corpus
    /// lands and never moved again. See `ForYouSessionWatermark`.
    private var sessionWatermark: ForYouSessionWatermark?
    private var failure: String?
    private var nextPageToken: String?
    private var load: Task<Void, Never>?
    private var pageLoad: Task<Void, Never>?

    public init(
        repository: any ForYouProviding,
        preferences: GalleryPreferences? = nil,
        unreadStore: ForYouUnreadStore = ForYouUnreadStore(),
        contextStore: ContentContextStore? = nil
    ) {
        self.repository = repository
        self.preferences = preferences
        self.unreadStore = unreadStore
        self.contextStore = contextStore
        if let contextStore { context = contextStore.context }
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
        onCorpusReset?()
        publish()
    }

    /// The lens the whole surface is read through. Local, like the ordering —
    /// it narrows the corpus already in hand rather than asking for another.
    ///
    /// Both tabs move together, because the context is a statement about the
    /// surface rather than about one page of it.
    public func setContext(_ context: ContentContext) {
        guard self.context != context else { return }
        self.context = context
        contextStore?.context = context
        // The unread counts are derived from the VISIBLE corpus, so they have
        // to be republished with it: a tab whose new posts are all filtered out
        // is a tab with nothing new on it, and a count left over from the wider
        // context would be pointing at posts this context does not admit.
        //
        // A lens change RE-DERIVES the corpus rather than extending it, and the
        // pages have to be told before they see it — see `onCorpusReset`.
        onCorpusReset?()
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

    /// The corpus under the active ordering, context and format — what a page
    /// renders, and the ordered set a tile tap seeds its feed from.
    ///
    /// The CONTEXT is applied here, in the single read path, rather than by
    /// narrowing `corpus` when it changes. Two reasons, and the second is the
    /// one that matters: a stored corpus would have to be re-fetched to widen
    /// again (switching back to Entertainment would show only what the narrower
    /// lens had already admitted), and every derived answer in this type —
    /// page states, empty messages, unread counts, the feed a tile seeds —
    /// already comes through this method, so applying it once here is what
    /// makes "the context filters both tabs" true by construction rather than
    /// by remembering to filter in four places.
    public func posts(for format: GalleryFilter.Format) -> [GalleryPost] {
        // `corpus` is already in display order — see its note. Reading is a
        // pure filter, so nothing can reorder behind the viewer's back.
        format.filtering(context.filtering(corpus ?? []))
    }

    private func publish() {
        func page(_ format: GalleryFilter.Format) -> PageState {
            if let failure { return .failed(message: failure) }
            guard corpus != nil else { return .loading }
            let posts = posts(for: format)
            return posts.isEmpty
                ? .empty(Self.emptyState(format: format, source: source, context: context))
                : .content(posts)
        }
        // ⚠️ Counts FIRST, then content. The Following page splits its rows into
        // "New" and "Recent" using the count published here, so a page that
        // received content first would render one flat list and re-section
        // itself a moment later — a visible restructure on every load. Nothing
        // in `publishUnread` reads the snapshot, so the order is free.
        publishUnread()
        onSnapshotChange?(Snapshot(activity: page(.activity), media: page(.media), short: page(.short)))
    }

    /// What the badged tab counts against this session, frozen on first sight.
    ///
    /// Taken from the persisted cursor BEFORE this visit advances it — see
    /// `ForYouSessionWatermark`. Read against the UNFILTERED corpus on purpose:
    /// a baseline is an instant, not a subject, and freezing it while a narrow
    /// context happened to be selected would date the whole session from
    /// whatever that context's newest post was.
    private func sessionWatermark(against posts: [GalleryPost]) -> ForYouSessionWatermark? {
        if let sessionWatermark { return sessionWatermark }
        guard let baseline = unreadStore.sessionBaseline(for: Self.badgedTab, in: posts) else { return nil }
        let watermark = ForYouSessionWatermark(baselineMS: baseline)
        sessionWatermark = watermark
        return watermark
    }

    /// The badged tab's count under a given lens.
    private func newCount(in context: ContentContext) -> Int {
        guard let corpus, let watermark = sessionWatermark(against: Self.badgedTab.filtering(corpus)) else {
            return 0
        }
        return watermark.count(in: Self.badgedTab.filtering(context.filtering(corpus)))
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
        // The session's baseline is frozen here, BEFORE the visit advances the
        // persisted cursor — that ordering is the whole mechanism.
        let count = newCount(in: context)
        unreadStore.markSeen(format, in: posts(for: format))
        // Only the tabs this screen HAS, not every case of the shared enum —
        // `.short` has no tab here, and publishing a count for it would invite
        // a badge with nowhere to sit.
        var counts: [GalleryFilter.Format: Int] = [:]
        for page in Self.tabs {
            // Discover carries no badge by product decision, not by accident:
            // a ranked feed has no "since you last looked" to count against.
            // A forced count is `-foryou-badges` only, and overrides the
            // derivation for the BADGE alone — see `forcedCount`.
            counts[page] = page == Self.badgedTab
                ? (unreadStore.forcedCount(for: page) ?? count)
                : 0
        }
        onUnreadChange?(counts)
        onNewCountChange?(count)
        onContextCountsChange?(
            ContentContext.allCases.reduce(into: [:]) { result, lens in
                result[lens] = newCount(in: lens)
            }
        )
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
    nonisolated static func emptyState(
        format: GalleryFilter.Format,
        source: DiscoverySource,
        context: ContentContext = .all
    ) -> EmptyState {
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
        let title = switch source {
        case .trending: "No trending \(what) yet."
        case .recent: "No recent \(what) yet."
        }
        // A narrowed context is very often the REASON a page is empty, and a
        // blank screen that does not say so reads as a broken feed. Naming the
        // lens turns "this is broken" into "this is filtered", which is the
        // difference between a bug report and a menu tap. All adds nothing,
        // because it filters nothing.
        guard !context.isUnfiltered else { return EmptyState(title: title) }
        return EmptyState(
            title: title,
            subtitle: "Showing \(context.title) only. Change the context to see everything."
        )
    }
}
