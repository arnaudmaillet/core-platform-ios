import AuthInterface
import CacheKit
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import LocalStore
import Synchronization
import Testing
@testable import Notifications

// The drawer's last notifications on the device, and the bounded lookups
// behind its rows (#897).

private let alice = LocalStoreViewer.member(account: "acct-alice", profile: "prof-alice")
private let bob = LocalStoreViewer.member(account: "acct-bob", profile: "prof-bob")

private final class ViewerBox: Sendable {
    private let current = Mutex<LocalStoreViewer?>(alice)

    var viewer: LocalStoreViewer? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

private final class DeviceFolder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "NotificationsLocalCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }
}

private func item(_ index: Int, read: Bool = true) -> NotificationItem {
    NotificationItem(
        id: "n\(index)", action: index.isMultiple(of: 2) ? .comment : .reaction,
        senderID: ProfileID("sender-\(index)"), senderName: "Sender \(index)",
        senderAvatarURL: URL(string: "https://cdn.example/\(index).jpg"), otherSenderCount: 2,
        sampleSenders: [NotificationActor(id: ProfileID("other-\(index)"), name: "Other", avatarURL: nil)],
        postSubjectID: PostID("post-\(index)"),
        subjectPreview: NotificationSubjectPreview(thumbnailURL: nil, excerpt: "text \(index)"),
        isRead: read, createdAt: Date(timeIntervalSince1970: TimeInterval(100_000 - index * 60))
    )
}

/// Pages of 20 by token ("p20", "p40"…), or no network at all.
private actor PagedDrawer: NotificationsProviding {
    private var offline = false
    nonisolated let total: Int
    private(set) var asks: [String?] = []

    init(total: Int) { self.total = total }

    func goOffline(_ value: Bool) { offline = value }

    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        asks.append(pageToken)
        if offline { throw NotificationsError.transport(message: "offline", failure: .offline) }
        let start = pageToken.flatMap { Int($0.dropFirst()) } ?? 0
        let end = min(start + Int(limit), total)
        return NotificationsPage(items: (start..<end).map { item($0) }, nextPageToken: end < total ? "p\(end)" : nil)
    }

    func markAllRead() async throws {}
    func unreadCount() async throws -> Int { 0 }
}

@MainActor
struct NotificationsLocalCacheTests {
    private let folder = DeviceFolder()
    private let viewer = ViewerBox()

    /// Waits for STATE, in looks (6,000 × 10 ms), never wall-clock time: a
    /// starved runner spends none of the budget (#1115). Returns whether
    /// `condition` came to hold; every caller asserts it.
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func launch() throws -> (LocalStore, NotificationsLocalCache) {
        let box = viewer
        let store = try LocalStore(directory: folder.url, viewer: { box.viewer })
        return (store, NotificationsLocalCache(store: store))
    }

    private final class Shown {
        var phase: NotificationsViewModel.Phase = .loading
        var ids: [String] {
            guard case .content(let sections) = phase else { return [] }
            return sections.flatMap { $0.rows.map(\.id) }
        }
        /// Every row loaded: shown, or held behind a section's "Show more"
        /// (#1571 — every section collapses, not only "New").
        var count: Int {
            guard case .content(let sections) = phase else { return 0 }
            return sections.reduce(0) { $0 + $1.rows.count + $1.hiddenCount }
        }
    }

    private func drawer(_ network: PagedDrawer, _ cache: NotificationsLocalCache) -> (NotificationsViewModel, Shown) {
        let viewModel = NotificationsViewModel(repository: network)
        viewModel.deviceCache = cache
        viewModel.connectivity = ConnectivityMonitor(offlineGrace: 0)
        viewModel.notificationCenter = NotificationCenter()
        let shown = Shown()
        viewModel.onPhaseChange = { shown.phase = $0 }
        return (viewModel, shown)
    }

    /// A first launch online that scrolled `pages` pages deep.
    private func firstLaunch(_ network: PagedDrawer, pages: Int) async throws {
        let (_, cache) = try launch()
        let (viewModel, shown) = drawer(network, cache)
        viewModel.viewDidLoad()
        #expect(await settle { await network.asks.count == 1 })
        for page in 1..<pages {
            #expect(await settle { viewModel.pageFooter == .loading })
            viewModel.loadNextPageIfNeeded()
            #expect(await settle { await network.asks.count == page + 1 })
        }
        // The last page landed: each page is stored before it renders
        // (`reload`, `loadPages`), so its rows on screen mean its write is
        // queued — and `waitForPendingWrites` waits for it.
        let read = min(pages * 20, network.total)
        #expect(await settle { shown.count == read })
        cache.waitForPendingWrites()
    }

