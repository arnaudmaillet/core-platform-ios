import AuthInterface
import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Profile

// A revisited profile opens its posts at frame 0 (#887).

private func post(_ id: String, at ms: Int64) -> GalleryPost {
    GalleryPost(id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil, caption: id, publishedAtMS: ms)
}

/// Serves authored pages by token (nil = the first), records every ask, and
/// deletes like the trash does.
private actor RevisitGallery: ProfileGalleryProviding, PostTrashManaging {
    private var authored: [String?: GalleryPage]
    private(set) var authoredAsks: [String?] = []

    init(authored: [String?: GalleryPage]) { self.authored = authored }

    func setAuthored(_ page: GalleryPage, for token: String?) { authored[token] = page }
    var firstPageAsks: Int { authoredAsks.filter { $0 == nil }.count }

    func authoredPage(for profileID: ProfileID, after pageToken: String?) async throws -> GalleryPage {
        authoredAsks.append(pageToken)
        return authored[pageToken] ?? GalleryPage(posts: [], nextPageToken: nil)
    }
    func taggedPage(for profileID: ProfileID, handle: String, after pageToken: String?) async throws -> GalleryPage {
        GalleryPage(posts: [], nextPageToken: nil)
    }
    func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
    func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
    func posts(ids: [String]) async throws -> [GalleryPost] { [] }

    func deletePost(_ postID: PostID, author: ProfileID) async throws {}
    func recentlyDeleted(for author: ProfileID) async throws -> [DeletedPost] { [] }
    func restorePost(_ postID: PostID, author: ProfileID) async throws {}
}

private func person(_ id: String = "prof-1", visibility: ProfileVisibility = .public) -> UserProfile {
    UserProfile(
        id: ProfileID(id), handle: "ada", displayName: "Ada", bio: "",
        avatarURL: nil, websiteURL: nil, isVerified: false, visibility: visibility,
        followerCount: .exact(0), followingCount: .exact(0), reactionCount: .unavailable
    )
}

private actor RevisitProfiles: ProfileProviding {
    let profile: UserProfile
    let answer: ProfileRelationship
    init(_ profile: UserProfile = person(), relationship: ProfileRelationship = .other(isFollowing: false, isBlocked: false)) {
        self.profile = profile
        answer = relationship
    }
    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile { profile }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { answer }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile { profile }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
}

@MainActor
struct ProfileGalleryRevisitTests {
    @MainActor
    private final class Shown {
        var snapshots: [ProfileViewModel.GallerySnapshot] = []
    }

    /// Waits for STATE, counted in looks (the pattern of `GalleryPagingTests`).
    @discardableResult
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Grace for "nothing more should happen".
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func ids(_ state: ProfileViewModel.GalleryPageState?) -> [String] {
        guard case .content(let posts) = state else { return [] }
        return posts.map(\.id.rawValue)
    }

    private let id = ProfileID("prof-1")

    private func visit(
        _ gallery: RevisitGallery, cache: ProfileCache, profiles: RevisitProfiles = RevisitProfiles()
    ) -> (ProfileViewModel, Shown) {
        let viewModel = ProfileViewModel(repository: profiles, gallery: gallery, source: .profile(id), cache: cache)
        let shown = Shown()
        viewModel.onGalleryChange = { shown.snapshots.append($0) }
        viewModel.viewDidLoad()
        return (viewModel, shown)
    }

    private func twoPages() -> RevisitGallery {
        RevisitGallery(authored: [
            nil: GalleryPage(posts: [post("a", at: 60), post("b", at: 50)], nextPageToken: "a2"),
            "a2": GalleryPage(posts: [post("c", at: 40)], nextPageToken: nil),
        ])
    }

    /// First visit: bones, then pages one and two, all kept beside the profile.
    private func firstVisit(_ gallery: RevisitGallery, cache: ProfileCache) async throws {
        let (viewModel, shown) = visit(gallery, cache: cache)
        #expect(shown.snapshots.first.map { $0.activity == .loading } ?? true, "a first visit opens on bones")
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b"] })
        viewModel.loadMoreGallery()
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b", "c"] })
    }

    @Test func aRevisitRendersTheLoadedPagesAtFrameZero() async throws {
        let cache = ProfileCache()
        let gallery = twoPages()
        try await firstVisit(gallery, cache: cache)

        let (viewModel, shown) = visit(gallery, cache: cache)

        // Before any await: the pages, not the bones.
        #expect(ids(shown.snapshots.first?.activity) == ["a", "b", "c"], "the revisit opened on bones")
        // The first page is asked again — and, agreeing, publishes nothing.
        try #require(await settle { await gallery.firstPageAsks >= 2 })
        await settle()
        #expect(shown.snapshots.count == 1, "a revalidation that agreed re-rendered the grid")
        #expect(shown.snapshots.allSatisfy { $0.activity != .loading })
        // Alive throughout: the screen holds its view model.
        withExtendedLifetime(viewModel) {}
    }

