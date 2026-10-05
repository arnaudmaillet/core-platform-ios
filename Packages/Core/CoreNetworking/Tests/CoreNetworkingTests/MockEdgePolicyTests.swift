import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

private struct StubTokenProvider: AuthTokenProviding {
    let token: String?
    func validAccessToken() async throws -> String? { token }
}

/// The mock edge refuses what the fleet's edge will: a guest (a `gt-…` guest
/// token) may read public content and report it, and nothing else; a caller
/// with no token at all may only sign in or start a guest session.
struct MockEdgePolicyTests {
    private let backend = MockBackend(enforcesEdgePolicy: true)

    private func client(token: String?) -> ProtocolClientInterface {
        ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local",
            tokenProvider: StubTokenProvider(token: token),
            httpClient: backend.bff
        )
    }

    private func reaction(on postID: String) -> Engagement_V1_UpsertReactionRequest {
        var request = Engagement_V1_UpsertReactionRequest()
        request.postID = postID
        request.profileID = "prof-guest-probe"
        request.kind = .heart
        return request
    }

    private var somePostID: String { backend.dataset.posts[0].postID }

    @Test func aGuestReadsPublicContent() async {
        var request = Post_V1_GetPostRequest()
        request.postID = somePostID
        let response = await Post_V1_PostServiceClient(client: client(token: "gt-1")).getPost(request: request, headers: [:])
        #expect(response.error == nil)
    }

    /// B1: every read needs `read:public` — a guest token at least.
    @Test func anAnonymousReadIsRefused() async {
        var request = Post_V1_GetPostRequest()
        request.postID = somePostID
        let response = await Post_V1_PostServiceClient(client: client(token: nil)).getPost(request: request, headers: [:])
        #expect(response.error?.code == .unauthenticated)
    }

    @Test func anyoneMayStartAGuestSession() {
        #expect(MockEdgePolicy.access(for: "/auth.v1.AuthService/StartGuestSession") == .open)
        #expect(MockEdgePolicy.access(for: "/auth.v1.AuthService/StartDeviceAttestation") == .open)
    }

    @Test func aGuestsWriteIsRefusedUnauthenticated() async {
        let response = await Engagement_V1_EngagementServiceClient(client: client(token: "gt-1"))
            .upsertReaction(request: reaction(on: somePostID), headers: [:])
        #expect(response.error?.code == .unauthenticated)
    }

    @Test func aGuestsViewerReadIsRefused() async {
        let response = await Notification_V1_NotificationServiceClient(client: client(token: "gt-1"))
            .getUnreadCount(request: Notification_V1_GetUnreadCountRequest(), headers: [:])
        #expect(response.error?.code == .unauthenticated)
    }

    @Test func aMembersWritePasses() async {
        let response = await Engagement_V1_EngagementServiceClient(client: client(token: "at-1"))
            .upsertReaction(request: reaction(on: somePostID), headers: [:])
        #expect(response.error?.code != .unauthenticated)
    }

    @Test func aGuestMayReport() {
        #expect(MockEdgePolicy.access(for: "/moderation.v1.ModerationService/SubmitReport") == .guestReadable)
        #expect(MockEdgePolicy.access(for: "/moderation.v1.ModerationService/ListMyReports") == .guestReadable)
        // Mesh-only on the fleet since backend #677: the reviewer console's.
        #expect(MockEdgePolicy.access(for: "/moderation.v1.ModerationService/OpenCase") == .member)
    }

    @Test func signingInNeedsNoSession() {
        #expect(MockEdgePolicy.access(for: "/auth.v1.AuthService/Login") == .open)
        #expect(MockEdgePolicy.access(for: "/auth.v1.AuthService/Refresh") == .open)
    }

    /// As at the fleet's edge: ending a session takes that session's bearer
    /// (`SessionManager.logout`, #486).
    @Test func loggingOutNeedsTheSession() {
        #expect(MockEdgePolicy.access(for: "/auth.v1.AuthService/Logout") == .member)
    }

    @Test func anUnlistedRouteIsMembersOnly() {
        #expect(MockEdgePolicy.access(for: "/future.v1.FutureService/DoSomething") == .member)
    }

    /// A typo in the table would silently close a public read to guests.
    @Test func everyListedRouteIsServed() {
        let served = backend.bff.routedPaths
        for path in ["/post.v1.PostService/GetPost", "/post.v1.PostService/ListPostsByProfile",
                     "/profile.v1.ProfileService/GetProfileById", "/comment.v1.CommentService/ListTopLevel",
                     "/comment.v1.CommentService/ListReplies", "/counter.v1.CounterService/BatchGetCounters",
                     "/social_graph.v1.SocialGraphService/ListFollowers",
                     "/social_graph.v1.SocialGraphService/ListFollowing",
                     "/geo_discovery.v1.GeoDiscoveryService/QueryTile", "/search.v1.SearchService/Search",
                     "/timeline.v1.TimelineService/GetDiscoveryFeed",
                     "/search.v1.SearchService/Suggest", "/media.v1.MediaService/ResolveDelivery",
                     "/moderation.v1.ModerationService/SubmitReport",
                     "/moderation.v1.ModerationService/ListMyReports", "/auth.v1.AuthService/Login",
                     "/auth.v1.AuthService/Refresh", "/auth.v1.AuthService/StartGuestSession",
                     "/auth.v1.AuthService/StartDeviceAttestation"] {
            #expect(served.contains(path), "\(path) is in the policy but not served")
            #expect(MockEdgePolicy.access(for: path) != .member, "\(path) should be open to guests")
        }
    }

    @Test func theEdgeIsOpenUnlessAskedFor() async {
        let open = MockBackend()
        let response = await Engagement_V1_EngagementServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: open.bff)
        ).upsertReaction(request: reaction(on: open.dataset.posts[0].postID), headers: [:])
        #expect(response.error?.code != .unauthenticated)
    }
}
