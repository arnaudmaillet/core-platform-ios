import CoreModels
import DesignSystem
import Foundation
import PostGrid
import Testing
@testable import Feed

// MARK: - Fixtures

private func post(_ id: String, kind: GalleryPost.Kind = .photo, at publishedAtMS: Int64) -> GalleryPost {
    GalleryPost(
        id: PostID(id),
        kind: kind,
        isRepost: false,
        thumbnailURL: nil,
        caption: "caption \(id)",
        publishedAtMS: publishedAtMS,
        reactionCount: nil
    )
}

/// A store over its own throwaway defaults suite, so tests never touch — or
/// inherit — the simulator's real watermarks.
private func makeStore(arguments: [String] = []) -> ForYouUnreadStore {
    let suite = UserDefaults(suiteName: "foryou.unread.tests.\(UUID().uuidString)")!
    return ForYouUnreadStore(defaults: suite, keyPrefix: "test.unread", arguments: arguments)
}

private final class StubProvider: ForYouProviding, @unchecked Sendable {
    private let lock = NSLock()
    var first: ForYouPage
    var next: ForYouPage

    init(first: ForYouPage, next: ForYouPage = ForYouPage(posts: [], nextPageToken: nil)) {
        self.first = first
        self.next = next
    }

    func firstPage() async throws -> ForYouPage { lock.withLock { first } }
    func page(after token: String) async throws -> ForYouPage { lock.withLock { next } }
}

@MainActor
private func settle() async {
    for _ in 0..<12 { await Task.yield() }
}

// MARK: - The pure count

struct ForYouUnreadCountTests {
    private let posts = [
        post("a", at: 10),
        post("b", at: 30),
        post("c", at: 20)
    ]

    @Test func countsOnlyWhatIsStrictlyNewer() {
        #expect(ForYouUnread.count(in: posts, since: 15) == 2)
    }

    @Test func theWatermarkItselfIsAlreadySeen() {
        // Strictly newer, so re-marking a tab whose newest post is the
        // watermark lands on zero rather than one.
        #expect(ForYouUnread.count(in: posts, since: 30) == 0)
    }

    @Test func theWatermarkIsTheNewestLoadedPost() {
        #expect(ForYouUnread.watermark(of: posts) == 30)
    }

    @Test func anEmptyPageHasNoWatermarkToAdopt() {
        // nil rather than 0: a tab with nothing on it must not claim to have
        // seen the epoch, or content arriving a moment later counts as read.
        #expect(ForYouUnread.watermark(of: []) == nil)
    }
}

// MARK: - The persisted store

struct ForYouUnreadStoreTests {
    @Test func aFirstSightIsNeverAllNew() {
        let store = makeStore()
        // 40 posts and no watermark: technically all newer than nothing, but
        // the viewer has not missed them, they have simply never been here.
        #expect(store.count(for: .activity, in: [post("a", at: 10), post("b", at: 20)]) == 0)
    }

    @Test func postsArrivingAfterAVisitAreCounted() {
        let store = makeStore()
        store.markSeen(.activity, in: [post("a", at: 10)])
        #expect(store.count(for: .activity, in: [post("a", at: 10), post("b", at: 20)]) == 1)
    }

    @Test func theFirstSightSeedsTheWatermarkRatherThanLeavingItUnset() {
        let store = makeStore()
        _ = store.count(for: .activity, in: [post("a", at: 10)])
        // The seed is what makes the SECOND load's new post countable. Without
        // it every load would look like a first sight and badge nothing, ever.
        #expect(store.count(for: .activity, in: [post("a", at: 10), post("b", at: 20)]) == 1)
    }

    @Test func markingSeenClearsTheCount() {
        let store = makeStore()
        store.markSeen(.activity, in: [post("a", at: 10)])
        let loaded = [post("a", at: 10), post("b", at: 20)]
        #expect(store.count(for: .activity, in: loaded) == 1)
        store.markSeen(.activity, in: loaded)
        #expect(store.count(for: .activity, in: loaded) == 0)
    }

