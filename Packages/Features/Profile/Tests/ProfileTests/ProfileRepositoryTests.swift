import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

private struct AuthenticatedSessionStub: AuthSessionProviding {
    var accountID = AccountID(MockAuthService.accountID)

    func currentState() async -> AuthState { .authenticated(accountID) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(accountID)); $0.finish() }
    }
    func logout() async {}
}

private struct UnauthenticatedSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .unauthenticated }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.unauthenticated); $0.finish() }
    }
    func logout() async {}
}

/// Drives the full read path — repository → generated clients → real
/// ProtocolClient → MockBFF — with production wire bytes, in-process.
struct ProfileRepositoryTests {
    private func makeRepository(
        session: any AuthSessionProviding = AuthenticatedSessionStub(),
        dataset: MockSocialDataset = MockSocialDataset()
    ) -> ProfileRepository {
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: session
        )
    }

    @Test func resolvesViewerIdentityFromAccount() async throws {
        let repository = makeRepository()

        let profile = try await repository.currentUserProfile()

        // account → ListProfilesByAccount → GetProfileById, end to end.
        #expect(profile.id == ProfileID(MockSocialDataset.viewerProfileID))
        #expect(profile.handle == "you")
        #expect(profile.displayName == "Demo Viewer")
    }

    @Test func fetchesAnyProfileByID() async throws {
        // Routing to another user resolves their view directly (no account hop).
        let repository = makeRepository()

        let profile = try await repository.profile(id: ProfileID(MockSocialDataset.viewerProfileID))

        #expect(profile.id == ProfileID(MockSocialDataset.viewerProfileID))
        #expect(profile.handle == "you")
    }

    @Test func degradesToUnavailableWhenNeitherSourceHasCounts() async throws {
        // MockBFF serves only LIKE on counter.v1 and has no social_graph route,
        // so both the primary read and the fallback come up empty; the
        // repository must surface `.unavailable` (rendered "—"), never `.exact(0)`.
        let repository = makeRepository()

        let profile = try await repository.currentUserProfile()

        #expect(profile.followerCount == .unavailable)
        #expect(profile.followingCount == .unavailable)
    }

    @Test func throwsWhenNotAuthenticated() async {
        let repository = makeRepository(session: UnauthenticatedSessionStub())

        await #expect(throws: ProfileError.notAuthenticated) {
            _ = try await repository.currentUserProfile()
        }
    }
}
