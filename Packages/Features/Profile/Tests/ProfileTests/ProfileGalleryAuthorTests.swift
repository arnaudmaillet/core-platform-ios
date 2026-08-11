import Connect
import CoreContracts
import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Profile

/// THE GRID DRAWS NO AUTHOR, AND CARRIES ONE ANYWAY.
///
/// A profile page has no reason to repeat whose posts you are looking at, which
/// is why these fields sat empty for so long without anyone noticing. They are
/// for the surface a tile OPENS INTO: the full-screen page is seeded from the
/// tile's own model, so a tile with no author seeds a page whose capsule and
/// attribution pill are anonymous until the network answers — and, before the
/// diffable reconfigure landed, for the rest of that page's life.
struct ProfileGalleryAuthorTests {

    @Test func authoredTilesCarryTheIdentityTheOpenedPageWillNeed() async throws {
        let profiles = StubProfileServiceClient(identities: [
            "prof-1": .init(
                handle: "demo", displayName: "Demo Viewer",
                avatarURL: "https://cdn.example/demo.jpg"
            )
        ])
        let repository = makeRepository(
            posts: [post("p1", author: "prof-1"), post("p2", author: "prof-1")],
            profiles: profiles
        )

        let tiles = try await repository.authoredPosts(for: ProfileID("prof-1"))

        #expect(tiles.count == 2)
        #expect(tiles.allSatisfy { $0.authorName == "Demo Viewer" })
        #expect(tiles.allSatisfy { $0.authorHandle == "demo" })
        #expect(tiles.allSatisfy { $0.authorID == ProfileID("prof-1") })
        #expect(tiles.first?.authorAvatarURL == URL(string: "https://cdn.example/demo.jpg"))
    }

    /// ⚠️ ONE read per distinct author, not per post. An authored page is a
    /// single person, so a ninety-tile grid is one round trip — and the
    /// difference between that and ninety is invisible in the result, which is
    /// exactly why it needs asserting.
    @Test func oneReadPerAuthorNotPerPost() async throws {
        let profiles = StubProfileServiceClient()
        let repository = makeRepository(
            posts: (1...12).map { post("p\($0)", author: "prof-1") },
            profiles: profiles
        )

        _ = try await repository.authoredPosts(for: ProfileID("prof-1"))

        #expect(profiles.readIDs == ["prof-1"])
    }

    /// …and not per LOAD either. Paging a tab, pulling to refresh and opening
    /// the saved pile all re-enter this; the identity does not change between
    /// them.
    @Test func aResolvedAuthorIsNotAskedAboutAgain() async throws {
        let profiles = StubProfileServiceClient()
        let repository = makeRepository(
            posts: [post("p1", author: "prof-1")], profiles: profiles
        )

        _ = try await repository.authoredPosts(for: ProfileID("prof-1"))
        _ = try await repository.authoredPosts(for: ProfileID("prof-1"))
        _ = try await repository.posts(ids: ["p1"])

        #expect(profiles.readCount == 1)
    }

    /// A tagged or saved pile is other people's posts, so each distinct author
    /// is resolved — and each only once.
    @Test func aMixedPileResolvesEachPersonOnce() async throws {
        let profiles = StubProfileServiceClient()
        let repository = makeRepository(
            posts: [
                post("p1", author: "prof-1"), post("p2", author: "prof-2"),
                post("p3", author: "prof-1"), post("p4", author: "prof-2")
            ],
            profiles: profiles
        )

        let tiles = try await repository.posts(ids: ["p1", "p2", "p3", "p4"])

        #expect(Set(profiles.readIDs) == ["prof-1", "prof-2"])
        #expect(profiles.readCount == 2)
        #expect(tiles.map(\.authorHandle) == ["prof-1", "prof-2", "prof-1", "prof-2"])
    }

    /// An unreachable person degrades to the tile it was before — no author,
    /// still a post. The grid renders identically either way; only the page it
    /// opens is poorer, and it recovers there when the entry hydrates.
    @Test func anUnreachableAuthorLeavesTheTileIntact() async throws {
        let profiles = StubProfileServiceClient(unreachable: ["prof-1"])
        let repository = makeRepository(
            posts: [post("p1", author: "prof-1")], profiles: profiles
        )

        let tiles = try await repository.authoredPosts(for: ProfileID("prof-1"))

        #expect(tiles.count == 1)
        #expect(tiles.first?.authorName == nil)
        #expect(tiles.first?.caption == "caption p1")
    }

