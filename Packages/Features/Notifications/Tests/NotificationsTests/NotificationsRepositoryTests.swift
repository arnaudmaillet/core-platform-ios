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
    private func makeRepository() -> NotificationsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff) // viewer resolve + sender hydration
        MockNotificationService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: AuthenticatedSessionStub()
        )
    }

    @Test func loadsAndHydratesSenderNames() async throws {
        let repository = makeRepository()

        let items = try await repository.loadNotifications(limit: 50)

        #expect(items.count == 4)
        // Sender names are hydrated from profile.v1, not left as ids.
        let first = try #require(items.first)
        #expect(first.action == .reaction)
        #expect(!first.senderName.isEmpty)
        #expect(first.senderName != first.senderID.rawValue)
        #expect(first.postSubjectID != nil) // subject is a post → routes to .post
        #expect(first.isRead == false)
    }

    @Test func aggregatedNotificationCarriesOtherSenderCount() async throws {
        let repository = makeRepository()

        let items = try await repository.loadNotifications(limit: 50)

        // The third fixture is an aggregate of 4 senders.
        let aggregated = try #require(items.first { $0.otherSenderCount > 0 })
        #expect(aggregated.otherSenderCount == 3)
    }

    @Test func markAllReadSucceeds() async throws {
        let repository = makeRepository()
        try await repository.markAllRead()
    }

    @Test func unreadCountReflectsMarkAllRead() async throws {
        let repository = makeRepository()

        #expect(try await repository.unreadCount() == 2)
        try await repository.markAllRead()
        #expect(try await repository.unreadCount() == 0)
    }
}
