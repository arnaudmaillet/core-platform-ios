import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Feed

/// The rows are driven by the follow graph: FRIENDS are mutual follows, the
/// Following row is everyone else the viewer follows, and neither holds the
/// viewer's own posts or a stranger's. A follow or an unfollow accepted
/// anywhere (`FollowGraphEvents`) moves the author between rows; Discover —
/// everyone — never moves.
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
            post("pal1", by: "pal"),
            post("followed1", by: "followed"),
            post("stranger1", by: "stranger"),
            post("fan1", by: "fan"),
            post("followed2", by: "followed"),
            post("broken1", by: "broken")
        ]
    }

    private func loaded(
        events: FollowGraphEvents? = nil
    ) async -> (ForYouViewModel, () -> Int) {
        let model = ForYouViewModel(
            repository: FollowGraphStubProvider(posts: corpus),
            followRelations: StubFollowRelations(
                viewer: "me", followed: ["followed"], mutual: ["pal"], followers: ["fan"],
                failing: ["broken"]
            ),
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

    /// Friends are the mutual follows; Following the one-way follows, plus an
    /// author the graph could not answer for (fail open). The viewer and a
    /// stranger are Discover's alone.
    @Test func theRowsSplitTheFollowedDiscoverIsEveryone() async {
        let (model, _) = await loaded()
        #expect(ids(model.friendPosts) == ["pal1"])
        #expect(ids(model.followingPosts) == ["followed1", "followed2", "broken1"])
        #expect(ids(model.discoverPosts) == Set(corpus.map(\.id.rawValue)))
    }

    /// A follow accepted ANYWHERE adds the author to Following.
    @Test func aFollowAnywhereAddsTheAuthorToFollowing() async {
        let events = FollowGraphEvents()
        let (model, resets) = await loaded(events: events)
        let before = resets()
        let discover = ids(model.discoverPosts)

        events.publish(FollowChange(profileID: ProfileID("stranger"), isFollowing: true))
        for _ in 0..<40 where !ids(model.followingPosts).contains("stranger1") {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(ids(model.followingPosts).contains("stranger1"))
        #expect(resets() >= before + 1, "the pages re-derive: the post lands at its rank")
        #expect(ids(model.discoverPosts) == discover, "Discover does not move")
    }

    /// Following someone who follows the viewer makes a FRIEND, not a
    /// one-way follow — the inbound half is kept.
    @Test func followingBackMakesAFriend() async {
        let events = FollowGraphEvents()
        let (model, _) = await loaded(events: events)

        events.publish(FollowChange(profileID: ProfileID("fan"), isFollowing: true))
        for _ in 0..<40 where !ids(model.friendPosts).contains("fan1") {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(ids(model.friendPosts) == ["pal1", "fan1"])
        #expect(!ids(model.followingPosts).contains("fan1"))
    }

    /// An unfollow accepted ANYWHERE takes the author out of the rows: a
    /// one-way follow leaves Following, a friend leaves Friends — and does not
    /// land in Following, since the viewer no longer follows them.
    @Test func anUnfollowAnywhereTakesTheAuthorOutOfTheRows() async {
        let events = FollowGraphEvents()
        let (model, _) = await loaded(events: events)
        let discover = ids(model.discoverPosts)

        events.publish(FollowChange(profileID: ProfileID("followed"), isFollowing: false))
        events.publish(FollowChange(profileID: ProfileID("pal"), isFollowing: false))
        for _ in 0..<40 where ids(model.followingPosts).contains("followed1") || !model.friendPosts.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(ids(model.followingPosts) == ["broken1"])
        #expect(model.friendPosts.isEmpty)
        #expect(ids(model.discoverPosts) == discover, "Discover does not move")
    }

    /// A change that shows nothing new announces nothing: re-following an
    /// author already followed must not make every page re-derive.
    @Test func aChangeWithNothingToShowIsSilent() async {
        let events = FollowGraphEvents()
        let (model, resets) = await loaded(events: events)
        let before = resets()

        events.publish(FollowChange(profileID: ProfileID("followed"), isFollowing: true))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(resets() == before)
        #expect(model.followingPosts.count == 3)
    }
}

private struct StubFollowRelations: SocialGraphReading {
    let viewer: String
    let followed: Set<String>
    let mutual: Set<String>
    let followers: Set<String>
    let failing: Set<String>

    struct Unreachable: Error {}

    func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        let id = profileID.rawValue
        if failing.contains(id) { throw Unreachable() }
        if id == viewer { return .viewer }
        if mutual.contains(id) { return .mutual }
        if followed.contains(id) { return .following }
        return followers.contains(id) ? .followedBy : .notFollowing
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
