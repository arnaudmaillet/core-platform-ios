import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Feed

/// Following is driven by the follow graph: only authors the viewer follows,
/// and the viewer's own posts. A follow or an unfollow accepted anywhere
/// (`FollowGraphEvents`) moves the author's posts into or out of Following;
/// Discover — everyone — never moves.
@MainActor
struct FollowingFollowGraphTests {
    private func post(_ id: String, by author: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "caption \(id)", publishedAtMS: 10, authorID: ProfileID(author)
        )
    }

    private var corpus: [GalleryPost] {
        [
            post("mine", by: "me"),
            post("friend1", by: "friend"),
            post("stranger1", by: "stranger"),
            post("friend2", by: "friend"),
            post("broken1", by: "broken")
        ]
    }

    private func loaded(
        events: FollowGraphEvents? = nil
    ) async -> (ForYouViewModel, () -> Int) {
        let model = ForYouViewModel(
            repository: FollowGraphStubProvider(posts: corpus),
            followRelations: StubFollowRelations(viewer: "me", followed: ["friend"], failing: ["broken"]),
            followEvents: events
        )
        var resets = 0
        model.onCorpusReset = { resets += 1 }
        model.viewDidLoad()
        for _ in 0..<80 where model.discoverPosts.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return (model, { resets })
    }

    private func ids(_ posts: [GalleryPost]) -> Set<String> { Set(posts.map(\.id.rawValue)) }

    /// Followed authors and the viewer's own posts; not a stranger's. An
    /// author the graph could not answer for is SHOWN (fail open).
    @Test func followingIsTheFollowedDiscoverIsEveryone() async {
        let (model, _) = await loaded()
        #expect(ids(model.posts(for: .activity)) == ["mine", "friend1", "friend2", "broken1"])
        #expect(ids(model.discoverPosts) == ["mine", "friend1", "stranger1", "friend2", "broken1"])
        #expect(ids(model.posts(for: .media)).contains("stranger1"), "the pushed mosaic is Discover's")
    }

    /// A follow accepted ANYWHERE adds the author's posts to Following.
    @Test func aFollowAnywhereAddsTheAuthorToFollowing() async {
        let events = FollowGraphEvents()
        let (model, resets) = await loaded(events: events)
        let before = resets()
        let discover = ids(model.discoverPosts)

        events.publish(FollowChange(profileID: ProfileID("stranger"), isFollowing: true))
        for _ in 0..<40 where !ids(model.posts(for: .activity)).contains("stranger1") {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(ids(model.posts(for: .activity)).contains("stranger1"))
        #expect(resets() == before + 1, "the pages re-derive: the post lands at its rank")
        #expect(ids(model.discoverPosts) == discover, "Discover does not move")
    }

    /// An unfollow accepted ANYWHERE takes the author out of Following.
    @Test func anUnfollowAnywhereTakesTheAuthorOutOfFollowing() async {
        let events = FollowGraphEvents()
        let (model, _) = await loaded(events: events)
        let discover = ids(model.discoverPosts)

        events.publish(FollowChange(profileID: ProfileID("friend"), isFollowing: false))
        for _ in 0..<40 where ids(model.posts(for: .activity)).contains("friend1") {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(ids(model.posts(for: .activity)) == ["mine", "broken1"])
        #expect(ids(model.discoverPosts) == discover, "Discover does not move")
    }

    /// A change that shows nothing new announces nothing: re-following an
    /// author already followed must not make every page re-derive.
    @Test func aChangeWithNothingToShowIsSilent() async {
        let events = FollowGraphEvents()
        let (model, resets) = await loaded(events: events)
        let before = resets()

        events.publish(FollowChange(profileID: ProfileID("friend"), isFollowing: true))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(resets() == before)
        #expect(model.posts(for: .activity).count == 4)
    }
}

private struct StubFollowRelations: SocialGraphReading {
    let viewer: String
    let followed: Set<String>
    let failing: Set<String>

    struct Unreachable: Error {}

    func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        if failing.contains(profileID.rawValue) { throw Unreachable() }
        if profileID.rawValue == viewer { return .viewer }
        return followed.contains(profileID.rawValue) ? .following : .notFollowing
    }
}

private final class FollowGraphStubProvider: ForYouProviding, @unchecked Sendable {
    private let posts: [GalleryPost]
    init(posts: [GalleryPost]) { self.posts = posts }
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: posts, nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}