    @Test func aWatermarkNeverMovesBackwards() {
        let store = makeStore()
        store.markSeen(.activity, in: [post("b", at: 30)])
        // A source change can re-filter the corpus down to older posts. If that
        // rewound the watermark, everything between would be resurrected as
        // unread — posts the viewer has already read.
        store.markSeen(.activity, in: [post("a", at: 10)])
        #expect(store.count(for: .activity, in: [post("a", at: 10), post("b", at: 30)]) == 0)
    }

    @Test func anEmptyPageDoesNotMoveTheWatermark() {
        let store = makeStore()
        store.markSeen(.activity, in: [post("a", at: 10)])
        store.markSeen(.activity, in: [])
        #expect(store.count(for: .activity, in: [post("a", at: 10), post("b", at: 20)]) == 1)
    }

    @Test func theFormatsKeepSeparateWatermarks() {
        let store = makeStore()
        store.markSeen(.media, in: [post("m1", at: 10)])
        store.markSeen(.short, in: [post("s1", kind: .text, at: 30)])
        let media = [post("m1", at: 10), post("m2", at: 20)]
        let short = [post("s1", kind: .text, at: 30), post("s2", kind: .text, at: 20)]
        // One key for both would put Short's later watermark over Media and
        // silence the one post that IS new there.
        #expect(store.count(for: .media, in: media) == 1)
        #expect(store.count(for: .short, in: short) == 0)
    }

    @Test func stagingBacksDatesTheWatermarkWhenTheCorpusAllows() {
        let store = makeStore()
        let posts = [post("a", at: 10), post("b", at: 20), post("c", at: 30), post("d", at: 40)]
        store.stageUnread(3, for: .activity, in: posts)
        // The three newest (40, 30, 20) are now newer than the watermark (10).
        #expect(store.count(for: .activity, in: posts) == 3)
    }

    @Test func stagingSurvivesUnsortedInput() {
        let store = makeStore()
        // The corpus arrives in display order, which is whatever the active
        // discovery ordering says — never assume it is chronological.
        let posts = [post("c", at: 30), post("a", at: 10), post("d", at: 40), post("b", at: 20)]
        store.stageUnread(2, for: .activity, in: posts)
        #expect(store.count(for: .activity, in: posts) == 2)
    }

    @Test func aCountBiggerThanTheCorpusIsStatedOutright() {
        let store = makeStore()
        let posts = [post("a", at: 10), post("b", at: 20)]
        // No timestamp leaves 5 posts above it in a corpus of 2, so the
        // watermark cannot express this and the count is stated instead. A QA
        // argument asking for a wide pill gets the wide pill.
        store.stageUnread(5, for: .activity, in: posts)
        #expect(store.count(for: .activity, in: posts) == 5)
    }

    @Test func aStatedCountStillClearsWhenTheTabIsRead() {
        let store = makeStore()
        let posts = [post("a", at: 10), post("b", at: 20)]
        store.stageUnread(99, for: .activity, in: posts)
        #expect(store.count(for: .activity, in: posts) == 99)
        // Same clearing path as a derived one — the mock must not leave a badge
        // that no amount of reading can dismiss.
        store.markSeen(.activity, in: posts, clearingOverride: true)
        #expect(store.count(for: .activity, in: posts) == 0)
    }

    @Test func stagingZeroDoesNothing() {
        let store = makeStore()
        let posts = [post("a", at: 10), post("b", at: 20)]
        store.stageUnread(0, for: .activity, in: posts)
        #expect(store.count(for: .activity, in: posts) == 0)
    }

