import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Privacy → Who Can Mention and Who Can Message (#397, backend
/// #656), over the mock.
@MainActor
struct MentionMessageAudienceTests {
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

    /// Everyone by default; each change sticks and leaves the other settings
    /// — who can comment, like counts — as they were.
    @Test func eachAudienceRoundTripsAndKeepsTheRest() async throws {
        let repository = makeRepository()
        try await repository.setCommentAudience(.followers)
        try await repository.setPostSharing(PostSharing(showsLikeCounts: false, allowsDownloads: true))
        #expect(try await repository.audience(for: .mentions) == .everyone)
        #expect(try await repository.audience(for: .messages) == .everyone)

        try await repository.setAudience(.mutuals, for: .mentions)
        try await repository.setAudience(.noOne, for: .messages)
        #expect(try await repository.audience(for: .mentions) == .mutuals)
        #expect(try await repository.audience(for: .messages) == .noOne)
        #expect(try await repository.commentAudience() == .followers)
        #expect(try await repository.postSharing() == PostSharing(showsLikeCounts: false, allowsDownloads: true))
    }

    @Test func thePrivacyScreenReadsAndWritesThem() async throws {
        let repository = makeRepository()
        let viewModel = PrivacySectionViewModel(visibility: repository, audiences: repository)
        await viewModel.load()
        for _ in 0..<2_000 where viewModel.mentionAudience == nil || viewModel.messageAudience == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(viewModel.mentionAudience == .everyone)
        #expect(viewModel.messageAudience == .everyone)

        try await viewModel.setAudience(.followers, for: .messages)
        #expect(viewModel.messageAudience == .followers)
        #expect(try await repository.audience(for: .messages) == .followers)
    }
}
