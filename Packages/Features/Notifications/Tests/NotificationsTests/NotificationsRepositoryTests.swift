import AuthInterface
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

/// Drives the read path — repository → generated clients → real ProtocolClient
/// → MockBFF — with production wire bytes, in-process.
struct NotificationsRepositoryTests {
    private func makeRepository(withPosts: Bool = true) -> NotificationsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff) // viewer, senders, posts
        MockNotificationService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
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

    @Test func markAllReadClearsTheCountAndTheList() async throws {
        let repository = makeRepository()

        let unread = try await repository.unreadCount()
        #expect(unread > 0)
        try await repository.markAllRead()
        #expect(try await repository.unreadCount() == 0)
        let items = try await repository.loadNotifications(limit: 50)
        #expect(items.allSatisfy { $0.isRead })
    }
}
