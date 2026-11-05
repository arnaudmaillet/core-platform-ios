import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

/// The posts and authors the repository holds were read for one viewer
/// (#2047): a member's private authors are not a guest's to see, so a viewer
/// change forgets them, and a read still in flight for the last viewer lands
/// nothing.
struct FeedRepositoryViewerChangeTests {
    /// The token the mock reads the viewer from: the demo member (any
    /// non-guest token) or a guest (`gt-…`). `hold()` parks the next read
    /// until `release()`, so a read can be caught in flight.
    private final class Viewer: AuthTokenProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var token = "member-token"
        private var held: CheckedContinuation<Void, Never>?
        private var holding = false
        private var parked = false

        func become(_ token: String) { lock.withLock { self.token = token } }
        func hold() { lock.withLock { holding = true } }
        var isParked: Bool { lock.withLock { parked } }

        func release() {
            let continuation = lock.withLock {
                holding = false
                defer { held = nil }
                return held
            }
            continuation?.resume()
        }

        func validAccessToken() async throws -> String? {
            // The token is the one the read STARTED with: the member's read in
            // flight is the member's, whoever the viewer is by its answer.
            let (token, wait) = lock.withLock { (token, holding) }
            if wait {
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        held = continuation
                        parked = true
                    }
                }
            }
            return token
        }
    }

    private struct Member: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private let backend = MockBackend()
    private let viewer = Viewer()

    private func makeRepository() -> FeedRepository {
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: viewer, httpClient: backend.bff
        )
        return FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: Member(),
            localCache: nil
        )
    }

    /// prof-1 is private and followed by the demo member: the member reads
    /// its posts, a guest does not.
    private func privatePost() throws -> PostID {
        #expect(backend.dataset.isRelationshipsPrivate("prof-1"))
        return PostID(try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-1" }?.postID))
    }

    @Test func aSignOutForgetsTheMembersPosts() async throws {
        let repository = makeRepository()
        let id = try privatePost()
        #expect(try await repository.loadPost(id).post.id == id)
        #expect(repository.peekPost(id) != nil)

        viewer.become("gt-guest")
        await repository.viewerDidChange(.guest)

        #expect(repository.peekPost(id) == nil)
        await #expect(throws: FeedError.notFound) { _ = try await repository.loadPost(id) }
    }

    /// A sign-in after a guest session: the member's private authors are
    /// back, read from the server for the member.
    @Test func aSignInReadsTheMembersOwnPosts() async throws {
        viewer.become("gt-guest")
        let repository = makeRepository()
        let id = try privatePost()
        await #expect(throws: FeedError.notFound) { _ = try await repository.loadPost(id) }

        viewer.become("member-token")
        await repository.viewerDidChange(.member(AccountID(MockAuthService.accountID), activeProfile: nil))

        #expect(try await repository.loadPost(id).post.id == id)
    }

    /// A profile switch is another viewer: a post the next profile may not
    /// read is not served from the copy the last one read. The seeded block
    /// (prof-4 blocks the viewer) stands for the next profile's.
    @Test func aProfileSwitchDoesNotServeTheLastProfilesCopy() async throws {
        let repository = makeRepository()
        let id = PostID(try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-4" }?.postID))
        _ = try await repository.loadPost(id)

        var block = SocialGraph_V1_BlockRequest()
        block.actorID = "prof-4"
        block.targetID = MockSocialDataset.viewerProfileID
        _ = await SocialGraph_V1_SocialGraphServiceClient(client: backend.makeRPCClient()).block(request: block, headers: [:])
        await repository.viewerDidChange(.member(AccountID(MockAuthService.accountID), activeProfile: ProfileID("prof-2")))

        #expect(repository.peekPost(id) == nil)
        await #expect(throws: FeedError.notFound) { _ = try await repository.loadPost(id) }
    }

    /// A public author's post is still the guest's to read after the change.
    @Test func aPublicPostReadsAgainForTheNextViewer() async throws {
        let repository = makeRepository()
        let id = PostID(try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-4" }?.postID))
        _ = try await repository.loadPost(id)

        viewer.become("gt-guest")
        await repository.viewerDidChange(.guest)

        #expect(try await repository.loadPost(id).post.id == id)
        #expect(repository.peekPost(id) != nil)
    }

    /// A read the member started lands after the sign-out: it stores nothing,
    /// and the guest's own read of that post is not handed the member's.
    @Test func aReadInFlightAcrossTheChangeStoresNothing() async throws {
        let repository = makeRepository()
        let id = try privatePost()
        viewer.hold()
        let membersRead = Task { try? await repository.loadPost(id) }
        var turns = 0
        while !viewer.isParked, turns < 100_000 {
            await Task.yield()
            turns += 1
        }
        #expect(viewer.isParked)

        viewer.become("gt-guest")
        await repository.viewerDidChange(.guest)
        viewer.release()
        _ = await membersRead.value

        #expect(repository.peekPost(id) == nil)
        await #expect(throws: FeedError.notFound) { _ = try await repository.loadPost(id) }
    }
}
