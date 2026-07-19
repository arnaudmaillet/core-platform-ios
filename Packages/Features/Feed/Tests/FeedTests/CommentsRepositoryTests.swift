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

    // post-0001 carries the mock's default sparse seed; post-0000 is one of
    // the densely-seeded ticker posts and is covered separately below.
    @Test func loadsAndHydratesAuthorNames() async throws {
        let repository = makeRepository()

        let comments = try await repository.loadComments(for: PostID("post-0001"))

        #expect(comments.count == 2)
        let first = try #require(comments.first)
        #expect(!first.authorName.isEmpty)
        #expect(first.authorName != first.authorID.rawValue) // hydrated, not an id
        #expect(!first.body.isEmpty)
    }

    @Test func addingACommentReturnsTheCreatedEntry() async throws {
        let repository = makeRepository()

        let created = try await repository.addComment("Great post!", to: PostID("post-0001"))

        #expect(created.body == "Great post!")
        #expect(!created.authorName.isEmpty)

        // The new comment persists and appears first on reload.
        let comments = try await repository.loadComments(for: PostID("post-0001"))
        #expect(comments.first?.body == "Great post!")
        #expect(comments.count == 3)
    }

    /// The mock's densely-seeded posts must clear BOTH comment surfaces'
    /// engagement gates end-to-end: repository load → builders → non-empty
    /// queue and cue list, partitioned with no overlap. post-0006's reaction
    /// slice includes all three deliberately disqualified bodies (over-length,
    /// embedded newline, semantic phrase past the word cap), so it also
    /// proves the filters: the newline body vanishes (collapsed, it's
    /// band-shaped — and the band takes no newlines), while the other two are
    /// semantic and land in the subtitle zone with the six seeded sentences.
    @Test func denselySeededPostFeedsBothSurfaces() async throws {
        let repository = makeRepository()

        let comments = try await repository.loadComments(for: PostID("post-0006"))
        // 18 reactions + 6 semantic seeds + 3 level-2 replies (threaded
        // in place under their parents by the repository).
        #expect(comments.count == 27)
        // The replies sit directly under their parents, marked as level 2.
        let replies = comments.filter { $0.parentID != nil }
        #expect(replies.count == 3)
        for reply in replies {
            let parentIndex = try #require(comments.firstIndex { $0.id == reply.parentID })
            let replyIndex = try #require(comments.firstIndex { $0.id == reply.id })
            #expect(replyIndex > parentIndex)
        }

        let queue = CommentTickerBuilder().build(comments, postID: PostID("post-0006"))
        // 27 − 3 disqualified reaction-bank bodies − 6 semantic seeds − 2
        // semantic replies (the reaction reply "fr fr 🔥" joins the band).
        #expect(queue.count == comments.count - 11)
        #expect(queue.count >= CommentTickerBuilder.minTickerCount)
        #expect(queue.allSatisfy { $0.text.count <= CommentTickerBuilder.maxCharacterCount })
        #expect(queue.allSatisfy { !$0.text.contains(where: \.isNewline) })

        let cues = SubtitleCommentBuilder().build(comments, postID: PostID("post-0006"))
        // 6 semantic seeds + the 2 semantic bodies in the reaction bank +
        // the 2 sentence-shaped replies.
        #expect(cues.count == 10)
        #expect(cues.count >= SubtitleCommentBuilder.minCueCount)
        #expect(Set(cues.map(\.id)).isDisjoint(with: queue.map(\.id))) // one comment, one surface
        #expect(cues.allSatisfy { !$0.text.contains(where: \.isNewline) })
    }
}