    @Test func theDrawerOpensOnItsLastPageOfflineAtTheFirstFrame() async throws {
        let network = PagedDrawer(total: 60)
        try await firstLaunch(network, pages: 1)
        await network.goOffline(true)

        let (_, cache) = try launch()
        let (viewModel, shown) = drawer(network, cache)
        viewModel.viewDidLoad()
        // Inside `viewDidLoad`: no skeleton.
        guard case .content(let sections) = shown.phase else {
            Issue.record("expected the stored rows, got \(shown.phase)")
            return
        }
        #expect(sections.reduce(0) { $0 + $1.rows.count + $1.hiddenCount } == 20)
        #expect(viewModel.pageFooter == .loading, "the stored cursor says there is more")
        // Offline: the failed load leaves them.
        #expect(await settle { await network.asks.count >= 2 })
        // "Nothing more happens": the failed load leaves the stored rows, so
        // there is no landing to wait for, only time for one to be wrong.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(shown.count == 20)
    }

    @Test func aStoredRowComesBackWhole() async throws {
        let network = PagedDrawer(total: 3)
        try await firstLaunch(network, pages: 1)
        let (_, cache) = try launch()
        let stored = try #require(cache.stored())
        #expect(stored.items == [item(0), item(1), item(2)])
        #expect(stored.nextCursor == nil)
    }

    @Test func theLast100AreKeptAndPagingGoesOnFromTheStoredCursor() async throws {
        let network = PagedDrawer(total: 200)
        try await firstLaunch(network, pages: 6)
        #expect(await network.asks.last == "p100")

        let (_, cache) = try launch()
        let stored = try #require(cache.stored())
        #expect(stored.items.count == 100, "the last 100, not the 120 read")
        #expect(stored.nextCursor == "p100")

        let (viewModel, shown) = drawer(network, cache)
        await network.goOffline(true)
        viewModel.viewDidLoad()
        #expect(shown.count >= 1)
        #expect(await settle { await network.asks.count >= 7 })
        await network.goOffline(false)
        viewModel.loadNextPageIfNeeded()
        #expect(await settle { await network.asks.count >= 8 })
        #expect(await network.asks.last == "p100")
    }

    @Test func anotherAccountReadsNoneOfTheNotifications() async throws {
        let network = PagedDrawer(total: 20)
        try await firstLaunch(network, pages: 1)
        viewer.viewer = .guest
        viewer.viewer = bob
        let (store, cache) = try launch()
        #expect(cache.stored() == nil)
        let (viewModel, shown) = drawer(network, cache)
        await network.goOffline(true)
        viewModel.viewDidLoad()
        #expect(shown.ids.isEmpty)
        store.waitForPendingWrites()
        viewer.viewer = alice
        #expect(cache.stored() == nil, "wiped, not hidden")
    }

    @Test func aViewerChangeInTheSameLaunchDoesNotPutTheDeviceRowsBack() async throws {
        let network = PagedDrawer(total: 20)
        try await firstLaunch(network, pages: 1)
        let (_, cache) = try launch()
        let center = NotificationCenter()
        let viewModel = NotificationsViewModel(repository: network)
        viewModel.deviceCache = cache
        viewModel.connectivity = ConnectivityMonitor(offlineGrace: 0)
        viewModel.notificationCenter = center
        let shown = Shown()
        viewModel.onPhaseChange = { shown.phase = $0 }
        viewModel.viewDidLoad()
        #expect(shown.count == 20)
        await network.goOffline(true)
        center.post(name: .viewerDidChange, object: nil)
        #expect(shown.ids.isEmpty)
        #expect(await settle {
            if case .failed = shown.phase { return true }
            return false
        })
        #expect(shown.ids.isEmpty)
    }
}

// MARK: - Bounded lookups

struct LookupCacheTests {
    @Test func aFailedLookupExpires() {
        var cache = LookupCache<String, String>(capacity: 10, failureLifetime: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        cache.record(nil, for: "gone", now: start)
        cache.record("Ava", for: "found", now: start)
        #expect(cache.isKnown("gone", now: start.addingTimeInterval(299)))
        #expect(!cache.isKnown("gone", now: start.addingTimeInterval(301)), "asked again after its lifetime")
        #expect(cache.isKnown("found", now: start.addingTimeInterval(10_000)), "a value does not expire")
        #expect(cache.value(for: "found") == "Ava")
        #expect(cache.value(for: "gone") == nil)
    }

    @Test func itKeepsItsCapacityTheOldestAnswerGoingFirst() {
        var cache = LookupCache<Int, Int>(capacity: 3, failureLifetime: 300)
        let now = Date()
        for key in 1...3 { cache.record(key, for: key, now: now) }
        // Answered again: the newest now.
        cache.record(10, for: 1, now: now)
        cache.record(4, for: 4, now: now)
        #expect(cache.count == 3)
        #expect(!cache.isKnown(2, now: now))
        #expect(cache.value(for: 1) == 10)
        #expect(cache.isKnown(3, now: now))
        #expect(cache.isKnown(4, now: now))
    }
}

/// Fails every profile.v1 call while `failing` is set, the way an
/// unreachable service does; everything else goes to the mock server.
private final class FlakyProfiles: HTTPClientInterface, Sendable {
    let bff: MockBFF
    private let state = Mutex(true)

