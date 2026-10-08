import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Notifications

private struct SignedIn: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

/// Push notifications (#651): what a push says to open, and this install's
/// registration with the notification service.
struct PushNotificationsTests {
    // MARK: - The payload

    /// backend#839's shape: the subject decides where a tap goes.
    @Test func aPushNamesTheSubjectToOpen() throws {
        let post = try #require(PushPayload(userInfo: [
            "aps": ["alert": ["loc-key": "NTF_PUSH_REACTION", "loc-args": ["Alice"]]],
            "notification_id": "n-1", "kind": "reaction",
            "subject_kind": "post", "subject_id": "post-0001"
        ]))
        #expect(post.destination == .post(PostID("post-0001")))
        #expect(post.kind == "reaction")
        #expect(post.notificationID == "n-1")

        #expect(PushPayload(userInfo: ["subject_kind": "comment", "subject_id": "c-9"])?.destination
                == .comment("c-9"))
        #expect(PushPayload(userInfo: ["subject_kind": "profile", "subject_id": "prof-2"])?.destination
                == .profile(ProfileID("prof-2")))
    }

    /// Anything else is not this service's push, or names nothing to open.
    @Test func anythingElseOpensNothing() {
        #expect(PushPayload(userInfo: [:]) == nil)
        #expect(PushPayload(userInfo: ["subject_kind": "post"]) == nil, "no subject id")
        #expect(PushPayload(userInfo: ["subject_kind": "post", "subject_id": ""]) == nil)
        #expect(PushPayload(userInfo: ["subject_kind": "story", "subject_id": "s-1"]) == nil, "an unknown kind")
    }

    // MARK: - Registration, through the real clients

    private func makeRepository() -> (NotificationsRepository, MockNotificationService) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        let notifications = MockNotificationService(dataset: dataset)
        notifications.register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: SignedIn()
        )
        return (repository, notifications)
    }

    /// The token goes up for the active profile, as an iOS device in the
    /// build's APNs environment, with the install's own id and its time zone.
    @Test func registeringSendsTheTokenForTheActiveProfile() async throws {
        let (repository, service) = makeRepository()
        let profile = try await repository.activeProfileIDForWrite("test")

        try await repository.registerPushDevice(token: "abc123", deviceID: "install-1", environment: .sandbox)

        let registered = try #require(service.registeredDevice(profileID: profile.rawValue, deviceID: "install-1"))
        #expect(registered.token == "abc123")
        #expect(registered.platform == .ios)
        #expect(registered.environment == .sandbox)
        #expect(registered.timezone == TimeZone.current.identifier)
    }

    /// Signing out takes this install off the profile's pushes.
    @Test func unregisteringStopsThePushes() async throws {
        let (repository, service) = makeRepository()
        let profile = try await repository.activeProfileIDForWrite("test")
        try await repository.registerPushDevice(token: "abc123", deviceID: "install-1", environment: .production)
        #expect(service.registeredDevice(profileID: profile.rawValue, deviceID: "install-1")?.environment == .production)

        try await repository.unregisterPushDevice(deviceID: "install-1")

        #expect(service.registeredDevice(profileID: profile.rawValue, deviceID: "install-1") == nil)
    }
}
