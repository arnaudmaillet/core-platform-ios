import Foundation
import Testing
@testable import CoreStorage

/// The viewing history behind the profile's History tab (#1344): newest
/// first, a re-view moves to the front, one pile per profile, remove one and
/// clear all.
struct PostViewHistoryStoreTests {
    private static func defaults() -> UserDefaults {
        let name = "post-view-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func member(_ profile: String) -> StorageScope {
        StorageScope(owner: .member(account: "A", profile: profile))
    }

    @Test func newestFirstAndAReViewMovesToTheFront() {
        let store = PostViewHistoryStore(defaults: Self.defaults(), scope: Self.member("P1"))
        store.record("a")
        store.record("b")
        store.record("c")
        #expect(store.postIDs == ["c", "b", "a"])
        store.record("a")
        #expect(store.postIDs == ["a", "c", "b"], "a re-view duplicated the post or stayed put")
    }

    @Test func removeOneAndClearAll() {
        let store = PostViewHistoryStore(defaults: Self.defaults(), scope: Self.member("P1"))
        for id in ["a", "b", "c"] { store.record(id) }
        store.remove("b")
        #expect(store.postIDs == ["c", "a"])
        store.clear()
        #expect(store.postIDs.isEmpty)
    }

    /// One pile per profile: a switch shows that profile's history.
    @Test func eachProfileHasItsOwnHistory() {
        let defaults = Self.defaults()
        let scope = Self.member("P1")
        let store = PostViewHistoryStore(defaults: defaults, scope: scope)
        store.record("p1-post")
        scope.owner = .member(account: "A", profile: "P2")
        #expect(store.postIDs.isEmpty, "another profile saw P1's history")
        store.record("p2-post")
        scope.owner = .member(account: "A", profile: "P1")
        #expect(store.postIDs == ["p1-post"])
    }

    @Test func theHistoryKeepsTheMostRecent() {
        let store = PostViewHistoryStore(defaults: Self.defaults(), scope: Self.member("P1"))
        for index in 0..<(PostViewHistoryStore.capacity + 5) { store.record("p\(index)") }
        #expect(store.postIDs.count == PostViewHistoryStore.capacity)
        #expect(store.postIDs.first == "p\(PostViewHistoryStore.capacity + 4)")
    }

    @Test func aChangeIsAnnounced() {
        let store = PostViewHistoryStore(defaults: Self.defaults(), scope: Self.member("P1"))
        var changes = 0
        store.onChange = { changes += 1 }
        store.record("a")
        store.record("a") // already at the front: no change
        store.remove("missing")
        store.clear()
        #expect(changes == 2)
    }
}
