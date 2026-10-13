import CoreModels
import Foundation
import Synchronization
import Testing
@testable import CoreStorage

/// The DEBUG `-reset-bookmarks` / `-seed-bookmarks` hooks act on the pile of
/// the viewer the launch resolves to, not on whatever scope held when the
/// app's one pile was made (#1074). Every test owns its defaults suite and its
/// scope, and hands the hooks their arguments: the process's are never read.
struct PostBookmarkLaunchHooksTests {
    private static let baseKey = "profile.savedPostIDs"

    private static func makeDefaults() -> UserDefaults {
        let name = "post-bookmark-launch-hooks-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The launch the app makes: the pile is created unscoped, the account
    /// signs in, then its active profile resolves.
    @Test func resetBookmarksClearsTheResolvedProfilesPileAndItsFacts() {
        let defaults = Self.makeDefaults()
        defaults.set(["post-1", "post-2"], forKey: Self.baseKey + "@p:P1")
        let scope = StorageScope(owner: .unscoped)
        let store = PostBookmarkStore(defaults: defaults, scope: scope, launchArguments: ["-reset-bookmarks"])
        let facts = LaunchFakeSaveFacts()
        store.facts = facts
        facts.setSaved(true, for: PostID("post-1"))

        scope.owner = .member(account: "A", profile: nil)
        #expect(defaults.array(forKey: Self.baseKey + "@p:P1") as? [String] == ["post-1", "post-2"],
                "nothing is cleared before the profile is known")

        scope.owner = .member(account: "A", profile: "P1")
        #expect(store.savedPostIDs.isEmpty, "the member's pile is empty after launch")
        #expect(!store.isSaved("post-1"))
        #expect(!store.isSaved("post-2"))
        #expect(facts.isSaved(PostID("post-1")) == false, "the saved fact in memory is cleared too")
        #expect(facts.isSaved(PostID("post-2")) == false)
    }

    /// Once per launch: a profile switch afterwards keeps the next profile's
    /// pile, and a save after the reset stays saved.
    @Test func resetBookmarksRunsOnceAndAProfileSwitchKeepsItsPile() {
        let defaults = Self.makeDefaults()
        defaults.set(["post-1"], forKey: Self.baseKey + "@p:P1")
        defaults.set(["post-9"], forKey: Self.baseKey + "@p:P2")
        let scope = StorageScope(owner: .member(account: "A", profile: "P1"))
        let store = PostBookmarkStore(defaults: defaults, scope: scope, launchArguments: ["-reset-bookmarks"])
        #expect(store.savedPostIDs.isEmpty, "a viewer already known is reset at once")

        store.toggle("post-3")
        scope.owner = .member(account: "A", profile: "P2")
        #expect(store.savedPostIDs == ["post-9"], "the switch resets nothing")
        scope.owner = .member(account: "A", profile: "P1")
        #expect(store.savedPostIDs == ["post-3"], "what was saved after the reset is kept")
    }

    @Test func withoutTheArgumentNothingIsCleared() {
        let defaults = Self.makeDefaults()
        defaults.set(["post-1"], forKey: Self.baseKey + "@p:P1")
        let scope = StorageScope(owner: .unscoped)
        let store = PostBookmarkStore(defaults: defaults, scope: scope, launchArguments: [])
        scope.owner = .member(account: "A", profile: "P1")
        #expect(store.savedPostIDs == ["post-1"])
    }

    /// The seed lands in the resolved profile's pile too, after a reset.
    @Test func seedBookmarksFillsTheResolvedProfilesPile() {
        let defaults = Self.makeDefaults()
        defaults.set(["post-1"], forKey: Self.baseKey + "@p:P1")
        let scope = StorageScope(owner: .unscoped)
        let store = PostBookmarkStore(
            defaults: defaults, scope: scope,
            launchArguments: ["-reset-bookmarks", "-seed-bookmarks", "post-7,post-8"]
        )
        scope.owner = .member(account: "A", profile: "P1")
        #expect(store.savedPostIDs == ["post-7", "post-8"])
        #expect(store.isSaved("post-7"))
        #expect(!store.isSaved("post-1"))
        #expect(defaults.object(forKey: Self.baseKey) == nil, "the unscoped key is never written")
    }
}

private final class LaunchFakeSaveFacts: PostSaveFacts {
    private let values = Mutex<[PostID: Bool]>([:])

    func isSaved(_ id: PostID) -> Bool? { values.withLock { $0[id] } }
    func setSaved(_ isSaved: Bool, for id: PostID) { values.withLock { $0[id] = isSaved } }
}
