import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → What You See (#407, backend #731): sensitive content, synced
/// on the profile, and how the feeds are ordered.
@MainActor
struct WhatYouSeeTests {
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

    /// Less by default; Standard sticks, and it's per profile.
    @Test func sensitiveContentRoundTripsPerProfile() async throws {
        let repository = makeRepository()
        #expect(try await repository.sensitiveContent() == .less)
        try await repository.setSensitiveContent(.standard)
        #expect(try await repository.sensitiveContent() == .standard)

        let profiles = try await repository.accountProfiles()
        await repository.setActiveProfile(profiles[1].id)
        #expect(try await repository.sensitiveContent() == .less, "another profile keeps its own")
        try await repository.setSensitiveContent(.standard)
        try await repository.setSensitiveContent(.less)
        #expect(try await repository.sensitiveContent() == .less)
    }

    @Test func theScreenSaysHowTheFeedsAreOrdered() {
        #expect(SensitiveContentLevel.allCases.map(\.title) == ["Less", "Standard"])
        #expect(SensitiveContentLevel.standard.detail.contains("under 18"))
        // Done when: the chronological option shows followed posts newest first.
        #expect(WhatYouSeeViewController.followingDetail.contains("newest first"))
        #expect(WhatYouSeeViewController.forYouDetail.contains("same way for everyone"))
        #expect(WhatYouSeeViewController.footer(.sensitive, teen: true).contains("under 18"))
        #expect(WhatYouSeeViewController.footer(.ordering, teen: false).contains("nothing to reset"))
    }
}
