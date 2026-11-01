import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Notifications

private struct AuthenticatedSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

/// Fails every call whose path contains `pathContains` ("" = every call) the
/// way Connect-Swift's URLSession client does with no connection: an
/// `unavailable` CARRYING the `URLError` in `exception` (#794). Everything
/// else goes to the wrapped mock server.
///
/// ⚠️ A wrapper, not `MockBFF.simulatedConditions`: the mock's injected
/// faults are bare codes with no `URLError`, which correctly read as a server
/// outage, not as offline. One per repository, never process-wide.
private struct OfflineTransport: HTTPClientInterface {
    let bff: MockBFF
    let pathContains: String

    func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        guard pathContains.isEmpty || request.url.path.contains(pathContains) else {
            return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
        }
        let error = ConnectError(
            code: .unavailable,
            message: "The Internet connection appears to be offline.",
            exception: URLError(.notConnectedToInternet)
        )
        // Off the caller's stack, as URLSession (and MockBFF) deliver.
        DispatchQueue.global().async {
            onResponse(HTTPResponse(
                code: .unavailable, headers: [:], message: nil, trailers: [:], error: error, tracingInfo: nil
            ))
        }
        return Cancelable {}
    }

    func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
        bff.stream(request: request, responseCallbacks: responseCallbacks)
    }
}

