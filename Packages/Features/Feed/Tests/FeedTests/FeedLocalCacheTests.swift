import AuthInterface
import CacheKit
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import LocalStore
import PostGrid
import Synchronization
import Testing
@testable import Feed

// MARK: - Fixtures

/// A store folder per suite instance, deleted with it.
private final class StoreFolder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "FeedLocalCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Who is using the app, as a test sets it.
private final class ViewerBox: Sendable {
    private let current = Mutex<LocalStoreViewer?>(.member(account: "acct-1", profile: "prof-1"))

    var viewer: LocalStoreViewer? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

private func cachedEntry(
    _ id: String, author: String = "author-1", likes: Int64 = 0, hidden: Bool = false,
    attachments: [MediaAttachment]? = nil, avatar: URL? = nil
) -> FeedEntry {
    FeedEntry(
        post: Post(
            id: PostID(id),
            authorID: ProfileID(author),
            caption: "caption \(id)",
            attachments: attachments ?? [MediaAttachment(
                url: URL(string: "https://cdn.example/\(id).jpg"),
                thumbnailURL: URL(string: "https://cdn.example/\(id)-thumb.jpg"),
                mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1350
            )],
            // Whole seconds: the contract carries milliseconds.
            publishedAt: Date(timeIntervalSince1970: 1_760_000_000),
            likeCountsHidden: hidden
        ),
        author: AuthorSummary(id: ProfileID(author), handle: "h-\(author)", displayName: "Name \(author)", avatarURL: avatar),
        likeCount: likes
    )
}

/// A feed that answers fixed pages, or fails like an offline network.
private final class ScriptedFeed: FeedProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _first: FeedPage
    private var _next: [String: FeedPage] = [:]
    private var _offline = false

    init(first: FeedPage, next: [String: FeedPage] = [:]) {
        _first = first
        _next = next
    }

    var first: FeedPage {
        get { lock.withLock { _first } }
        set { lock.withLock { _first = newValue } }
    }

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }

    func loadFirstPage() async throws -> FeedPage {
        try lock.withLock {
            if _offline { throw FeedError.transport(message: "offline", failure: .offline) }
            return _first
        }
    }

    func loadPage(afterToken token: String) async throws -> FeedPage {
        try lock.withLock {
            if _offline { throw FeedError.transport(message: "offline", failure: .offline) }
            return _next[token] ?? FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
    }

    func loadPost(_ id: PostID) async throws -> FeedEntry { cachedEntry(id.rawValue) }
}

@MainActor
private func settleTasks() async {
    for _ in 0..<40 { await Task.yield() }
}

// MARK: - The cache

/// The feed's lists in the LocalStore: protobuf round trip, one row per post
/// across lists, cursors, viewers (#893).
final class FeedLocalCacheTests {
    private let folder = StoreFolder()
    private let viewer = ViewerBox()

    private func makeCache() throws -> FeedLocalCache {
        let box = viewer
        return FeedLocalCache(store: try LocalStore(directory: folder.url, viewer: { box.viewer }))
    }

    @Test func entriesRoundTripThroughTheirProtobufBytes() throws {
        let entries = [
            cachedEntry("p1", likes: 0, avatar: URL(string: "https://cdn.example/a.jpg")),
            cachedEntry("p2", author: "author-2", likes: 42, hidden: true, attachments: [
                MediaAttachment(url: URL(string: "https://cdn.example/v.mp4"), thumbnailURL: nil, mimeType: "video/mp4", pixelWidth: 720, pixelHeight: 1280),
                MediaAttachment(url: URL(string: "https://cdn.example/i.jpg"), thumbnailURL: URL(string: "https://cdn.example/i-t.jpg"), mimeType: "image/jpeg", pixelWidth: 0, pixelHeight: 0)
            ]),
            cachedEntry("p3", author: "author-3", attachments: [])
        ]
        let writer = viewer.viewer
        try makeCache().storeFirstPage(
            entries, counters: [PostID("p2"): PostCounters(likes: 7, comments: 0)],
            nextCursor: "c1", in: .forYouDiscover, as: writer
        )
        // A cold start: a new store on the same file.
        let stored = try #require(try makeCache().firstPage(of: .forYouDiscover))
        #expect(stored.entries == entries)
        #expect(stored.nextCursor == "c1")
        #expect(stored.counters[PostID("p2")] == PostCounters(likes: 7, comments: 0), "a zero is kept as a zero")
        #expect(stored.counters[PostID("p1")] == nil, "an unanswered counter stays absent")
    }

