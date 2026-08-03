import CoreModels
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
        let store = makeStore(arguments: ["-foryou-badges", "3,0,1"])
        #expect(store.count(for: .activity, in: []) == 3)
        #expect(store.count(for: .media, in: []) == 0)
        #expect(store.count(for: .short, in: []) == 1)
    }

    @MainActor
    @Test func theForcedOrderIsThePagerOrder() {
        // `ForYouUnreadStore` spells the order out literally because the pager's
        // static is MainActor-isolated. This is what stops the two drifting.
        #expect(ForYouPagerView.pageOrder == [.activity, .media, .short])
    }

    @Test func aTabChangeRetiresItsOverride() {
        let store = makeStore(arguments: ["-foryou-badges", "3,0,1"])
        #expect(store.count(for: .activity, in: []) == 3)
        store.markSeen(.activity, in: [post("a", at: 10)], clearingOverride: true)
        #expect(store.count(for: .activity, in: [post("a", at: 10)]) == 0)
    }

    @Test func anAutomaticAdvanceLeavesTheOverrideStanding() {
        let store = makeStore(arguments: ["-foryou-badges", "3,0,1"])
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
        #expect(box.latest == [.activity: 0, .media: 0, .short: 0])
    }

    @Test func theActiveTabNeverBadgesContentThatLandedUnderTheViewersEyes() async {
        let store = makeStore()
        // Activity is the landing tab and shows everything, so a first load
        // arriving while it is on screen has been seen by definition.
        store.markSeen(.activity, in: [post("old", at: 1)])
        store.markSeen(.media, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        model.viewDidLoad()
        await settle()
        #expect(box.latest[.activity] == 0)
        // The same post is unread on Gallery, which the viewer is NOT looking
        // at — one arrival, two honest answers.
        #expect(box.latest[.media] == 1)
    }

    @Test func changingTabsClearsThatTabsBadge() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        store.markSeen(.media, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        model.viewDidLoad()
        await settle()
        #expect(box.latest[.media] == 1)
        model.setFormat(.media)
        #expect(box.latest[.media] == 0)
    }

    @Test func leavingATabDoesNotBadgeWhatWasOnScreen() async {
        let store = makeStore()
        store.markSeen(.activity, in: [post("old", at: 1)])
        let (model, box) = makeModel(posts: [post("a", at: 100)], store: store)
        model.viewDidLoad()
        await settle()
        // Activity was watching when "a" landed; walking to Gallery and back
        // must not present it as news.
        model.setFormat(.media)
        model.setFormat(.activity)
        #expect(box.latest[.activity] == 0)
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
