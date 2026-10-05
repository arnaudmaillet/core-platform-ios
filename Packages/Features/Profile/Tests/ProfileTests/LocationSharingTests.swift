import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Privacy → Location Sharing (#398; backend #717, #718).
@MainActor
struct LocationSharingTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func makeRepository() -> ProfileRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
    }

    /// Not ghosted and precise by default; both stick, per profile.
    @Test func settingsRoundTripPerProfile() async throws {
        let repository = makeRepository()
        #expect(try await repository.locationSharing() == LocationSharingSettings(ghost: false, cityLevel: false))

        try await repository.setLocationSharing(LocationSharingSettings(ghost: true, cityLevel: true))
        #expect(try await repository.locationSharing() == LocationSharingSettings(ghost: true, cityLevel: true))

        let profiles = try await repository.accountProfiles()
        await repository.setActiveProfile(profiles[1].id)
        #expect(try await repository.locationSharing() == LocationSharingSettings(), "another profile keeps its own")
    }

    @Test func theScreenExplains() {
        #expect(LocationSharingViewController.footer(.ghost).contains("leave everyone else's map"))
        #expect(LocationSharingViewController.footer(.precision).contains("never at the exact spot"))
        #expect(LocationSharingViewController.planned == ["Who can see your location", "Add your location to new posts by default"])
    }
}
