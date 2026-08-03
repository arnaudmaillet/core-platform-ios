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
    @Test func unreadIsShownAsPresenceNeverAsANumber() {
        // The store keeps deriving a real count; this is where For You decides
        // the number is not the useful part. Any positive count is one dot.
        #expect(ForYouViewController.badgeStyle(forUnread: 1) == .dot(isVisible: true))
        #expect(ForYouViewController.badgeStyle(forUnread: 3) == .dot(isVisible: true))
        #expect(ForYouViewController.badgeStyle(forUnread: 99) == .dot(isVisible: true))
    }

    @Test func nothingUnreadShowsNothing() {
        #expect(ForYouViewController.badgeStyle(forUnread: 0) == .dot(isVisible: false))
    }

    @Test func aNegativeCountIsNotAnIndicator() {
        // Defensive: no path produces one today, but "anything non-zero shows a
        // dot" would turn a future arithmetic slip into a badge that cannot be
        // cleared.
        #expect(ForYouViewController.badgeStyle(forUnread: -1) == .dot(isVisible: false))
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

    @Test func theActiveTabNeverBadgesContentThatLandedUnderTheViewersEyes() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        // Sitting on Following when the load arrives: it has been seen by
        // definition, so the one badged tab still reports nothing.
        model.setFormat(.activity)
        model.viewDidLoad()
        await settle()
        #expect(box.latest[.activity] == 0)
    }

    @Test func changingTabsClearsThatTabsBadge() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        model.viewDidLoad()
        await settle()
        #expect(box.latest[.activity] == 1)
        model.setFormat(.activity)
        #expect(box.latest[.activity] == 0)
    }

    @Test func leavingATabDoesNotBadgeWhatWasOnScreen() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        model.setFormat(.activity)
        model.viewDidLoad()
        await settle()
        // Following was watching when "a" landed; walking to Discover and back
        // must not present it as news.
        model.setFormat(.media)
        model.setFormat(.activity)
        #expect(box.latest[.activity] == 0)
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
