import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Privacy → Who Can Comment (#397, backend #714).
@MainActor
struct CommentAudienceTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// Everyone by default; a change sticks and leaves the other settings
    /// (mentions, messages, downloads, like counts) as they were.
    @Test func theAudienceRoundTripsAndKeepsTheRest() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let profileClient = Profile_V1_ProfileServiceClient(client: client)
        let repository = ProfileRepository(
            profileClient: profileClient,
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )

        #expect(try await repository.commentAudience() == .everyone)
        try await repository.setCommentAudience(.mutuals)
        #expect(try await repository.commentAudience() == .mutuals)

        var get = Profile_V1_GetProfileByIdRequest()
        get.profileID = MockSocialDataset.viewerProfileID
        let settings = try await profileClient.getProfileByID(request: get, headers: [:]).result.get().interactionSettings
        #expect(settings.mentions == .everyone)
        #expect(settings.messages == .everyone)
        #expect(settings.allowDownloads)
        #expect(settings.showLikeCounts)
    }

    @Test func theChoicesReadPlainly() {
        #expect(CommentAudience.allCases.map(\.title) == ["Everyone", "Followers", "Friends", "No One"])
    }
}