    init(bff: MockBFF) { self.bff = bff }

    var failing: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        guard failing, request.url.path.contains("ProfileService") else {
            return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
        }
        DispatchQueue.global().async {
            onResponse(HTTPResponse(
                code: .unavailable, headers: [:], message: nil, trailers: [:],
                error: ConnectError(code: .unavailable, message: "down"), tracingInfo: nil
            ))
        }
        return Cancelable {}
    }

    func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
        bff.stream(request: request, responseCallbacks: responseCallbacks)
    }
}

private struct SignedInSession: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(by seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

struct NotificationsLookupExpiryTests {
    @Test func aSenderWhoseProfileFailedIsAskedAgainOnceTheFailureExpires() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockNotificationService(dataset: dataset).register(on: bff)
        let transport = FlakyProfiles(bff: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: transport)
        let clock = TestClock()
        // The viewer resolves before the profiles fail.
        transport.failing = false
        let repository = NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: SignedInSession(),
            now: { clock.now }
        )
        _ = try await repository.unreadCount()
        transport.failing = true

        let failed = try await repository.loadNotifications(limit: 5)
        #expect(failed.allSatisfy { $0.senderName == "Someone" })

        transport.failing = false
        let stillBelieved = try await repository.loadNotifications(limit: 5)
        #expect(stillBelieved.allSatisfy { $0.senderName == "Someone" }, "a failure is believed for a while")

        clock.advance(by: NotificationsRepository.failedLookupLifetime + 1)
        let retried = try await repository.loadNotifications(limit: 5)
        #expect(retried.contains { $0.senderName != "Someone" }, "then asked again")
    }
}

/// Fails every post.v1 call while `failing` is set; everything else goes to
/// the mock server.
private final class FlakyPosts: HTTPClientInterface, Sendable {
    let bff: MockBFF
    private let state = Mutex(false)

    init(bff: MockBFF) { self.bff = bff }

    var failing: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        guard failing, request.url.path.contains("PostService") else {
            return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
        }
        DispatchQueue.global().async {
            onResponse(HTTPResponse(
                code: .notFound, headers: [:], message: nil, trailers: [:],
                error: ConnectError(code: .notFound, message: "not for this viewer"), tracingInfo: nil
            ))
        }
        return Cancelable {}
    }

    func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
        bff.stream(request: request, responseCallbacks: responseCallbacks)
    }
}

/// A post one viewer could not read is not missing for the next (#978).
struct NotificationsLookupViewerChangeTests {
    @Test func aViewerChangeForgetsThePostsThePreviousViewerCouldNotRead() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockNotificationService(dataset: dataset).register(on: bff)
        let transport = FlakyPosts(bff: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: transport)
        let repository = NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            authSession: SignedInSession()
        )

        // Viewer A cannot read the posts the rows are about.
        transport.failing = true
        let asA = try await repository.loadNotifications(limit: 20)
        let aboutPosts = asA.filter { $0.postSubjectID != nil }
        try #require(!aboutPosts.isEmpty, "guard: the mock has notifications about posts")
        #expect(aboutPosts.allSatisfy { $0.subjectPreview == nil })

        // The posts are readable now, but the failure is still believed.
        transport.failing = false
        let stillA = try await repository.loadNotifications(limit: 20)
        #expect(stillA.filter { $0.postSubjectID != nil }.allSatisfy { $0.subjectPreview == nil },
                "guard: a failed lookup is believed within its lifetime")

        // Another viewer: the lookups start over.
        await repository.viewerDidChange(.member(AccountID(MockAuthService.accountID), activeProfile: ProfileID("prof-b")))
        #expect(await repository.lookupCounts.previews == 0, "the previous viewer's lookups were kept")
        let asB = try await repository.loadNotifications(limit: 20)
        #expect(asB.contains { $0.postSubjectID != nil && $0.subjectPreview != nil },
                "B was shown A's missing posts as missing")
    }
}
