import CoreModels
import Foundation
import Synchronization
import Testing
@testable import CoreStorage

/// `PostBookmarkStore` as a view over the app's saved fact (#896): the pile is
/// the record, the fact is what every screen reads and observes.
struct PostBookmarkFactsTests {
    private static func defaults() -> UserDefaults {
        let name = "post-bookmark-facts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func member(_ profile: String) -> StorageScope {
        StorageScope(owner: .member(account: "A", profile: profile))
    }

    @Test func aSaveWritesThePileThenTheFact() {
        let facts = FakeSaveFacts()
        let store = PostBookmarkStore(defaults: Self.defaults(), scope: Self.member("P1"))
        store.facts = facts

        #expect(store.toggle("post-1"))
        #expect(store.savedPostIDs == ["post-1"])
        #expect(facts.isSaved(PostID("post-1")) == true)

        #expect(!store.toggle("post-1"))
        #expect(store.savedPostIDs.isEmpty)
        #expect(facts.isSaved(PostID("post-1")) == false)
    }

    /// A read asks the fact first: what a screen draws is what every other
    /// screen observes.
    @Test func aReadAsksTheFactFirstAndThePileWhenItIsUnknown() {
        let facts = FakeSaveFacts()
        let store = PostBookmarkStore(defaults: Self.defaults(), scope: Self.member("P1"))
        store.facts = facts
        store.toggle("post-1")

        facts.setSaved(false, for: PostID("post-1"))
        #expect(!store.isSaved("post-1"), "the fact answers")

        facts.forget()
        #expect(store.isSaved("post-1"), "the pile answers an unknown fact (a viewer wipe, an eviction)")
    }

    /// Between a profile switch and the store's wipe, a fact written for the
    /// last profile is never read for the next.
    @Test func aFactWrittenForAnotherProfileIsNotRead() {
        let facts = FakeSaveFacts()
        let scope = Self.member("P1")
        let store = PostBookmarkStore(defaults: Self.defaults(), scope: scope)
        store.facts = facts
        store.toggle("post-1")

        scope.owner = .member(account: "A", profile: "P2")

        #expect(facts.isSaved(PostID("post-1")) == true, "not wiped yet")
        #expect(!store.isSaved("post-1"), "P2's own pile answers")
    }
}

private final class FakeSaveFacts: PostSaveFacts {
    private let values = Mutex<[PostID: Bool]>([:])

    func isSaved(_ id: PostID) -> Bool? { values.withLock { $0[id] } }
    func setSaved(_ isSaved: Bool, for id: PostID) { values.withLock { $0[id] = isSaved } }
    func forget() { values.withLock { $0.removeAll() } }
}