/// Drives the read path — repository → generated clients → real ProtocolClient
/// → MockBFF — with production wire bytes, in-process.
struct NotificationsRepositoryTests {
    private func makeRepository(
        withPosts: Bool = true,
        offlineFor offlinePath: String? = nil,
        clears: Bool = false
    ) -> NotificationsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff) // viewer, senders, posts
        let service = MockNotificationService(dataset: dataset)
        service.register(on: bff)
        let transport: any HTTPClientInterface = offlinePath.map { OfflineTransport(bff: bff, pathContains: $0) } ?? bff
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: transport)
        // The app's mock-mode clear (#1574), reaching the mock directly.
        let clear: NotificationsClearing? = clears ? { @Sendable profileID, bound in
            service.clear(
                profileID: profileID, newestID: bound.newestID,
                throughMs: Int64(bound.newestCreatedAt.timeIntervalSince1970 * 1_000)
            )
        } : nil
        return NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            postClient: withPosts ? Post_V1_PostServiceClient(client: client) : nil,
            authSession: AuthenticatedSessionStub(),
            clear: clear
        )
    }

    /// Clear all (#1574), against the mock: the rows up to the bound go, the
    /// unread count follows, and a row newer than the bound survives.
    @Test func aClearDeletesUpToItsBoundAndTheCountFollows() async throws {
        let repository = makeRepository(clears: true)
        let before = try await repository.loadNotifications(limit: 100)
        try #require(before.count > 3, "guard: rows to clear")
        // Bounded by the third row: the two newer ones are "arrivals".
        let bound = NotificationsClearBound(newestID: before[2].id, newestCreatedAt: before[2].createdAt)

        try await repository.clearAll(through: bound)

        let after = try await repository.loadNotifications(limit: 100)
        #expect(after.map(\.id) == before.prefix(2).map(\.id), "only the rows newer than the bound remain")
        let unread = try await repository.unreadCount()
        #expect(unread == after.filter { !$0.isRead }.count)
    }

    /// Without a server clear (the fleet, until backend #971) it says so.
    @Test func aClearWithoutTheServersIsUnsupported() async throws {
        let repository = makeRepository()
        let bound = NotificationsClearBound(newestID: "notif-0", newestCreatedAt: Date())
        await #expect(throws: NotificationsError.unsupported) {
            try await repository.clearAll(through: bound)
        }
    }

    @Test func loadsAndHydratesSenders() async throws {
        let repository = makeRepository()

        let items = try await repository.loadNotifications(limit: 50)

        // Enough new rows to exercise "Show more", and some already read.
        #expect(items.filter { !$0.isRead }.count > NotificationSectionBuilder.sectionLimit + 1)
        #expect(items.contains { $0.isRead })
        // Sender names are hydrated from profile.v1, not left as ids.
        let first = try #require(items.first)
        #expect(first.action == .reaction)
        #expect(!first.senderName.isEmpty)
        #expect(first.senderName != first.senderID.rawValue)
        #expect(first.postSubjectID != nil) // subject is a post → routes to .post
        // …and so are their pictures: a real photograph or none at all.
        #expect(items.contains { $0.senderAvatarURL != nil })
        #expect(items.contains { $0.senderAvatarURL == nil })
    }

    @Test func aggregatedNotificationsCarryTheirCountAndASecondFace() async throws {
        let repository = makeRepository()

        let items = try await repository.loadNotifications(limit: 50)

        let aggregated = try #require(items.first { $0.otherSenderCount > 0 })
        #expect(aggregated.otherSenderCount == 4)
        // The server's sample leads with the primary; the repository keeps the
        // OTHERS, hydrated, for the stacked avatar.
        let second = try #require(aggregated.sampleSenders.first)
        #expect(second.id != aggregated.senderID)
        #expect(!second.name.isEmpty)
    }

    /// Media posts bring a still, text posts their words.
    @Test func subjectPostsArePreviewed() async throws {
        let items = try await makeRepository().loadNotifications(limit: 50)
        #expect(items.contains { $0.subjectPreview?.thumbnailURL != nil })
        #expect(items.contains { $0.subjectPreview?.excerpt?.isEmpty == false })
    }

    /// A post the server no longer shows the viewer (#447: taken down,
    /// backend #688, or withheld) keeps its row — the thing happened — but
    /// shows nothing of the post: `GetPost` answers not found, and a tap
    /// opens a detail that reads "This post isn't available". The mock's
    /// notifications are about the viewer's own posts, which their author
    /// always reads, so `GetPost` is made to answer as it does for a post
    /// taken down under someone else.
    /// ⚠️ A SENDER IS KNOWN THE NEXT TIME THEY ARE OPENED (#1858): every
    /// sender the page hydrated is reported, with the handle the row drops.
    @Test func theSendersAreReported() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockNotificationService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let people = RecordedNotificationPeople()
        let repository = NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: AuthenticatedSessionStub(),
            people: people
        )
        let items = try await repository.loadNotifications(limit: 20)
        try #require(!items.isEmpty)
        for item in items where !item.senderID.rawValue.isEmpty {
            let person = try #require(people.seen.first { $0.id == item.senderID }, "\(item.senderID) not reported")
            #expect(person.displayName == item.senderName)
            #expect(person.avatarURL == item.senderAvatarURL)
            #expect(!person.handle.isEmpty, "the handle the row drops")
        }
    }

    /// One profile of the account's unread count (#2034): `GetUnreadCount`
    /// with that profile's id, not the active one's.
    @Test func theUnreadCountOfAGivenProfile() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockNotificationService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: AuthenticatedSessionStub()
        )
        for (profile, count) in MockNotificationService.otherProfileUnread {
            #expect(try await repository.unreadCount(forProfile: ProfileID(profile)) == Int(count), "\(profile)")
        }
        let active = try await repository.unreadCount()
        #expect(try await repository.unreadCount(forProfile: ProfileID(MockSocialDataset.viewerProfileID)) == active)
    }

    @Test func aSubjectTheServerNoLongerShowsKeepsItsRowWithoutAPreview() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockNotificationService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        func repository() -> NotificationsRepository {
            NotificationsRepository(
                notificationClient: Notification_V1_NotificationServiceClient(client: client),
                profileClient: Profile_V1_ProfileServiceClient(client: client),
                postClient: Post_V1_PostServiceClient(client: client),
                authSession: AuthenticatedSessionStub()
            )
        }
        let before = try await repository().loadNotifications(limit: 50)
        let previewed = try #require(before.first { $0.subjectPreview != nil })

        bff.register(path: "/post.v1.PostService/GetPost") { (request: Post_V1_GetPostRequest) -> Result<Post_V1_PostView, ConnectError> in
            .failure(ConnectError(code: .notFound, message: "PST-1001: post \(request.postID) not found"))
        }
        let after = try await repository().loadNotifications(limit: 50)
        let row = try #require(after.first { $0.id == previewed.id })
        #expect(row.postSubjectID == previewed.postSubjectID)
        #expect(row.subjectPreview == nil)
    }

    @Test func withoutAPostClientRowsSimplyHaveNoPreview() async throws {
        let items = try await makeRepository(withPosts: false).loadNotifications(limit: 50)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.subjectPreview == nil })
    }

    /// Page by page (#608): the first page sends the page size, the next the
    /// token the last returned, until there is none — and the pages add up to
    /// the whole list, in order, with nothing twice.
    @Test func pagesFollowTheTokenToTheEnd() async throws {
        let repository = makeRepository()

        let whole = try await repository.loadNotifications(limit: 500, after: nil)
        #expect(whole.nextPageToken == nil)
        #expect(whole.items.count > 20) // the fixture needs more than one drawer page

        var paged: [NotificationItem] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await repository.loadNotifications(limit: 20, after: token)
            #expect(page.items.count <= 20)
            paged += page.items
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 10
        #expect(pages >= 2)
        #expect(paged.map(\.id) == whole.items.map(\.id))
    }

    @Test func markAllReadClearsTheCountAndTheList() async throws {
        let repository = makeRepository()

        let unread = try await repository.unreadCount()
        #expect(unread > 0)
        try await repository.markAllRead()
        #expect(try await repository.unreadCount() == 0)
        let items = try await repository.loadNotifications(limit: 50)
        #expect(items.allSatisfy { $0.isRead })
    }

    /// The mute toolbar's pause (#1575) is the server's "pause all": what it
    /// sends reads back — a day long, indefinite, resumed — the field
    /// Settings → Notifications reads too.
    @Test func thePushPauseRoundTrips() async throws {
        let repository = makeRepository()
        #expect(try await repository.pushPause() == .off)

        let tomorrow = Date().addingTimeInterval(24 * 3_600)
        guard case .until(let held) = try await repository.setPushPause(.until(tomorrow)) else {
            Issue.record("a day's pause did not hold")
            return
        }
        #expect(abs(held.timeIntervalSince(tomorrow)) < 1)
        #expect(try await repository.pushPause() == .until(held))

        #expect(try await repository.setPushPause(.indefinite) == .indefinite)
        #expect(try await repository.pushPause() == .indefinite)

        #expect(try await repository.setPushPause(.off) == .off)
        #expect(try await repository.pushPause() == .off)
    }

    // MARK: - Why a call failed (#794)

    /// Connect answers a lost connection with `unavailable`. The
    /// `NotificationsError` it becomes must still say offline, or the screen
    /// can only ever say "couldn't load".
    @Test func aLostConnectionStaysOfflineThroughTheRepositoryError() async {
        let repository = makeRepository(offlineFor: "NotificationService")

        let error = await #expect(throws: NotificationsError.self) {
            _ = try await repository.loadNotifications(limit: 50)
        }

        #expect(error?.networkFailure == .offline)
        #expect(error.flatMap { NetworkFailure.of($0) } == .offline)
    }

    /// The viewer lookup fails first when every route is down: the failure
    /// survives `AccountProfilesReader.ReadError` on its way to the feature
    /// error too.
    @Test func aLostConnectionStaysOfflineThroughTheViewerLookup() async {
        let repository = makeRepository(offlineFor: "")

        let error = await #expect(throws: NotificationsError.self) {
            _ = try await repository.loadNotifications(limit: 50)
        }

        #expect(error?.networkFailure == .offline)
    }
}

/// What a writer reported (#1858).
private final class RecordedNotificationPeople: PeopleSightings, @unchecked Sendable {
    private let lock = NSLock()
    private var sightings: [AuthorSummary] = []
    func saw(_ people: [AuthorSummary]) { lock.withLock { sightings += people } }
    func loaded(_ person: AuthorSummary) { lock.withLock { sightings.append(person) } }
    var seen: [AuthorSummary] { lock.withLock { sightings } }
}