    @Test func aPostInTwoListsIsOneRowAndBothReadTheFreshestCopy() throws {
        let cache = try makeCache()
        let writer = viewer.viewer
        cache.storeFirstPage([cachedEntry("shared", likes: 3), cachedEntry("d1")], nextCursor: nil, in: .forYouDiscover, as: writer)
        cache.storeFirstPage([cachedEntry("shared", likes: 5)], nextCursor: nil, in: .forYouFollowing, as: writer)
        // 2 posts, 1 author, 2 like counters: the shared post is not stored twice.
        #expect(cache.store.usage.count == 5)
        #expect(cache.firstPage(of: .forYouDiscover)?.entries.first?.likeCount == 5, "Discover reads what Following fetched last")
        #expect(cache.firstPage(of: .forYouFollowing)?.entries.first?.likeCount == 5)
    }

    @Test func nextPagesAreStoredWithTheirCursorAndServedBack() throws {
        let cache = try makeCache()
        let writer = viewer.viewer
        cache.storeFirstPage([cachedEntry("p1")], nextCursor: "c1", in: .following, as: writer)
        cache.storeNextPage([cachedEntry("p2")], nextCursor: "c2", after: "c1", in: .following, as: writer)
        // The first page alone opens the screen, with its own cursor…
        let first = try #require(cache.firstPage(of: .following))
        #expect(first.entries.map(\.post.id.rawValue) == ["p1"])
        #expect(first.nextCursor == "c1")
        // …and the page after it is there when the network is not.
        let next = try #require(cache.page(after: "c1", in: .following))
        #expect(next.entries.map(\.post.id.rawValue) == ["p2"])
        #expect(next.nextCursor == "c2")
        #expect(cache.page(after: "c2", in: .following) == nil)
    }

    @Test func aPageThatLandsAfterAViewerSwitchIsNotStored() throws {
        let cache = try makeCache()
        let writer = viewer.viewer
        viewer.viewer = .member(account: "acct-2", profile: "prof-9")
        cache.storeFirstPage([cachedEntry("alice-late")], nextCursor: nil, in: .following, as: writer)
        #expect(cache.firstPage(of: .following) == nil)
        viewer.viewer = .member(account: "acct-1", profile: "prof-1")
        #expect(cache.firstPage(of: .following) == nil)
    }

    @Test func relationsRoundTrip() throws {
        let cache = try makeCache()
        let all: [FollowRelation] = [.viewer, .following, .mutual, .notFollowing, .followedBy, .blocked, .requested]
        let relations = Dictionary(uniqueKeysWithValues: all.enumerated().map { (ProfileID("p\($0.offset)"), $0.element) })
        cache.storeRelations(relations, as: viewer.viewer)
        #expect(cache.relations(for: Set(relations.keys)) == relations)
    }
}

// MARK: - The Following feed

/// `FeedRepository` writes the following timeline's pages and opens on them
/// at the next cold start; the JSON snapshot it replaces is gone (#893).
final class FollowingColdStartTests {
    private let folder = StoreFolder()

    private func makeRepository() throws -> FeedRepository {
        let bff = MockBFF()
        let dataset = MockSocialDataset()
        let counters = MockCounterStore(dataset: dataset)
        MockSocialServices(dataset: dataset).register(on: bff)
        MockEngagementService(store: counters).register(on: bff)
        MockCounterService(store: counters).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: ColdStartToken(), httpClient: bff
        )
        let session = ColdStartSession()
        let viewer = ViewerSession(authSession: session) { account in
            try await AccountProfilesReader.profileIDs(
                ofAccount: account.rawValue, using: Profile_V1_ProfileServiceClient(client: client)
            ).map { ProfileID($0) }
        }
        let store = try LocalStore(directory: folder.url, viewer: { .member(account: MockAuthService.accountID, profile: nil) })
        return FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: session,
            viewer: viewer,
            localCache: FeedLocalCache(store: store)
        )
    }

    @Test func theFollowingFeedOpensOnItsLastFirstPageAfterAColdStart() async throws {
        let session = try makeRepository()
        #expect(await session.cachedFirstPage() == nil, "nothing stored yet")
        let first = try await session.loadFirstPage()
        let token = try #require(first.nextPageToken)
        _ = try await session.loadPage(afterToken: token)

        // The next launch: a new repository over a new store on the same file.
        let relaunched = try makeRepository()
        let cached = try #require(await relaunched.cachedFirstPage())
        #expect(cached == first.entries, "the first page, as the network served it, without a request")
    }
}

private struct ColdStartSession: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private struct ColdStartToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}

// MARK: - For You