    @Test func aDerivedStagedBadgeClearsThroughTheOrdinaryPath() {
        let store = makeStore()
        let posts = [post("a", at: 10), post("b", at: 20), post("c", at: 30)]
        store.stageUnread(2, for: .activity, in: posts)
        #expect(store.count(for: .activity, in: posts) == 2)
        // The whole point of staging it this way rather than forcing a number:
        // reading the tab clears it exactly as a genuine count would.
        store.markSeen(.activity, in: posts)
        #expect(store.count(for: .activity, in: posts) == 0)
    }

    @Test func watermarksSurviveANewStoreOverTheSameDefaults() {
        let suite = UserDefaults(suiteName: "foryou.unread.tests.\(UUID().uuidString)")!
        let first = ForYouUnreadStore(defaults: suite, keyPrefix: "test.unread", arguments: [])
        first.markSeen(.activity, in: [post("a", at: 10)])
        // The whole point of persisting: "since you last looked" has to mean
        // something across a relaunch.
        let relaunched = ForYouUnreadStore(defaults: suite, keyPrefix: "test.unread", arguments: [])
        #expect(relaunched.count(for: .activity, in: [post("a", at: 10), post("b", at: 20)]) == 1)
    }
}

// MARK: - The debug override

#if DEBUG
struct ForYouBadgeOverrideTests {
    @Test func theArgumentForcesCountsInPagerOrder() {
        // Pager order is Discover then Following, so the first number is the
        // media page's and the second is the unfiltered one's.
        let store = makeStore(arguments: ["-foryou-badges", "3,7"])
        #expect(store.count(for: .media, in: []) == 3)
        #expect(store.count(for: .activity, in: []) == 7)
    }

    @Test func aCountPastTheTabsIsIgnored() {
        // Three numbers for two tabs: the extra belongs to a tab that no longer
        // exists, and must not land on one that does.
        let store = makeStore(arguments: ["-foryou-badges", "3,7,9"])
        #expect(store.count(for: .media, in: []) == 3)
        #expect(store.count(for: .activity, in: []) == 7)
        #expect(store.count(for: .short, in: []) == 0)
    }

    @MainActor
    @Test func theForcedOrderIsThePagerOrder() {
        // `ForYouUnreadStore` reads `ForYouViewModel.tabs` because the pager's
        // own static is MainActor-isolated. This is what stops the two drifting.
        #expect(ForYouPagerView.pageOrder == ForYouViewModel.tabs)
        #expect(ForYouViewModel.tabs == [.media, .activity])
    }

    @MainActor
    @Test func theBadgedTabIsFollowingAndTheLandingTabIsDiscover() {
        #expect(ForYouViewModel.badgedTab == .activity)
        #expect(ForYouViewModel.defaultFormat == .media)
        // The landing tab must not be the badged one, or the badge clears
        // itself on the first publish and can never be seen.
        #expect(ForYouViewModel.defaultFormat != ForYouViewModel.badgedTab)
    }

    @Test func aTabChangeRetiresItsOverride() {
        let store = makeStore(arguments: ["-foryou-badges", "0,3"])
        #expect(store.count(for: .activity, in: []) == 3)
        store.markSeen(.activity, in: [post("a", at: 10)], clearingOverride: true)
        #expect(store.count(for: .activity, in: [post("a", at: 10)]) == 0)
    }

    @Test func anAutomaticAdvanceLeavesTheOverrideStanding() {
        let store = makeStore(arguments: ["-foryou-badges", "0,3"])
        // The view model advances the active tab's watermark on every publish,
        // including the first one. If that retired the override, a forced badge
        // would be wiped before it rendered a single frame.
        store.markSeen(.activity, in: [post("a", at: 10)])
        #expect(store.count(for: .activity, in: [post("a", at: 10)]) == 3)
    }

    @Test func anAbsentArgumentForcesNothing() {
        #expect(makeStore().count(for: .activity, in: []) == 0)
    }
}
#endif

// MARK: - How the count is presented

