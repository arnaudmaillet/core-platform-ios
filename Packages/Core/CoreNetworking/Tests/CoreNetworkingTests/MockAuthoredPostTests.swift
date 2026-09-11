import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

/// A post authored this session did not exist when the comment seed was
/// written, so it opens with NO comments — the way a post just published on the
/// fleet does — and what is commented on it afterwards stays.
///
/// It used to fall through to the sparse seed like any other post, and the Text
/// Post page's freshly published post opened on two strangers' comments.
struct MockAuthoredPostTests {
    private struct Harness {
        let posts: Post_V1_PostServiceClient
        let comments: Comment_V1_CommentServiceClient
    }

    private func makeHarness() -> Harness {
        let bff = MockBFF()
        let dataset = MockSocialDataset()
        let postStore = MockPostStore()
        MockSocialServices(dataset: dataset, postStore: postStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)
        MockCommentService(dataset: dataset, postStore: postStore).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return Harness(
            posts: Post_V1_PostServiceClient(client: client),
            comments: Comment_V1_CommentServiceClient(client: client)
        )
    }

    private func publishTextPost(_ harness: Harness) async throws -> String {
        var create = Post_V1_CreatePostRequest()
        create.profileID = MockSocialDataset.viewerProfileID
        create.kind = .textOnly
        create.caption = "Fresh off the press"
        let created = try await harness.posts.createPost(request: create, headers: [:]).result.get()
        var publish = Post_V1_PublishPostRequest()
        publish.postID = created.postID
        publish.profileID = MockSocialDataset.viewerProfileID
        _ = try await harness.posts.publishPost(request: publish, headers: [:]).result.get()
        return created.postID
    }

    private func topLevel(_ postID: String, _ harness: Harness) async throws -> [Comment_V1_CommentView] {
        var request = Comment_V1_ListTopLevelRequest()
        request.postID = postID
        request.limit = 50
        return try await harness.comments.listTopLevel(request: request, headers: [:]).result.get().comments
    }

    @Test func anAuthoredPostOpensWithNoComments() async throws {
        let harness = makeHarness()
        let postID = try await publishTextPost(harness)

        #expect(try await topLevel(postID, harness).isEmpty)
    }

    @Test func aCommentOnAnAuthoredPostStays() async throws {
        let harness = makeHarness()
        let postID = try await publishTextPost(harness)
        var comment = Comment_V1_CreateCommentRequest()
        comment.commentID = UUID().uuidString
        comment.postID = postID
        comment.authorID = MockSocialDataset.viewerProfileID
        comment.body = "First!"
        _ = try await harness.comments.createComment(request: comment, headers: [:]).result.get()

        #expect(try await topLevel(postID, harness).map(\.body) == ["First!"])
    }

    /// The seed is untouched for everything that was not authored here.
    @Test func aSeededPostKeepsItsSeed() async throws {
        let harness = makeHarness()

        #expect(try await topLevel("post-0001", harness).isEmpty == false)
    }

    /// Read back, an authored text post says what it is, as the seeded ones do.
    @Test func anAuthoredTextPostSaysSoOnTheWire() async throws {
        let harness = makeHarness()
        let postID = try await publishTextPost(harness)
        var request = Post_V1_GetPostRequest()
        request.postID = postID

        let view = try await harness.posts.getPost(request: request, headers: [:]).result.get()

        #expect(view.kind == .textOnly)
    }
}
