import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Privacy → Show Like Counts and Allow Downloads (#397, backend
/// #809), over the mock.
@MainActor
struct PostSharingTests {
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

    /// Both on by default; each change sticks and leaves the other settings
    /// — who can comment included — as they were.
    @Test func eachSwitchRoundTripsAndKeepsTheRest() async throws {
        let repository = makeRepository()
        try await repository.setCommentAudience(.followers)
        #expect(try await repository.postSharing() == PostSharing(showsLikeCounts: true, allowsDownloads: true))

        try await repository.setPostSharing(PostSharing(showsLikeCounts: false, allowsDownloads: true))
        #expect(try await repository.postSharing() == PostSharing(showsLikeCounts: false, allowsDownloads: true))

        try await repository.setPostSharing(PostSharing(showsLikeCounts: false, allowsDownloads: false))
        #expect(try await repository.postSharing() == PostSharing(showsLikeCounts: false, allowsDownloads: false))
        #expect(try await repository.commentAudience() == .followers)

        // And who can comment keeps them in turn.
        try await repository.setCommentAudience(.everyone)
        #expect(try await repository.postSharing() == PostSharing(showsLikeCounts: false, allowsDownloads: false))
    }

    /// The screen's state follows the server: it reads both, and a change
    /// shows once it is stored.
    @Test func thePrivacyScreenReadsAndWritesThem() async throws {
        let repository = makeRepository()
        let viewModel = PrivacySectionViewModel(visibility: repository, sharing: repository)
        await viewModel.load()
        for _ in 0..<2_000 where viewModel.postSharing == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(viewModel.postSharing == PostSharing(showsLikeCounts: true, allowsDownloads: true))

        try await viewModel.setPostSharing(PostSharing(showsLikeCounts: true, allowsDownloads: false))
        #expect(viewModel.postSharing?.allowsDownloads == false)
        #expect(try await repository.postSharing().allowsDownloads == false)
    }
}
