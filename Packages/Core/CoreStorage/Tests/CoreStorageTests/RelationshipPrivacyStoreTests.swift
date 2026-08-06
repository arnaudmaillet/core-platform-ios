import Foundation
import Testing
@testable import CoreStorage

/// The relationship-privacy preferences. These are LOCAL flags — see
/// `RelationshipPrivacySettings` for why the backend cannot express them — so
/// what there is to get right is that they persist, that they round-trip
/// independently, and that an unset or corrupt store reads as "nothing
/// hidden" rather than hiding everything.
@Suite("Relationship privacy store")
struct RelationshipPrivacyStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "RelationshipPrivacyStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Nothing is hidden until the viewer says so")
    func defaultsToPublic() throws {
        let store = RelationshipPrivacyStore(defaults: try makeDefaults())
        #expect(store.settings == RelationshipPrivacySettings())
        #expect(!store.settings.isAnyHidden)
    }

    @Test("A flag survives a new store over the same defaults")
    func persistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        RelationshipPrivacyStore(defaults: defaults).update { $0.hidesFollowers = true }

        #expect(RelationshipPrivacyStore(defaults: defaults).settings.hidesFollowers)
    }

    /// The three lists are separate settings, so writing one must not disturb
    /// the others — the whole struct is re-encoded on every write, which is
    /// exactly where a read-modify-write bug would flatten the other two.
    @Test("Each list toggles independently")
    func flagsAreIndependent() throws {
        let store = RelationshipPrivacyStore(defaults: try makeDefaults())

        store.update { $0.hidesFollowing = true }
        store.update { $0.hidesFriends = true }

        #expect(!store.settings.hidesFollowers)
        #expect(store.settings.hidesFollowing)
        #expect(store.settings.hidesFriends)
    }

    @Test("Turning a flag back off is persisted too")
    func clearsAFlag() throws {
        let store = RelationshipPrivacyStore(defaults: try makeDefaults())
        store.update { $0.hidesFollowers = true }

        store.update { $0.hidesFollowers = false }

        #expect(!store.settings.hidesFollowers)
    }

    /// Fails OPEN, not closed. A privacy store that hid every list when it
    /// couldn't read itself would silently change the viewer's settings on a
    /// bad decode; the honest reading of "I don't know" is the default.
    @Test("Unreadable stored data reads as the default")
    func corruptDataDegradesToDefault() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "relationshipPrivacySettings")

        #expect(RelationshipPrivacyStore(defaults: defaults).settings == RelationshipPrivacySettings())
    }
}