/// For You opens on the last session's corpora in its first frame, and the
/// revalidation that follows changes nothing on screen when nothing changed
/// (#893).
@MainActor
final class ForYouColdStartTests {
    private let folder = StoreFolder()
    private let viewer = ViewerBox()
    private let discoverEntries = [cachedEntry("d1", likes: 4), cachedEntry("d2", author: "author-2"), cachedEntry("d3")]
    private let followingEntries = [cachedEntry("f1", author: "friend"), cachedEntry("f2", author: "author-2")]

    private func makeCache() throws -> FeedLocalCache {
        let box = viewer
        return FeedLocalCache(store: try LocalStore(directory: folder.url, viewer: { box.viewer }))
    }

    private struct Session {
        let viewModel: ForYouViewModel
        let discover: ScriptedFeed
        let following: ScriptedFeed
        let monitor: ConnectivityMonitor
        let snapshots: () -> [ForYouViewModel.Snapshot]
        let resets: () -> Int
        let refreshFailures: () -> Int
    }

    /// One launch: a repository over the store and scripted networks.
    private func launch(discover: [FeedEntry]? = nil, following: [FeedEntry]? = nil, cursor: String? = "dc1") throws -> Session {
        let discoverFeed = ScriptedFeed(first: FeedPage(entries: discover ?? discoverEntries, nextPageToken: cursor, isCold: false))
        let followingFeed = ScriptedFeed(first: FeedPage(entries: following ?? followingEntries, nextPageToken: "fc1", isCold: false))
        let repository = ForYouRepository(feed: followingFeed, discovery: discoverFeed, localCache: try makeCache())
        let viewModel = ForYouViewModel(
            repository: repository,
            unreadStore: ForYouUnreadStore(defaults: UserDefaults(suiteName: "ForYouColdStart-\(UUID().uuidString)")!),
            seenStore: ForYouSeenPostsStore(defaults: UserDefaults(suiteName: "ForYouColdStartSeen-\(UUID().uuidString)")!)
        )
        let monitor = ConnectivityMonitor(offlineGrace: 0)
        viewModel.connectivity = monitor
        var snapshots: [ForYouViewModel.Snapshot] = []
        var resets = 0
        var refreshFailures = 0
        viewModel.onSnapshotChange = { snapshots.append($0) }
        viewModel.onCorpusReset = { resets += 1 }
        viewModel.onRefreshFailed = { refreshFailures += 1 }
        return Session(
            viewModel: viewModel, discover: discoverFeed, following: followingFeed, monitor: monitor,
            snapshots: { snapshots }, resets: { resets }, refreshFailures: { refreshFailures }
        )
    }

    private func discoverIDs(_ state: ForYouViewModel.PageState?) -> [String]? {
        guard case .content(let posts) = state else { return nil }
        return posts.map(\.id.rawValue)
    }

    @Test func aFirstLaunchOpensOnSkeletonsAndStoresWhatLands() async throws {
        let first = try launch()
        first.viewModel.viewDidLoad()
        #expect(first.snapshots().first?.discover == .loading, "nothing stored yet")
        await settleTasks()
        #expect(discoverIDs(first.snapshots().last?.discover) == ["d1", "d2", "d3"])
        #expect(try makeCache().firstPage(of: .forYouDiscover)?.entries == discoverEntries)
        #expect(try makeCache().firstPage(of: .forYouFollowing)?.entries == followingEntries)
    }

    @Test func aColdStartRendersTheLastCorpusInItsFirstFrame() async throws {
        let previous = try launch()
        previous.viewModel.viewDidLoad()
        await settleTasks()

        let relaunch = try launch()
        relaunch.viewModel.viewDidLoad()
        // Before any await: the first snapshot is content, never loading.
        let frameZero = try #require(relaunch.snapshots().first)
        #expect(discoverIDs(frameZero.discover) == ["d1", "d2", "d3"])
        #expect(frameZero.following != .loading)
        #expect(relaunch.viewModel.hasMorePages, "and it pages on from the stored cursor")

        // The revalidation answers the same posts: no re-derivation, and the
        // pages are handed the same content (they keep their cells).
        await settleTasks()
        #expect(relaunch.resets() == 0)
        #expect(relaunch.snapshots().last?.discover == frameZero.discover)
    }

    @Test func aRevalidationThatChangedSomethingReplacesTheCorpus() async throws {
        let previous = try launch()
        previous.viewModel.viewDidLoad()
        await settleTasks()

        let relaunch = try launch(discover: [cachedEntry("new")] + discoverEntries)
        relaunch.viewModel.viewDidLoad()
        #expect(discoverIDs(relaunch.snapshots().first?.discover) == ["d1", "d2", "d3"])
        await settleTasks()
        #expect(relaunch.resets() == 1)
        #expect(discoverIDs(relaunch.snapshots().last?.discover) == ["new", "d1", "d2", "d3"])
    }