@MainActor
struct ForYouBadgePresentationTests {
    /// ⚠️ This used to assert the opposite — presence, never a number — on the
    /// argument that three new posts are not three things to open. That held
    /// while the count answered one question. It now sizes the "New" section
    /// the viewer scrolls through and appears beside every mode in the context
    /// menu, so a dot would be the badge disagreeing with two things on the
    /// same screen.
    @Test func unreadIsShownAsTheNumberItIs() {
        #expect(ForYouViewController.badgeStyle(forUnread: 1) == .count(1))
        #expect(ForYouViewController.badgeStyle(forUnread: 3) == .count(3))
        #expect(ForYouViewController.badgeStyle(forUnread: 99) == .count(99))
    }

    @Test func nothingUnreadShowsNothing() {
        // The presence signal the dot carried is not lost — `.count` renders
        // nothing at zero — it just arrived with a size attached.
        #expect(ForYouViewController.badgeStyle(forUnread: 0) == .count(0))
        #expect(ForYouViewController.badgeStyle(forUnread: 0).isVisible == false)
    }

    @Test func aNegativeCountIsNotAnIndicator() {
        // Defensive: no path produces one today, but a badge that draws for any
        // non-zero value would turn a future arithmetic slip into a pill that
        // cannot be cleared.
        #expect(ForYouViewController.badgeStyle(forUnread: -1).isVisible == false)
    }

    @Test func theCountStyleStaysAvailableForHostsThatCount() {
        // Messages renders numbers through the same component; removing that
        // case is what this test exists to prevent.
        #expect(PagedTabBar.BadgeStyle.count(11).isVisible)
        #expect(PagedTabBar.BadgeStyle.count(0).isVisible == false)
    }
}

// MARK: - Through the view model

@MainActor
struct ForYouViewModelUnreadTests {
    private func makeModel(
        posts: [GalleryPost],
        store: ForYouUnreadStore
    ) -> (ForYouViewModel, Box) {
        let model = ForYouViewModel(
            repository: StubProvider(first: ForYouPage(posts: posts, nextPageToken: nil)),
            preferences: nil,
            unreadStore: store
        )
        let box = Box()
        model.onUnreadChange = { counts in box.counts.append(counts) }
        return (model, box)
    }

    /// Keeps every emission, not just the last: a badge that appears and is
    /// immediately superseded is exactly the kind of thing "last" hides.
    private final class Box {
        var counts: [[GalleryFilter.Format: Int]] = []
        var latest: [GalleryFilter.Format: Int] { counts.last ?? [:] }
    }

    @Test func theFirstLoadBadgesNothing() async {
        let store = makeStore()
        let (model, box) = makeModel(
            posts: [post("a", at: 10), post("t", kind: .text, at: 20)],
            store: store
        )
        model.viewDidLoad()
        await settle()
        // Two tabs, both silent — and `.short` is absent entirely, because a
        // count for a tab that does not exist has nowhere to be shown.
        #expect(box.latest == [.media: 0, .activity: 0])
    }

    @Test func onlyFollowingIsEverBadged() async {
        let store = makeStore()
        // Both tabs have been visited, then a newer post lands on both of them
        // (an unfiltered page shows the media page's posts too).
        store.markSeen(.activity, in: [post("old", at: 1)])
        store.markSeen(.media, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        model.viewDidLoad()
        await settle()
        // Following counts it: the viewer is on Discover and has not seen it.
        #expect(box.latest[.activity] == 1)
        // Discover does not, whatever its watermark says — a ranked surface has
        // no "since you last looked" to count against.
        #expect(box.latest[.media] == 0)
    }

    /// ⚠️ **This trio replaces three tests that asserted the opposite** —
    /// "the active tab never badges", "changing tabs clears that tab's badge",
    /// "leaving a tab does not badge what was on screen". Each of them was true
    /// of a badge derived from the PERSISTED cursor, which moves the moment the
    /// viewer looks at the tab.
    ///
    /// The badge is now derived from a baseline frozen for the session, because
    /// it has a second job: it is the size of the "New" section on the Following
    /// list. A count that zeroed itself on arrival would leave that section
    /// empty exactly when someone is looking at it, and the header and the badge
    /// could never be the same number. What was lost is small and what replaced
    /// it is visible: the count no longer means "unseen", it means "arrived
    /// since you opened the app" — and the rows it counts are on screen under
    /// their own header, which is a claim the viewer can check.
    @Test func aCountHoldsForTheSessionEvenWhileItsTabIsWatched() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        // Sitting on Following when the load arrives.
        model.setFormat(.activity)
        model.viewDidLoad()
        await settle()
        #expect(box.latest[.activity] == 1)
    }