    @Test func aRevisitRevalidatesInPlace() async throws {
        let cache = ProfileCache()
        let gallery = twoPages()
        try await firstVisit(gallery, cache: cache)
        await gallery.setAuthored(
            GalleryPage(posts: [post("new", at: 70), post("a", at: 60), post("b", at: 50)], nextPageToken: "a2"),
            for: nil
        )

        let (viewModel, shown) = visit(gallery, cache: cache)

        #expect(ids(shown.snapshots.first?.activity) == ["a", "b", "c"])
        // Merged over the later page, never cut back to the first.
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["new", "a", "b", "c"] })
        #expect(shown.snapshots.allSatisfy { $0.activity != .loading }, "the grid fell back to bones")
        withExtendedLifetime(viewModel) {}
    }

    @Test func aFirstVisitStillOpensOnBones() async throws {
        let cache = ProfileCache()
        cache.store(person())
        let (viewModel, shown) = visit(twoPages(), cache: cache)
        #expect(shown.snapshots.first?.activity == .loading, "nothing cached, so bones")
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b"] })
        withExtendedLifetime(viewModel) {}
    }

    @Test func aViewerChangeForgetsTheGallery() async throws {
        let center = NotificationCenter()
        let cache = ProfileCache(center: center)
        try await firstVisit(twoPages(), cache: cache)
        #expect(cache.gallery(for: id) != nil)

        center.post(name: .viewerDidChange, object: nil)

        #expect(cache.gallery(for: id) == nil, "the previous viewer's gallery survived")
    }

    @Test func theGalleryIsBoundByTheProfileLRU() {
        let cache = ProfileCache(limit: 2)
        let pages = ProfileGalleryStore.Corpora(
            authored: .init(posts: [post("a", at: 1)], nextToken: nil, hasLaterPages: false), tagged: nil
        )
        for raw in ["p1", "p2", "p3"] { cache.store(pages, for: ProfileID(raw)) }
        #expect(cache.gallery(for: ProfileID("p1")) == nil, "past the limit, the oldest goes")
        #expect(cache.gallery(for: ProfileID("p2")) != nil)
        #expect(cache.gallery(for: ProfileID("p3")) != nil)
    }

    // MARK: - Truthful, or dropped

    private func cacheHolding(_ profile: UserProfile, _ relationship: ProfileRelationship) -> ProfileCache {
        let cache = ProfileCache()
        cache.store(profile)
        cache.store(relationship, for: profile.id)
        cache.store(ProfileGalleryStore.Corpora(
            authored: .init(posts: [post("a", at: 1)], nextToken: nil, hasLaterPages: false), tagged: nil
        ), for: profile.id)
        return cache
    }

    /// A private profile's posts are its followers': an unfollow, a follow
    /// or a block drops the gallery the last visit saw.
    @Test func aFollowChangeOnAPrivateProfileDropsTheGallery() {
        let unfollowed = cacheHolding(person(visibility: .private), .other(isFollowing: true, isBlocked: false))
        unfollowed.store(.other(isFollowing: false, isBlocked: false), for: id)
        #expect(unfollowed.gallery(for: id) == nil)

        let followed = cacheHolding(person(visibility: .private), .other(isFollowing: false, isBlocked: false))
        followed.store(.other(isFollowing: true, isBlocked: false), for: id)
        #expect(followed.gallery(for: id) == nil)
    }

    @Test func aFollowHeardFromElsewhereDropsAPrivateProfilesGallery() async {
        let events = FollowGraphEvents()
        let cache = cacheHolding(person(visibility: .private), .other(isFollowing: true, isBlocked: false))
        cache.observe(events)
        events.publish(FollowChange(profileID: id, isFollowing: false))
        #expect(await settle { cache.gallery(for: id) == nil })
    }

    /// A public profile shows everyone the same posts: a follow keeps them.
    @Test func aFollowOnAPublicProfileKeepsTheGallery() {
        let cache = cacheHolding(person(visibility: .public), .other(isFollowing: false, isBlocked: false))
        cache.store(.other(isFollowing: true, isBlocked: false), for: id)
        #expect(cache.gallery(for: id) != nil)
    }

    @Test func aBlockDropsTheGallery() async throws {
        let cache = ProfileCache()
        let gallery = twoPages()
        try await firstVisit(gallery, cache: cache)
        let (viewModel, _) = visit(gallery, cache: cache)
        try #require(await settle { viewModel.canModerate })

        viewModel.block(.profile)

        #expect(await settle { viewModel.isBlocked })
        #expect(cache.gallery(for: id) == nil, "a revisit would open on a blocked profile's posts")
    }

    /// The viewer's own post, deleted from their grid, is gone from the cache
    /// too: the next visit never opens on it.
    @Test func aDeletedPostLeavesTheCachedGallery() async throws {
        let cache = ProfileCache()
        let gallery = twoPages()
        let (viewModel, shown) = visit(gallery, cache: cache, profiles: RevisitProfiles(relationship: .me))
        try #require(await settle { ids(shown.snapshots.last?.activity) == ["a", "b"] && viewModel.isRelationshipSettled })

        viewModel.deletePost(PostID("a"))

        #expect(await settle { ids(shown.snapshots.last?.activity) == ["b"] })
        #expect(cache.gallery(for: id)?.authored?.posts.map(\.id.rawValue) == ["b"])
    }

    @Test func aRestoredPostDropsTheAuthorsGallery() async throws {
        let cache = cacheHolding(person(), .me)
        let restored = ProfileID("prof-1")
        let viewModel = RecentlyDeletedViewModel(
            trash: twoPages(), viewer: RestoreViewer(id: restored),
            onRestored: { cache.removeGallery(for: $0) }
        )
        try await viewModel.restore(DeletedPost(post: post("a", at: 1), deletedAt: Date()))
        #expect(cache.gallery(for: restored) == nil)
    }
}

private struct RestoreViewer: ProfileViewerResolving {
    let id: ProfileID
    func viewerProfileID() async -> ProfileID? { id }
}
