import CoreStorage
import Foundation
import Testing
@testable import Chat

/// The played voice messages are the profile's (#2376): what one viewer
/// played is not the next one's, and the list kept before it was scoped goes
/// to the first member profile that reads it.
@MainActor
struct VoicePlayedStoreTests {
    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "VoicePlayed.\(UUID().uuidString)"))
    }

    @Test func anotherViewerReadsNothingOfThePreviousOnesPlays() throws {
        let defaults = try Self.defaults()
        let scope = StorageScope(owner: .member(account: "A", profile: "pa"))
        let store = VoicePlayedStore(defaults: defaults, scope: scope)
        store.markPlayed("m1")
        #expect(store.isPlayed("m1"))

        scope.owner = .guest
        #expect(!store.isPlayed("m1"), "the guest read A's plays")
        scope.owner = .member(account: "B", profile: nil)
        #expect(!store.isPlayed("m1"), "B, before their profile resolved, read A's plays")
        scope.owner = .member(account: "B", profile: "pb")
        #expect(!store.isPlayed("m1"), "B read A's plays")
        store.markPlayed("m2")

        scope.owner = .member(account: "A", profile: "pa")
        #expect(store.isPlayed("m1"))
        #expect(!store.isPlayed("m2"), "A read B's plays")
    }

    @Test func theUnscopedListGoesToTheFirstMemberProfile() throws {
        let defaults = try Self.defaults()
        defaults.set(["m1"], forKey: VoicePlayedStore.key)
        let scope = StorageScope(owner: .guest)
        let store = VoicePlayedStore(defaults: defaults, scope: scope)
        #expect(!store.isPlayed("m1"), "a guest inherited the install's list")

        scope.owner = .member(account: "A", profile: "pa")
        #expect(store.isPlayed("m1"))
        #expect(defaults.object(forKey: VoicePlayedStore.key) == nil)

        scope.owner = .member(account: "B", profile: "pb")
        #expect(!store.isPlayed("m1"))
    }

    /// Built with the chat feature at launch, it reads nothing until asked.
    @Test func theListIsReadOnFirstUse() throws {
        let defaults = try Self.defaults()
        let scope = StorageScope(owner: .member(account: "A", profile: "pa"))
        let store = VoicePlayedStore(defaults: defaults, scope: scope)
        defaults.set(["m1"], forKey: scope.profileKey(VoicePlayedStore.key))
        #expect(store.isPlayed("m1"))
    }
}