    @Test func changingTabsDoesNotClearTheCount() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        model.viewDidLoad()
        await settle()
        #expect(box.latest[.activity] == 1)
        model.setFormat(.activity)
        #expect(box.latest[.activity] == 1)
        model.setFormat(.media)
        #expect(box.latest[.activity] == 1)
    }

    /// The persisted cursor still advances underneath, which is what keeps the
    /// count from being permanent: a session that has seen these posts hands
    /// the NEXT one a baseline that excludes them. This is the half of the old
    /// behaviour that survives, and the reason a badge is not forever.
    @Test func theNextSessionStartsFromWhereThisOneFinished() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let posts = [post("a", at: 100)]
        let (model, box) = makeModel(posts: posts, store: store)
        model.setFormat(.activity)
        model.viewDidLoad()
        await settle()
        #expect(box.latest[.activity] == 1)

        // A relaunch: same store, a brand-new model, so a brand-new baseline.
        let (next, nextBox) = makeModel(posts: posts, store: store)
        next.viewDidLoad()
        await settle()
        #expect(nextBox.latest[.activity] == 0)
    }

    @Test func theModelOpensOnDiscover() async {
        let store = makeStore()
        let (model, _) = makeModel(posts: [post("a", at: 100)], store: store)
        #expect(model.format == .media)
    }

    @Test func noBadgeIsPublishedBeforeTheFirstPageLands() async {
        let store = makeStore()
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        // `publish()` runs once up front to put every page in `.loading`. A
        // count derived from a corpus that does not exist yet would badge the
        // skeletons.
        model.viewDidLoad()
        #expect(box.counts.isEmpty)
    }
}

// MARK: - Seeding a baseline for the first time

@MainActor
struct ForYouFirstSightTests {
    private func store(now: Date, arguments: [String] = []) -> ForYouUnreadStore {
        ForYouUnreadStore(
            defaults: UserDefaults(suiteName: "foryou.firstsight.\(UUID().uuidString)")!,
            keyPrefix: "test.firstsight",
            arguments: arguments,
            now: { now }
        )
    }

    private let now = Date(timeIntervalSince1970: 1_000)
    private var nowMS: Int64 { 1_000_000 }

    /// The ordinary case, unchanged: a corpus entirely in the past seeds at its
    /// own newest post, so nothing already loaded is announced as new.
    @Test func aPastCorpusSeedsAtItsNewestPost() {
        let store = store(now: now)
        let posts = [post("a", at: nowMS - 5_000), post("b", at: nowMS - 9_000)]
        #expect(store.sessionBaseline(for: .activity, in: posts) == nowMS - 5_000)
    }

    /// ⚠️ The rule that makes a badge possible at all against a fixed corpus,
    /// and the one that protects a real one from clock skew: a baseline is
    /// never set to a moment that has not happened yet.
    @Test func aFutureDatedPostCannotSetTheBaseline() {
        let store = store(now: now)
        let posts = [post("arrival", at: nowMS + 300_000), post("old", at: nowMS - 5_000)]
        #expect(store.sessionBaseline(for: .activity, in: posts) == nowMS)
    }

