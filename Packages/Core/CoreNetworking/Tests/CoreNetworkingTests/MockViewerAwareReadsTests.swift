import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

private struct Token: AuthTokenProviding {
    let token: String?
    func validAccessToken() async throws -> String? { token }
}

/// Viewer-aware reads in the mock (#447, backend #686/#690/#691): a draft or
/// a deleted post is its author's alone; a block either way hides an
/// author's posts; a private author's listing is its followers' alone, and a
/// guest — who follows no one — reads none of its posts.
struct MockViewerAwareReadsTests {
    private let backend = MockBackend()

    /// The demo member (any non-guest token), or a guest (`gt-…`).
    private func posts(as token: String) -> Post_V1_PostServiceClient {
        Post_V1_PostServiceClient(client: ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: Token(token: token), httpClient: backend.bff
        ))
    }

    private var member: Post_V1_PostServiceClient { posts(as: "member-token") }
    private var guest: Post_V1_PostServiceClient { posts(as: "gt-guest") }

    private func listing(of profileID: String, with client: Post_V1_PostServiceClient) async throws -> [String] {
        var request = Post_V1_ListPostsByProfileRequest()
        request.profileID = profileID
        request.limit = 50
        return try await client.listPostsByProfile(request: request, headers: [:]).result.get().posts.map(\.postID)
    }

    private func read(_ postID: String, with client: Post_V1_PostServiceClient) async -> Code? {
        var request = Post_V1_GetPostRequest()
        request.postID = postID
        return await client.getPost(request: request, headers: [:]).error?.code
    }

    private func firstPost(of profileID: String) throws -> String {
        try #require(backend.dataset.posts.first { $0.authorProfileID == profileID }?.postID)
    }

    /// prof-1 is private and followed by the viewer; prof-20 is private and
    /// not; prof-4 is public.
    @Test func aPrivateAuthorsListingIsItsFollowersAlone() async throws {
        #expect(backend.dataset.isRelationshipsPrivate("prof-1") && backend.dataset.isRelationshipsPrivate("prof-20"))
        #expect(try await !listing(of: "prof-1", with: member).isEmpty)
        #expect(try await listing(of: "prof-20", with: member).isEmpty)
        #expect(try await !listing(of: "prof-4", with: member).isEmpty)
    }

    @Test func aGuestReadsNoPrivateAuthorsPosts() async throws {
        #expect(try await listing(of: "prof-1", with: guest).isEmpty)
        #expect(await read(try firstPost(of: "prof-1"), with: guest) == .notFound)
        #expect(try await !listing(of: "prof-4", with: guest).isEmpty)
        #expect(await read(try firstPost(of: "prof-4"), with: guest) == nil)
    }

    @Test func aBlockEitherWayHidesTheAuthorsPosts() async throws {
        let graph = SocialGraph_V1_SocialGraphServiceClient(client: backend.makeRPCClient())
        var block = SocialGraph_V1_BlockRequest()
        block.actorID = "prof-4"
        block.targetID = MockSocialDataset.viewerProfileID
        _ = await graph.block(request: block, headers: [:])

        #expect(await read(try firstPost(of: "prof-4"), with: member) == .notFound)
        #expect(try await listing(of: "prof-4", with: member).isEmpty)
        #expect(await read(try firstPost(of: "prof-5"), with: member) == nil)
    }

    @Test func aDraftIsItsAuthorsAlone() async throws {
        var create = Post_V1_CreatePostRequest()
        create.profileID = MockSocialDataset.viewerProfileID
        create.kind = .textOnly
        create.caption = "Not yet"
        let draft = try await member.createPost(request: create, headers: [:]).result.get().postID

        #expect(await read(draft, with: member) == nil)
        #expect(await read(draft, with: guest) == .notFound)
    }

    @Test func aDeletedPostIsItsAuthorsTombstoneAlone() async throws {
        var create = Post_V1_CreatePostRequest()
        create.profileID = MockSocialDataset.viewerProfileID
        create.kind = .textOnly
        create.caption = "Gone soon"
        let postID = try await member.createPost(request: create, headers: [:]).result.get().postID
        var publish = Post_V1_PublishPostRequest()
        publish.postID = postID
        publish.profileID = MockSocialDataset.viewerProfileID
        _ = try await member.publishPost(request: publish, headers: [:]).result.get()
        #expect(await read(postID, with: guest) == nil)

        var delete = Post_V1_DeletePostRequest()
        delete.postID = postID
        delete.profileID = MockSocialDataset.viewerProfileID
        _ = try await member.deletePost(request: delete, headers: [:]).result.get()

        var request = Post_V1_GetPostRequest()
        request.postID = postID
        #expect(try await member.getPost(request: request, headers: [:]).result.get().status == .deleted)
        #expect(await read(postID, with: guest) == .notFound)
    }
}
