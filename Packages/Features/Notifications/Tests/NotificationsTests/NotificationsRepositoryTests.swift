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
        offlineFor offlinePath: String? = nil
    ) -> NotificationsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff) // viewer, senders, posts
        MockNotificationService(dataset: dataset).register(on: bff)
        let transport: any HTTPClientInterface = offlinePath.map { OfflineTransport(bff: bff, pathContains: $0) } ?? bff
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: transport)
        return NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            postClient: withPosts ? Post_V1_PostServiceClient(client: client) : nil,
            authSession: AuthenticatedSessionStub()
        )
    }

    @Test func loadsAndHydratesSenders() async throws {
        let repository = makeRepository()

        let items = try await repository.loadNotifications(limit: 50)

        // Enough new rows to exercise "Show more", and some already read.
        #expect(items.filter { !$0.isRead }.count > NotificationSectionBuilder.newLimit + 1)
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