    /// And so it counts. Seeding at the raw maximum made this zero, which is
    /// why the badge never appeared out of the box.
    @Test func aFutureDatedPostCountsAsAnArrival() {
        let store = store(now: now)
        let posts = [post("arrival", at: nowMS + 300_000), post("old", at: nowMS - 5_000)]
        let baseline = store.sessionBaseline(for: .activity, in: posts)!
        #expect(ForYouSessionWatermark(baselineMS: baseline).count(in: posts) == 1)
    }

    /// Reading a tab records "caught up to now", never "caught up to a moment
    /// that has not happened".
    ///
    /// ⚠️ Without the cap, a session that saw a future-dated post recorded ITS
    /// timestamp — marking as seen everything due to arrive before then. Against
    /// the mock's staged arrivals that meant a badge of 5 on the first launch
    /// and 1 on the next, decaying to nothing as the launches drew level.
    @Test func readingNeverRecordsAWatermarkInTheFuture() {
        let store = store(now: now)
        store.markSeen(.activity, in: [post("arrival", at: nowMS + 300_000)])
        // The next session's arrivals, ahead of ITS clock, still clear this.
        #expect(store.sessionBaseline(for: .activity, in: []) == nowMS)
    }

    @Test func readingStillRecordsAPastPost() {
        let store = store(now: now)
        store.markSeen(.activity, in: [post("seen", at: nowMS - 4_000)])
        #expect(store.sessionBaseline(for: .activity, in: []) == nowMS - 4_000)
    }

    /// A baseline is written once. A second sight reads what the first stored
    /// rather than re-seeding against a clock that has moved on.
    @Test func theBaselineIsSeededOnlyOnce() {
        let store = store(now: now)
        let posts = [post("a", at: nowMS - 5_000)]
        let first = store.sessionBaseline(for: .activity, in: posts)
        let second = store.sessionBaseline(for: .activity, in: [post("b", at: nowMS - 1)])
        #expect(first == second)
    }
}

// MARK: - The session baseline

@MainActor
struct ForYouSessionWatermarkTests {
    private let watermark = ForYouSessionWatermark(baselineMS: 100)

    @Test func onlyWhatArrivedAfterTheBaselineIsNew() {
        #expect(watermark.isNew(post("after", at: 101)))
        // Strictly after, so a corpus that has not changed lands on zero rather
        // than one.
        #expect(watermark.isNew(post("exactly", at: 100)) == false)
        #expect(watermark.isNew(post("before", at: 99)) == false)
    }

    @Test func theCountAndTheSplitAreTheSameAnswer() {
        // The invariant the whole design rests on: the number on the badge is
        // the size of the section under it, because both come from here.
        let posts = [post("c", at: 300), post("b", at: 200), post("a", at: 50)]
        let split = watermark.partition(posts)
        #expect(watermark.count(in: posts) == split.new.count)
        #expect(split.new.map(\.id.rawValue) == ["c", "b"])
        #expect(split.earlier.map(\.id.rawValue) == ["a"])
    }

    /// The Following page is a timeline where order carries meaning, so this
    /// partitions and never sorts — an interleaved corpus keeps the order it
    /// arrived in inside each half.
    @Test func partitioningPreservesTheCallersOrder() {
        let posts = [post("new1", at: 300), post("old1", at: 10), post("new2", at: 200)]
        let split = watermark.partition(posts)
        #expect(split.new.map(\.id.rawValue) == ["new1", "new2"])
        #expect(split.earlier.map(\.id.rawValue) == ["old1"])
    }

    @Test func anEmptyCorpusIsNotNews() {
        #expect(watermark.count(in: []) == 0)
        #expect(watermark.partition([]).new.isEmpty)
    }
}

// MARK: - Counts under a lens

@MainActor
struct ForYouContextCountTests {
    private func makeModel(posts: [GalleryPost], store: ForYouUnreadStore) -> ForYouViewModel {
        ForYouViewModel(
            repository: StubProvider(first: ForYouPage(posts: posts, nextPageToken: nil)),
            preferences: nil,
            unreadStore: store
        )
    }

