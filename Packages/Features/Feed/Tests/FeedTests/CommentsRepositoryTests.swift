import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

private struct AuthenticatedSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

struct CommentsRepositoryTests {
    private func makeRepository() -> CommentsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff) // viewer resolve + author hydration
        MockCommentService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: AuthenticatedSessionStub()
        )
    }

    @Test func loadsAndHydratesAuthorNames() async throws {
        let repository = makeRepository()

        let comments = try await repository.loadComments(for: PostID("post-0000"))

        #expect(comments.count == 2)
        let first = try #require(comments.first)
        #expect(!first.authorName.isEmpty)
        #expect(first.authorName != first.authorID.rawValue) // hydrated, not an id
        #expect(!first.body.isEmpty)
    }

    @Test func addingACommentReturnsTheCreatedEntry() async throws {
        let repository = makeRepository()

        let created = try await repository.addComment("Great post!", to: PostID("post-0000"))

        #expect(created.body == "Great post!")
        #expect(!created.authorName.isEmpty)

        // The new comment persists and appears first on reload.
        let comments = try await repository.loadComments(for: PostID("post-0000"))
        #expect(comments.first?.body == "Great post!")
        #expect(comments.count == 3)
    }
}
