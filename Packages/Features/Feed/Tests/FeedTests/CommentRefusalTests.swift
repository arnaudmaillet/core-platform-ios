import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

private struct SessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

/// A comment outside the post author's "Who Can Comment" (#397) is refused
/// by the server, and the app says so instead of dropping it silently.
struct CommentRefusalTests {
    private func makeRepository(mayComment: @escaping @Sendable (String, String) -> Bool) -> (CommentsRepository, MockSocialDataset) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset, mayComment: mayComment).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: SessionStub()
        )
        return (repository, dataset)
    }

    @Test func aRefusedCommentReadsAsNotAllowed() async throws {
        let (repository, dataset) = makeRepository { _, _ in false }
        let post = try #require(dataset.posts.first { $0.authorProfileID != MockSocialDataset.viewerProfileID })
        await #expect(throws: CommentsError.notAllowed) {
            _ = try await repository.addComment("Nice", to: PostID(post.postID), parentID: nil)
        }
    }

    /// Your own post always takes your comments.
    @Test func yourOwnPostAlwaysTakesYourComment() async throws {
        let (repository, dataset) = makeRepository { _, _ in false }
        let post = try #require(dataset.posts.first { $0.authorProfileID == MockSocialDataset.viewerProfileID })
        let entry = try await repository.addComment("Mine", to: PostID(post.postID), parentID: nil)
        #expect(entry.body == "Mine")
    }

    @MainActor
    @Test func theNoticeSaysWhy() {
        #expect(PostDetailViewController.commentFailureNotice(refused: true).title == "Comments Are Limited")
        #expect(PostDetailViewController.commentFailureNotice(refused: false).message.contains("still here"))
    }
}