    @Test func anOfflineColdStartKeepsTheLastCorpusSilentlyAndReloadsOnRecovery() async throws {
        let previous = try launch()
        previous.viewModel.viewDidLoad()
        await settleTasks()

        let relaunch = try launch(discover: [cachedEntry("fresh")] + discoverEntries)
        relaunch.discover.offline = true
        relaunch.following.offline = true
        relaunch.viewModel.viewDidLoad()
        await settleTasks()
        #expect(discoverIDs(relaunch.snapshots().last?.discover) == ["d1", "d2", "d3"])
        #expect(relaunch.refreshFailures() == 0, "no toast: the offline indicator says why")

        relaunch.discover.offline = false
        relaunch.following.offline = false
        relaunch.monitor.report(online: false)
        relaunch.monitor.report(online: true)
        for _ in 0..<200 where discoverIDs(relaunch.snapshots().last?.discover)?.first != "fresh" {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(discoverIDs(relaunch.snapshots().last?.discover) == ["fresh", "d1", "d2", "d3"])
    }

    @Test func aPullThatFailsOverTheLastCorpusSaysSo() async throws {
        let previous = try launch()
        previous.viewModel.viewDidLoad()
        await settleTasks()

        let relaunch = try launch()
        relaunch.discover.offline = true
        relaunch.following.offline = true
        relaunch.viewModel.viewDidLoad()
        await settleTasks()
        relaunch.viewModel.refresh()
        await settleTasks()
        #expect(relaunch.refreshFailures() == 1)
        #expect(discoverIDs(relaunch.snapshots().last?.discover) == ["d1", "d2", "d3"])
    }

    @Test func storedPagesServeTheScrollWhileOffline() async throws {
        let cache = try makeCache()
        let writer = viewer.viewer
        cache.storeFirstPage(discoverEntries, nextCursor: "dc1", in: .forYouDiscover, as: writer)
        cache.storeNextPage([cachedEntry("d4")], nextCursor: nil, after: "dc1", in: .forYouDiscover, as: writer)
        let offline = ScriptedFeed(first: FeedPage(entries: [], nextPageToken: nil, isCold: false))
        offline.offline = true
        let repository = ForYouRepository(feed: offline, discovery: offline, localCache: cache)
        let next = try #require(try await repository.discoveryPage(after: "dc1"))
        #expect(next.posts.map(\.id.rawValue) == ["d4"])
        #expect(next.nextPageToken == nil)
        await #expect(throws: FeedError.self) { _ = try await repository.discoveryPage(after: "unknown") }
    }

    @Test func theRowsAreSplitInTheFirstFrameFromTheStoredRelations() async throws {
        let cache = try makeCache()
        let writer = viewer.viewer
        cache.storeFirstPage(discoverEntries, nextCursor: nil, in: .forYouDiscover, as: writer)
        cache.storeFirstPage(followingEntries, nextCursor: nil, in: .forYouFollowing, as: writer)
        cache.storeRelations([ProfileID("friend"): .mutual, ProfileID("author-2"): .following], as: writer)

        let relaunch = try launch()
        relaunch.viewModel.viewDidLoad()
        let frameZero = try #require(relaunch.snapshots().first)
        #expect(discoverIDs(frameZero.friends) == ["f1"])
        #expect(discoverIDs(frameZero.following) == ["f2"])
    }
}

// MARK: - Comments

/// A post opened in an earlier session opens its comments on the last first
/// page, before any request (#893).
final class CommentsColdStartTests {
    private let folder = StoreFolder()
    private let viewer = ViewerBox()

    private func makeRepository() throws -> CommentsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let box = viewer
        return CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: ColdStartSession(),
            localStore: try LocalStore(directory: folder.url, viewer: { box.viewer })
        )
    }

    @Test func aPostsFirstCommentPageOpensFromTheDeviceAfterAColdStart() async throws {
        let session = try makeRepository()
        let loaded = try await session.loadCommentsPage(for: PostID("post-0001"), after: nil).entries
        try #require(!loaded.isEmpty)
        session.waitForDeviceWrites()

        let relaunched = try makeRepository()
        #expect(relaunched.cachedTopComments(for: PostID("post-0001")) == loaded, "synchronously, before any request")
        #expect(relaunched.cachedTopComments(for: PostID("post-0002")) == nil)
    }

    @Test func anotherViewerOpensOnNoComments() async throws {
        let session = try makeRepository()
        _ = try await session.loadCommentsPage(for: PostID("post-0001"), after: nil)
        session.waitForDeviceWrites()

        viewer.viewer = .member(account: "acct-2", profile: "prof-9")
        let relaunched = try makeRepository()
        #expect(relaunched.cachedTopComments(for: PostID("post-0001")) == nil)
    }
}
