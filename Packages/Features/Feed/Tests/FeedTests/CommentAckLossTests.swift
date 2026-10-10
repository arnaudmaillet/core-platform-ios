import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

/// ⚠️ **A LOST ANSWER IS NOT A LOST WRITE (#795).** The server can take a
/// comment and the answer never arrive: the client sees a failure, the viewer
/// sends it again, and without a key the post carries it twice. These lose
/// the answer on purpose, against the mock BFF.
struct CommentAckLossTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// Hands every call to the mock BFF — so the write is applied — and,
    /// while `losses` lasts, swaps the answer of a CreateComment for a
    /// transport failure: the server did it, the client never heard.
    private final class AckLosingRelay: HTTPClientInterface, @unchecked Sendable {
        private let bff: MockBFF
        private let lock = NSLock()
        private var losses: Int

        init(_ bff: MockBFF, losing losses: Int) {
            self.bff = bff
            self.losses = losses
        }

        @discardableResult
        func unary(
            request: HTTPRequest<Data?>,
            onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
            onResponse: @escaping @Sendable (HTTPResponse) -> Void
        ) -> Cancelable {
            let loses = request.url.path.hasSuffix("/CreateComment") && lock.withLock {
                guard losses > 0 else { return false }
                losses -= 1
                return true
            }
            guard loses else { return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse) }
            return bff.unary(request: request, onMetrics: onMetrics) { _ in
                let lost = ConnectError(code: .unavailable, message: "the answer was lost")
                onResponse(HTTPResponse(
                    code: lost.code, headers: [:], message: nil, trailers: [:], error: lost, tracingInfo: nil
                ))
            }
        }

        func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
            bff.stream(request: request, responseCallbacks: responseCallbacks)
        }
    }

    private func repository(losing losses: Int) -> CommentsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(
            host: "https://mock.bff.local", httpClient: AckLosingRelay(bff, losing: losses)
        )
        return CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session()
        )
    }

    /// The retry goes under the same `comment_id`, and the mock answers it
    /// with the comment it already took: one comment, not two.
    @Test func aRetryAfterALostAnswerPostsTheCommentOnce() async throws {
        let repository = repository(losing: 1)
        let post = PostID("post-0001")
        let before = try await repository.loadComments(for: post).count

        await #expect(throws: CommentsError.self) {
            _ = try await repository.addComment("Only once", to: post, parentID: nil, commentID: "draft-1")
        }
        let retried = try await repository.addComment("Only once", to: post, parentID: nil, commentID: "draft-1")

        #expect(retried.id == "draft-1")
        let after = try await repository.loadComments(for: post)
        #expect(after.count == before + 1, "the retry posted a twin: \(after.map(\.body))")
        #expect(after.filter { $0.body == "Only once" }.count == 1)
    }

    /// The other half: a NEW comment with the same words is not a replay.
    /// Without this, a mock that deduplicated on the text would pass above.
    @Test func theSameWordsUnderANewIdAreANewComment() async throws {
        let repository = repository(losing: 0)
        let post = PostID("post-0001")
        let before = try await repository.loadComments(for: post).count

        _ = try await repository.addComment("Again", to: post, parentID: nil, commentID: "draft-a")
        _ = try await repository.addComment("Again", to: post, parentID: nil, commentID: "draft-b")

        #expect(try await repository.loadComments(for: post).count == before + 2)
    }
}
