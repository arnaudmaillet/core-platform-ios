import CacheKit
import CoreModels
import Foundation
import Testing
@testable import EntityStore

/// One post and one profile per id, observed by every screen (#896).
@MainActor
struct EntityStoreTests {
    // MARK: - A change made in one place reaches every observer

    @Test func aChangeMadeInOnePlaceReachesTwoObservers() {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 10)])
        var feedRow: [Int64?] = []
        var gridTile: [Int64?] = []
        let row = store.observePost(PostID("p1")) { id in feedRow.append(store.post(id)?.likeCount) }
        let grid = store.observePosts { change in
            if change.contains(PostID("p1")) { gridTile.append(store.post(PostID("p1"))?.likeCount) }
        }

        // The feed's like: the count moves at once, on both screens.
        store.addLikes(1, to: PostID("p1"))

        #expect(feedRow == [11])
        #expect(gridTile == [11])
        withExtendedLifetime((row, grid)) {}
    }

    @Test func aRealtimeTickWrittenOffTheMainThreadReachesObserversOnTheMainActor() async {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 10)])
        let heard: Int64? = await withCheckedContinuation { continuation in
            let box = ObservationBox()
            box.observation = store.observePost(PostID("p1")) { id in
                #expect(Thread.isMainThread)
                box.observation = nil
                continuation.resume(returning: store.post(id)?.likeCount)
            }
            Task.detached { store.setLikeCount(42, for: PostID("p1")) }
        }
        #expect(heard == 42)
    }

    @Test func aWriteThatChangesNothingCallsNoObserver() {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 10)])
        var calls = 0
        let observation = store.observePost(PostID("p1")) { _ in calls += 1 }
        store.setLikeCount(10, for: PostID("p1"))
        store.upsert([entry("p1", likes: 10)])
        #expect(calls == 0)
        withExtendedLifetime(observation) {}
    }

    @Test func aCancelledObserverHearsNothing() {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 10)])
        var calls = 0
        let observation = store.observePost(PostID("p1")) { _ in calls += 1 }
        observation.cancel()
        store.setLikeCount(11, for: PostID("p1"))
        #expect(calls == 0)
    }

    @Test func aFollowFromOneScreenReachesAnotherScreensBadge() {
        let store = EntityStore()
        let author = ProfileID("a1")
        store.setRelation(.followedBy, for: author)
        var badges: [FollowRelation?] = []
        let observation = store.observeProfile(author) { id in badges.append(store.relation(to: id)) }

        // The graph accepted a follow made on the author's profile.
        store.applyFollowChange(FollowChange(profileID: author, isFollowing: true))

        #expect(badges == [.mutual], "following someone who follows the viewer makes a friend")
        withExtendedLifetime(observation) {}
    }

    @Test func anAcceptedFollowLeavesAnUnknownRelationUnknown() {
        let store = EntityStore()
        store.applyFollowChange(FollowChange(profileID: ProfileID("a1"), isFollowing: true))
        #expect(store.relation(to: ProfileID("a1")) == nil, "a guess would draw a one-way follow for a friend")
    }

    @Test func setRelationReturnsWhatWasKnownForARollback() {
        let store = EntityStore()
        let author = ProfileID("a1")
        #expect(store.setRelation(.notFollowing, for: author) == nil)
        #expect(store.setRelation(.following, for: author) == .notFollowing)
        store.setRelation(nil, for: author)
        #expect(store.relation(to: author) == nil)
    }

    // MARK: - Viewer reset

    @Test func aViewerChangeWipesTheViewersFactsAndKeepsTheContent() {
        let store = EntityStore()
        let coordinator = CacheCoordinator(device: device)
        store.register(with: coordinator)
        store.upsert([entry("p1", author: "a1", likes: 10)])
        store.setRelation(.following, for: ProfileID("a1"))
        store.setSaved(true, for: PostID("p1"))
        var postCalls = 0
        var profileChanges: [EntityChange<ProfileID>] = []
        let post = store.observePost(PostID("p1")) { _ in postCalls += 1 }
        let profiles = store.observeProfiles { profileChanges.append($0) }

        coordinator.trim(.viewerChanged)

        #expect(store.relation(to: ProfileID("a1")) == nil)
        #expect(store.isSaved(PostID("p1")) == nil)
        #expect(store.post(PostID("p1"))?.likeCount == 10, "the content is the same for every viewer")
        #expect(store.profile(ProfileID("a1"))?.summary?.handle == "a1")
        #expect(postCalls == 1, "a screen drawing the saved glyph re-draws")
        #expect(profileChanges == [.everything])
        // `-cache-audit` (#900) reads the wipe through the wrapper.
        let relations = coordinator.usage().lines.first { $0.namespace.name == "entities.relations" }
        #expect(relations?.statistics.removals[.viewerChanged] == 1)
        withExtendedLifetime((post, profiles)) {}
    }

    @Test func theViewersFactsAreViewerScopedNamespacesAndTheContentIsPublic() {
        let store = EntityStore()
        let scopes = Dictionary(uniqueKeysWithValues: store.managedCaches.map { ($0.namespace.name, $0.namespace.scope) })
        #expect(scopes == [
            "entities.posts": .public, "entities.profiles": .public,
            "entities.relations": .viewer, "entities.saved": .viewer
        ])
        #expect(store.managedCaches.allSatisfy { $0.medium == .memory && $0.namespace.priorityClass == .preferred })
    }

    // MARK: - Memory trim

    @Test func theStoreKeepsItsCountBudget() {
        let store = EntityStore(postLimit: 10, profileLimit: 5)
        store.upsert((0..<20).map { entry("p\($0)", author: "a\($0)") })
        #expect(store.posts.usage.count == 10)
        #expect(store.profiles.usage.count == 5)
        #expect(store.post(PostID("p19")) != nil, "the newest stay")
        #expect(store.post(PostID("p0")) == nil, "the oldest went first")
    }

    @Test func anObservedPostSurvivesEvictionAndACriticalTrim() {
        let store = EntityStore(postLimit: 10)
        let coordinator = CacheCoordinator(device: device)
        store.register(with: coordinator)
        store.upsert([entry("shown", likes: 7)])
        let observation = store.observePost(PostID("shown")) { _ in }

        store.upsert((0..<30).map { entry("p\($0)") })
        #expect(store.post(PostID("shown"))?.likeCount == 7, "a budget never evicts what a screen observes")

        coordinator.trim(.memoryCritical)
        #expect(store.post(PostID("shown")) != nil, "nor does a critical trim")
        #expect(store.posts.usage.count == 1)

        observation.cancel()
        coordinator.trim(.memoryCritical)
        #expect(store.post(PostID("shown")) == nil, "released, it goes like the others")
    }

    @Test func aPostObservedBeforeItLoadsIsPinnedOnceItLands() {
        let store = EntityStore(postLimit: 5)
        let observation = store.observePost(PostID("late")) { _ in }
        store.upsert([entry("late")])
        store.upsert((0..<10).map { entry("p\($0)") })
        #expect(store.post(PostID("late")) != nil)
        withExtendedLifetime(observation) {}
    }

    @Test func aMemoryWarningTakesTheLookaheadFirst() {
        let store = EntityStore()
        let coordinator = CacheCoordinator(device: device)
        store.register(with: coordinator)
        store.upsert([entry("seen")])
        store.upsert([entry("lookahead")], tier: .speculative)

        coordinator.trim(.memoryWarning)

        #expect(store.post(PostID("lookahead")) == nil)
        #expect(store.post(PostID("seen")) != nil)
    }

    // MARK: - Dedup across lists

    @Test func aPostTwoListsLoadIsOneEntity() {
        let store = EntityStore()
        // For You's grid and the vertical feed's lookahead load the same post.
        store.upsert([entry("p1", author: "a1", likes: 10), entry("p2", author: "a1")])
        store.upsert([entry("p1", author: "a1", likes: 10)], tier: .speculative)

        #expect(store.posts.usage.count == 2)
        #expect(store.profiles.usage.count == 1, "the author too")
        #expect(store.posts.tier(of: PostID("p1")) == .recent, "a lookahead never demotes what was seen")

        var gridHeard: [Int64?] = []
        let grid = store.observePost(PostID("p1")) { id in gridHeard.append(store.post(id)?.likeCount) }
        store.addLikes(3, to: PostID("p1"))
        #expect(gridHeard == [13])
        withExtendedLifetime(grid) {}
    }

    @Test func aRestoredPageNeverReplacesACountTheStoreKnows() {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 50)])
        store.upsert([entry("p1", likes: 10)], counts: .ifUnknown)
        #expect(store.post(PostID("p1"))?.likeCount == 50)
        store.upsert([entry("p2", likes: 10)], counts: .ifUnknown)
        #expect(store.post(PostID("p2"))?.likeCount == 10)
        store.mergeCounts([PostID("p1"): PostCounts(likes: 9, comments: 4)], freshness: .ifUnknown)
        #expect(store.post(PostID("p1"))?.likeCount == 50)
        #expect(store.post(PostID("p1"))?.commentCount == 4)
    }

    @Test func aRestoredPageNeverReplacesAnEditOrARename() {
        let store = EntityStore()
        store.upsert([entry("p1", author: "a1")])
        store.replacePost(post("p1", caption: "edited"))
        let renamed = AuthorSummary(id: ProfileID("a1"), handle: "new", displayName: "New", avatarURL: nil)
        store.upsert(renamed)
        store.upsert([entry("p1", author: "a1")], counts: .ifUnknown)
        #expect(store.post(PostID("p1"))?.post?.caption == "edited")
        #expect(store.profile(ProfileID("a1"))?.summary?.handle == "new")
    }

    @Test func aLikeOnAPostWithNoKnownCountMovesNothing() {
        let store = EntityStore()
        store.addLikes(1, to: PostID("unknown"))
        #expect(store.post(PostID("unknown")) == nil)
    }

    // MARK: - Delete

    @Test func aDeleteRemovesThePostEverywhere() {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 10), entry("p2")])
        var feedIDs = [PostID("p1"), PostID("p2")]
        var gridIDs = [PostID("p2"), PostID("p1")]
        let feed = store.observePosts { change in
            feedIDs.removeAll { change.contains($0) && store.isDeleted($0) }
        }
        let tile = store.observePost(PostID("p1")) { id in
            if store.isDeleted(id) { gridIDs.removeAll { $0 == id } }
        }

        // Deleted from the profile.
        store.deletePost(PostID("p1"))

        #expect(feedIDs == [PostID("p2")])
        #expect(gridIDs == [PostID("p2")])
        #expect(store.post(PostID("p1")) == nil)

        // A page fetched before the delete, and a realtime tick, land after it.
        store.upsert([entry("p1", likes: 11)])
        store.setLikeCount(12, for: PostID("p1"))
        #expect(store.post(PostID("p1")) == nil, "nothing brings a deleted post back")
        withExtendedLifetime((feed, tile)) {}
    }

    /// Settings → Recently Deleted brings it back: the next page carrying
    /// it is let in again.
    @Test func aRestoredPostComesBackWithTheNextPage() {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 10)])
        store.deletePost(PostID("p1"))

        store.restorePost(PostID("p1"))

        #expect(!store.isDeleted(PostID("p1")))
        #expect(store.post(PostID("p1")) == nil, "nothing is put back until a list loads it")
        store.upsert([entry("p1", likes: 11)])
        #expect(store.post(PostID("p1"))?.likeCount == 11)
        // Deleted again: one tombstone, as before.
        store.deletePost(PostID("p1"))
        #expect(store.isDeleted(PostID("p1")))
    }

    @Test func anEditKeepsTheCounters() {
        let store = EntityStore()
        store.upsert([entry("p1", likes: 10)])
        store.replacePost(post("p1", caption: "edited"))
        #expect(store.post(PostID("p1"))?.post?.caption == "edited")
        #expect(store.post(PostID("p1"))?.likeCount == 10)
    }

    @Test func aHiddenCountIsNoNumber() {
        let store = EntityStore()
        let hidden = Post(
            id: PostID("p1"), authorID: ProfileID("a1"), caption: "", attachments: [],
            publishedAt: Date(timeIntervalSince1970: 0), likeCountsHidden: true
        )
        store.upsert([FeedEntry(post: hidden, author: author("a1"), likeCount: 10)])
        #expect(store.post(PostID("p1"))?.visibleLikeCount == nil)
    }

    // MARK: - Fixtures

    private var device: CacheDevice {
        CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) })
    }

    private func post(_ id: String, author: String = "a1", caption: String = "") -> Post {
        Post(id: PostID(id), authorID: ProfileID(author), caption: caption, attachments: [],
             publishedAt: Date(timeIntervalSince1970: 0))
    }

    private func author(_ id: String) -> AuthorSummary {
        AuthorSummary(id: ProfileID(id), handle: id, displayName: id.uppercased(), avatarURL: nil)
    }

    private func entry(_ id: String, author authorID: String = "a1", likes: Int64 = 0) -> FeedEntry {
        FeedEntry(post: post(id, author: authorID), author: author(authorID), likeCount: likes)
    }
}

/// Holds an observation a handler releases itself.
private final class ObservationBox: @unchecked Sendable {
    var observation: EntityObservation?
}
