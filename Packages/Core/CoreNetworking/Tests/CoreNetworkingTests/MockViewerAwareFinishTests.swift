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

/// The rest of #447 in the mock, as the backend rules them:
/// - comments (backend #692): a post's comments are read as the post is —
///   none of a draft, deleted or taken-down post for anyone but its author,
///   none of a private author's for a guest — and a commenter hidden from
///   the reader is dropped;
/// - search (backend #687/#693): no profile hidden from the reader (a private
///   one stays findable by its header), no post by an author they may not
///   see, none taken down; hashtags stay;
/// - hidden and suspended profiles (backend #689): not found;
/// - takedowns (backend #688): the post is its author's alone, everywhere.
struct MockViewerAwareFinishTests {
    private let backend = MockBackend()

    private func client(_ token: String) -> any ProtocolClientInterface {
        ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: Token(token: token), httpClient: backend.bff
        )
    }

    private var member: any ProtocolClientInterface { client("member-token") }
    private var guest: any ProtocolClientInterface { client("gt-guest") }

    private func firstPost(of profileID: String) throws -> String {
        // Past the posts seeded with no comments (`zeroCommentPostIDs`).
        try #require(backend.dataset.posts.first {
            $0.authorProfileID == profileID && !["post-0009", "post-0010"].contains($0.postID)
        }?.postID)
    }

    private func comments(on postID: String, as reader: any ProtocolClientInterface) async throws -> [Comment_V1_CommentView] {
        var request = Comment_V1_ListTopLevelRequest()
        request.postID = postID
        request.limit = 50
        return try await Comment_V1_CommentServiceClient(client: reader).listTopLevel(request: request, headers: [:]).result.get().comments
    }

    private func search(_ query: String, _ types: [Search_V1_SearchEntityType], as reader: any ProtocolClientInterface) async throws -> [Search_V1_SearchHit] {
        var request = Search_V1_SearchRequest()
        request.query = query
        request.entityTypes = types
        return try await Search_V1_SearchServiceClient(client: reader).search(request: request, headers: [:]).result.get().hits
    }

    private func block(_ actor: String, _ target: String) async {
        var request = SocialGraph_V1_BlockRequest()
        request.actorID = actor
        request.targetID = target
        _ = await SocialGraph_V1_SocialGraphServiceClient(client: member).block(request: request, headers: [:])
    }

    private func readPost(_ postID: String, as reader: any ProtocolClientInterface) async -> Code? {
        var request = Post_V1_GetPostRequest()
        request.postID = postID
        return await Post_V1_PostServiceClient(client: reader).getPost(request: request, headers: [:]).error?.code
    }

    // MARK: - Comments

    /// prof-1 is private and followed by the demo viewer.
    @Test func aPrivateAuthorsCommentsAreNoGuestsToRead() async throws {
        let post = try firstPost(of: "prof-1")
        #expect(try await !comments(on: post, as: member).isEmpty)
        #expect(try await comments(on: post, as: guest).isEmpty)
    }

    @Test func aTakenDownPostsCommentsAreNoOnesButItsAuthors() async throws {
        let post = try firstPost(of: "prof-4")
        #expect(try await !comments(on: post, as: member).isEmpty)
        backend.socialServices.takeDown(post)
        #expect(try await comments(on: post, as: member).isEmpty)
        #expect(try await comments(on: post, as: guest).isEmpty)
    }

    @Test func aDeletedPostsCommentsAreItsAuthorsAlone() async throws {
        let posts = Post_V1_PostServiceClient(client: member)
        var create = Post_V1_CreatePostRequest()
        create.profileID = MockSocialDataset.viewerProfileID
        create.kind = .textOnly
        create.caption = "Soon gone"
        let postID = try await posts.createPost(request: create, headers: [:]).result.get().postID
        var publish = Post_V1_PublishPostRequest()
        publish.postID = postID
        publish.profileID = MockSocialDataset.viewerProfileID
        _ = try await posts.publishPost(request: publish, headers: [:]).result.get()
        var comment = Comment_V1_CreateCommentRequest()
        comment.commentID = UUID().uuidString
        comment.postID = postID
        comment.authorID = MockSocialDataset.viewerProfileID
        comment.body = "First"
        _ = try await Comment_V1_CommentServiceClient(client: member).createComment(request: comment, headers: [:]).result.get()
        #expect(try await comments(on: postID, as: guest).map(\.body) == ["First"])

        var delete = Post_V1_DeletePostRequest()
        delete.postID = postID
        delete.profileID = MockSocialDataset.viewerProfileID
        _ = try await posts.deletePost(request: delete, headers: [:]).result.get()
        #expect(try await comments(on: postID, as: guest).isEmpty)
        #expect(try await comments(on: postID, as: member).map(\.body) == ["First"], "its author still reads them")
    }

    @Test func aCommenterHiddenFromTheReaderIsDropped() async throws {
        let post = try firstPost(of: "prof-4")
        let before = try await comments(on: post, as: member)
        // Someone else's: not one of the viewer's own profiles (prof-0, prof-2
        // share its account, and a block of oneself does nothing).
        let own = backend.dataset.accountID(for: MockSocialDataset.viewerProfileID)
        let commenter = try #require(before.first {
            backend.dataset.accountID(for: $0.authorID) != own && $0.authorID != "prof-4"
        }?.authorID)
        await block(MockSocialDataset.viewerProfileID, commenter)
        let after = try await comments(on: post, as: member)
        #expect(!after.contains { $0.authorID == commenter })
        #expect(after.count == before.filter { $0.authorID != commenter }.count, "the others stay")
    }

    // MARK: - Search

    @Test func searchKeepsAPrivateProfilesHeaderAndDropsABlockedOne() async throws {
        let privateOne = try #require(backend.dataset.author(for: "prof-20"))
        let blocked = try #require(backend.dataset.author(for: "prof-4"))
        #expect(try await search(privateOne.handle, [.profile], as: guest).contains { $0.id == "prof-20" }, "findable by its header")
        await block("prof-4", MockSocialDataset.viewerProfileID)
        #expect(try await !search(blocked.handle, [.profile], as: member).contains { $0.id == "prof-4" })
    }

    @Test func searchDropsPostsByAuthorsTheReaderMayNotSee() async throws {
        let unfollowedPrivate = try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-20" })
        let followedPrivate = try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-1" })
        let query = { (record: MockSocialDataset.PostRecord) in String(record.caption.prefix(24)).lowercased() }
        #expect(try await !search(query(unfollowedPrivate), [.post], as: member).contains { $0.id == unfollowedPrivate.postID })
        #expect(try await search(query(followedPrivate), [.post], as: member).contains { $0.id == followedPrivate.postID })
        #expect(try await !search(query(followedPrivate), [.post], as: guest).contains { $0.id == followedPrivate.postID })
    }

    @Test func searchDropsATakenDownPostButKeepsItsHashtags() async throws {
        let tagged = try #require(backend.dataset.posts.first {
            $0.caption.contains("#") && !backend.dataset.isRelationshipsPrivate($0.authorProfileID)
        })
        let tag = try #require(tagged.caption.split(separator: " ").first { $0.hasPrefix("#") }.map { String($0.dropFirst()).lowercased() })
        #expect(try await search("#\(tag)", [.post], as: member).contains { $0.id == tagged.postID })
        let count = { () async throws -> Int64? in
            try await self.search(tag, [.hashtag], as: self.member).first { $0.hashtag.tag == tag }?.hashtag.postCount
        }
        let before = try #require(try await count())
        backend.socialServices.takeDown(tagged.postID)
        #expect(try await !search("#\(tag)", [.post], as: member).contains { $0.id == tagged.postID })
        // The tag stays, without the post the fleet's index dropped (#687).
        #expect(try await count() == before - 1, "hashtags stay, counted without it")
    }

    /// The owner's "Show Up in Search" off keeps a profile out of typeahead
    /// on a display-name match too — the filter used to bind to the handle
    /// alone.
    @Test func typeaheadHonoursShowUpInSearchOnADisplayNameMatch() async throws {
        let author = try #require(backend.dataset.author(for: "prof-5"))
        let firstName = try #require(author.displayName.split(separator: " ").first.map { String($0.prefix(3)).lowercased() })
        var off = Profile_V1_SetDiscoverySettingsRequest()
        off.profileID = "prof-5"
        off.byHandleSearch = false
        _ = await Profile_V1_ProfileServiceClient(client: member).setDiscoverySettings(request: off, headers: [:])
        var suggest = Search_V1_SuggestRequest()
        suggest.prefix = firstName
        suggest.entityTypes = [.profile]
        let ids = try await Search_V1_SearchServiceClient(client: member).suggest(request: suggest, headers: [:]).result.get().suggestions.map(\.id)
        #expect(!ids.contains("prof-5"))
    }

    // MARK: - Hidden and suspended profiles

    @Test func aHiddenOrSuspendedProfileIsNotFoundByIDOrHandle() async throws {
        let profiles = Profile_V1_ProfileServiceClient(client: member)
        for hidden in MockSocialServices.hiddenProfiles {
            var byID = Profile_V1_GetProfileByIdRequest()
            byID.profileID = hidden.id
            #expect(await profiles.getProfileByID(request: byID, headers: [:]).error?.code == .notFound)
            var byHandle = Profile_V1_GetProfileByHandleRequest()
            byHandle.handle = hidden.handle
            #expect(await profiles.getProfileByHandle(request: byHandle, headers: [:]).error?.code == .notFound)
            #expect(try await search(hidden.handle, [.profile], as: member).isEmpty)
        }
    }

    // MARK: - Takedowns

    /// Every post id of the discovery pool, page by page.
    private func discoveryPool(as reader: any ProtocolClientInterface) async throws -> [String] {
        let timeline = Timeline_V1_TimelineServiceClient(client: reader)
        var pool: [String] = []
        var token = ""
        for _ in 0..<100 {
            var discovery = Timeline_V1_GetDiscoveryFeedRequest()
            discovery.limit = 50
            discovery.pageToken = token
            let page = try await timeline.getDiscoveryFeed(request: discovery, headers: [:]).result.get()
            pool += page.items.map(\.postID)
            token = page.nextPageToken
            if token.isEmpty { break }
        }
        return pool
    }

    @Test func aTakenDownPostIsItsAuthorsAloneEverywhere() async throws {
        let post = try firstPost(of: "prof-6")
        backend.socialServices.takeDown(post)
        #expect(await readPost(post, as: member) == .notFound)
        #expect(await readPost(post, as: guest) == .notFound)

        var listing = Post_V1_ListPostsByProfileRequest()
        listing.profileID = "prof-6"
        listing.limit = 50
        let listed = try await Post_V1_PostServiceClient(client: member).listPostsByProfile(request: listing, headers: [:]).result.get()
        #expect(!listed.posts.contains { $0.postID == post })

        let pool = try await discoveryPool(as: member)
        #expect(pool.count > 50, "the pool was read past its first page")
        #expect(!pool.contains(post))
    }

    @Test func aTakenDownPostOfTheViewersOwnStillReadsToThem() async throws {
        let posts = Post_V1_PostServiceClient(client: member)
        var create = Post_V1_CreatePostRequest()
        create.profileID = MockSocialDataset.viewerProfileID
        create.kind = .textOnly
        create.caption = "Mine"
        let postID = try await posts.createPost(request: create, headers: [:]).result.get().postID
        var publish = Post_V1_PublishPostRequest()
        publish.postID = postID
        publish.profileID = MockSocialDataset.viewerProfileID
        _ = try await posts.publishPost(request: publish, headers: [:]).result.get()
        backend.socialServices.takeDown(postID)
        #expect(await readPost(postID, as: member) == nil)
        #expect(await readPost(postID, as: guest) == .notFound)
        #expect(try await discoveryPool(as: member).contains(postID), "its author's discovery keeps it")
        #expect(try await !discoveryPool(as: guest).contains(postID))
    }
}
