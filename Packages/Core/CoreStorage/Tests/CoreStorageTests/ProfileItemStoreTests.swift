import Foundation
import Testing
@testable import CoreStorage

/// Profile items (#944): bought once, for good, by the ACCOUNT.
struct ProfileItemStoreTests {
    private static func defaults() -> UserDefaults {
        let name = "profile-items-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theVideoBannerCostsFiveHundredGems() {
        #expect(ProfileItem.videoBanner.gemPrice == 500)
    }

    @Test func aGrantIsTheAccountsAndHappensOnce() {
        let store = ProfileItemStore(defaults: Self.defaults())
        #expect(!store.owns(.videoBanner, accountID: "acct-1"))
        #expect(store.grant(.videoBanner, to: "acct-1"))
        #expect(!store.grant(.videoBanner, to: "acct-1"), "already owned")
        #expect(store.owns(.videoBanner, accountID: "acct-1"))
        #expect(!store.owns(.videoBanner, accountID: "acct-2"), "another account owns nothing")
    }

    /// For good: a new store over the same defaults still owns it.
    @Test func ownershipOutlivesTheStore() {
        let defaults = Self.defaults()
        ProfileItemStore(defaults: defaults).grant(.videoBanner, to: "acct-1")
        #expect(ProfileItemStore(defaults: defaults).owned(by: "acct-1") == [.videoBanner])
    }
}