    /// The client is optional, and a composition root without one must still
    /// get a working grid — the behaviour every tile had before this existed.
    @Test func noProfileClientStillYieldsTiles() async throws {
        let repository = makeRepository(
            posts: [post("p1", author: "prof-1")], profiles: nil
        )

        let tiles = try await repository.authoredPosts(for: ProfileID("prof-1"))

        #expect(tiles.count == 1)
        #expect(tiles.first?.authorName == nil)
    }

    // MARK: - Fixtures

    private func makeRepository(
        posts: [Post_V1_PostView],
        profiles: StubProfileServiceClient?
    ) -> ProfileGalleryRepository {
        ProfileGalleryRepository(
            postClient: StubPostClient(posts: posts),
            searchClient: StubSearchClient(),
            counterClient: StubCounterClient(),
            profileClient: profiles
        )
    }

    private func post(_ id: String, author: String) -> Post_V1_PostView {
        var view = Post_V1_PostView()
        view.postID = id
        view.profileID = author
        view.caption = "caption \(id)"
        view.kind = .textOnly
        return view
    }
}

// MARK: - Wire stubs

/// Serves a fixed set of post views, and lists them in the order given.
private struct StubPostClient: Post_V1_PostServiceClientInterface {
    let posts: [Post_V1_PostView]

    func getPost(
        request: Post_V1_GetPostRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Post_V1_PostView> {
        guard let match = posts.first(where: { $0.postID == request.postID }) else {
            return ResponseMessage(result: .failure(ConnectError(code: .notFound, message: "stub")))
        }
        return ResponseMessage(result: .success(match))
    }

    func listPostsByProfile(
        request: Post_V1_ListPostsByProfileRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Post_V1_ListPostsByProfileResponse> {
        var response = Post_V1_ListPostsByProfileResponse()
        response.posts = posts.map { view in
            var summary = Post_V1_PostSummary()
            summary.postID = view.postID
            return summary
        }
        return ResponseMessage(result: .success(response))
    }

    func createPost(
        request: Post_V1_CreatePostRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Post_V1_CreatePostResponse> {
        ResponseMessage(result: .success(Post_V1_CreatePostResponse()))
    }

    func publishPost(
        request: Post_V1_PublishPostRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Post_V1_CommandResponse> {
        ResponseMessage(result: .success(Post_V1_CommandResponse()))
    }

    func updatePost(
        request: Post_V1_UpdatePostRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Post_V1_CommandResponse> {
        ResponseMessage(result: .success(Post_V1_CommandResponse()))
    }

    func deletePost(
        request: Post_V1_DeletePostRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Post_V1_CommandResponse> {
        ResponseMessage(result: .success(Post_V1_CommandResponse()))
    }
}

private struct StubSearchClient: Search_V1_SearchServiceClientInterface {
    func search(
        request: Search_V1_SearchRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Search_V1_SearchResponse> {
        ResponseMessage(result: .success(Search_V1_SearchResponse()))
    }

    func suggest(
        request: Search_V1_SuggestRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Search_V1_SuggestResponse> {
        ResponseMessage(result: .success(Search_V1_SuggestResponse()))
    }

    func multiSearch(
        request: Search_V1_MultiSearchRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Search_V1_MultiSearchResponse> {
        ResponseMessage(result: .success(Search_V1_MultiSearchResponse()))
    }
}

/// Answers nothing, which is a supported state: counters are best-effort and a
/// nil count hides the label rather than failing the grid.
private struct StubCounterClient: Counter_V1_CounterServiceClientInterface {
    func batchGetCounters(
        request: Counter_V1_BatchGetCountersRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Counter_V1_BatchGetCountersResponse> {
        ResponseMessage(result: .success(Counter_V1_BatchGetCountersResponse()))
    }

    func getTrending(
        request: Counter_V1_GetTrendingRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Counter_V1_GetTrendingResponse> {
        ResponseMessage(result: .success(Counter_V1_GetTrendingResponse()))
    }

    func getTimeSeries(
        request: Counter_V1_GetTimeSeriesRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Counter_V1_GetTimeSeriesResponse> {
        ResponseMessage(result: .success(Counter_V1_GetTimeSeriesResponse()))
    }
}
