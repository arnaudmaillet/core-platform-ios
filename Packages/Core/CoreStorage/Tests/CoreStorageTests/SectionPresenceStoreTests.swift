import Foundation
import Testing
@testable import CoreStorage

/// Last-known section presence (#1757): what a cold load's skeleton is drawn
/// from.
struct SectionPresenceStoreTests {
    private func makeStore(scope: StorageScope = StorageScope(owner: .member(account: "a", profile: "p"))) -> SectionPresenceStore {
        SectionPresenceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, scope: scope)
    }

    @Test func aSectionNeverLoadedIsUnknown() {
        #expect(makeStore().count(screen: "foryou", section: "friends") == nil)
    }

    @Test func anEmptySectionIsZeroAndAFullOneItsCount() {
        let store = makeStore()
        store.remember(0, screen: "foryou", section: "friends")
        store.remember(7, screen: "foryou", section: "following")
        #expect(store.count(screen: "foryou", section: "friends") == 0)
        #expect(store.count(screen: "foryou", section: "following") == 7)
    }

    /// Whether a viewer has friends is theirs: another profile on the device
    /// starts unknown.
    @Test func presenceIsPerProfile() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let scope = StorageScope(owner: .member(account: "a", profile: "p1"))
        let store = SectionPresenceStore(defaults: defaults, scope: scope)
        store.remember(3, screen: "foryou", section: "friends")
        scope.owner = .member(account: "a", profile: "p2")
        #expect(store.count(screen: "foryou", section: "friends") == nil)
        scope.owner = .member(account: "a", profile: "p1")
        #expect(store.count(screen: "foryou", section: "friends") == 3)
    }
}