    /// A "work" post and a "focus" post arrive after the baseline. Each lens
    /// counts only what it admits, and the unfiltered lens counts both — the
    /// numbers the context menu puts beside its rows.
    @Test func eachLensCountsOnlyWhatItAdmits() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let posts = [
            GalleryPost(
                id: PostID("w"), kind: .photo, isRepost: false, thumbnailURL: nil,
                caption: "shipping the refactor at the office", publishedAtMS: 100, reactionCount: nil
            ),
            GalleryPost(
                id: PostID("f"), kind: .photo, isRepost: false, thumbnailURL: nil,
                // NOT "deep work" — that phrase is in Focus's keyword set AND
                // contains Work's, so the post would land in both and the
                // per-lens counts would stop being distinguishable. The lens is
                // a caption search; overlapping fixtures test the overlap
                // rather than the counting.
                caption: "study session, quiet morning", publishedAtMS: 200, reactionCount: nil
            )
        ]
        let model = makeModel(posts: posts, store: store)
        var counts: [ContentContext: Int] = [:]
        model.onContextCountsChange = { counts = $0 }
        model.viewDidLoad()
        await settle()

        #expect(counts[.all] == 2)
        #expect(counts[.work] == 1)
        #expect(counts[.focus] == 1)
        #expect(counts[.gaming] == 0)
    }

    /// ⚠️ The baseline is an INSTANT, not a subject. Freezing it while a narrow
    /// lens happened to be selected would date the whole session from that
    /// lens's newest post, and every other lens would then under-count.
    @Test func theBaselineDoesNotDependOnTheLensThatWasActiveWhenItFroze() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let posts = [
            GalleryPost(
                id: PostID("g"), kind: .photo, isRepost: false, thumbnailURL: nil,
                caption: "boss level speedrun", publishedAtMS: 500, reactionCount: nil
            ),
            GalleryPost(
                id: PostID("w"), kind: .photo, isRepost: false, thumbnailURL: nil,
                caption: "office deadline", publishedAtMS: 100, reactionCount: nil
            )
        ]
        let model = makeModel(posts: posts, store: store)
        model.setContext(.gaming)
        var counts: [ContentContext: Int] = [:]
        model.onContextCountsChange = { counts = $0 }
        model.viewDidLoad()
        await settle()
        // Both are still new. Had the baseline frozen at the newest GAMING post
        // (500), the work post at 100 would have read as already seen.
        #expect(counts[.work] == 1)
        #expect(counts[.gaming] == 1)
        #expect(counts[.all] == 2)
    }

    /// The badge and the section are published together and describe the same
    /// posts — the invariant the sectioned list depends on.
    @Test func theBadgeIsTheSizeOfTheNewSection() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let model = makeModel(posts: [post("a", at: 100), post("b", at: 200)], store: store)
        var badge: Int?
        var arrivals: Set<PostID>?
        model.onUnreadChange = { badge = $0[.activity] }
        model.onNewPostsChange = { arrivals = $0 }
        model.viewDidLoad()
        await settle()
        #expect(badge == 2)
        #expect(arrivals?.count == badge)
    }

    /// ⚠️ And it names WHICH posts, not just how many. The page used to take the
    /// leading N rows, which is only the same set when the list happens to be in
    /// date order — Trending ranks it, so the arrivals sit wherever their
    /// reactions put them and the "New" header landed over the wrong rows.
    @Test func theNewSectionNamesTheArrivalsThemselves() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("seen", at: 100)])
        let model = makeModel(
            posts: [post("seen", at: 100), post("fresh", at: 500), post("older", at: 50)],
            store: store
        )
        var arrivals: Set<PostID>?
        model.onNewPostsChange = { arrivals = $0 }
        model.viewDidLoad()
        await settle()
        #expect(arrivals == [PostID("fresh")])
    }
}
