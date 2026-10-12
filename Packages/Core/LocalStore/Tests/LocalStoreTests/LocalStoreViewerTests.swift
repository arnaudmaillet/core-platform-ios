import CacheKit
import Foundation
import Testing
@testable import LocalStore

/// Logout, account switch and profile switch: nothing of the previous viewer
/// is readable, and the rows are wiped (#893, decision 4 of #890).
final class LocalStoreViewerTests {
    private let folder = TemporaryFolder()
    private let viewer = ViewerBox(alice)

    private func storeWithAlicesFeed() throws -> LocalStore {
        let store = try LocalStore.test(in: folder, viewer: viewer)
        try store.replaceList("following", with: page(["p1", "p2"], author: "a1", cursor: "c1"), as: alice)
        try store.write([profile("prof-1", "alice's own profile", tier: .retained)], as: alice)
        #expect(ids(store.list("following")) == ["p1", "p2"])
        return store
    }

    private func expectNothingReadable(_ store: LocalStore) {
        #expect(store.list("following") == nil)
        #expect(store.entity(postKey("p1")) == nil)
        #expect(store.entity(profileKey("prof-1")) == nil)
        #expect(store.entities([postKey("p1"), postKey("p2"), profileKey("a1")]).isEmpty)
    }

    private func expectWiped(_ store: LocalStore) throws {
        store.waitForPendingWrites()
        #expect(try store.rowCount("entity") == 0)
        #expect(try store.rowCount("list") == 0)
        #expect(try store.rowCount("list_item") == 0)
        #expect(try store.rowCount("meta") == 0)
    }

    @Test func aLogoutLeavesNothingReadableAndWipesTheRows() throws {
        let store = try storeWithAlicesFeed()
        viewer.viewer = .guest
        expectNothingReadable(store)
        try expectWiped(store)
    }

    @Test func anAccountSwitchLeavesNothingReadable() throws {
        let store = try storeWithAlicesFeed()
        viewer.viewer = bob
        expectNothingReadable(store)
        try expectWiped(store)
    }

    @Test func aProfileSwitchLeavesNothingReadable() throws {
        let store = try storeWithAlicesFeed()
        viewer.viewer = aliceSecondProfile
        expectNothingReadable(store)
        try expectWiped(store)
    }

    @Test func aRelaunchAsSomeoneElseReadsNothing() throws {
        do { _ = try storeWithAlicesFeed() }
        viewer.viewer = bob
        let reopened = try LocalStore.test(in: folder, viewer: viewer)
        expectNothingReadable(reopened)
        try expectWiped(reopened)
    }

    @Test func nobodyYetReadsNothingAndWritesNothing() throws {
        let store = try storeWithAlicesFeed()
        viewer.viewer = nil
        #expect(store.list("following") == nil)
        #expect(try !store.replaceList("following", with: page(["x"], cursor: nil), as: nil))
        // Alice comes back: her rows were never someone else's, so they stay.
        viewer.viewer = alice
        #expect(ids(store.list("following")) == ["p1", "p2"])
    }

    @Test func anOfflineColdStartReadsTheSameAccountBeforeItsProfileResolves() throws {
        do { _ = try storeWithAlicesFeed() }
        // The active profile takes a network call to resolve.
        viewer.viewer = aliceUnresolved
        let reopened = try LocalStore.test(in: folder, viewer: viewer)
        #expect(ids(reopened.list("following")) == ["p1", "p2"])
        // It resolves to the profile that wrote them: still readable.
        viewer.viewer = alice
        #expect(ids(reopened.list("following")) == ["p1", "p2"])
    }

    @Test func aPageFetchedForAViewerWhoLeftIsDropped() throws {
        let store = try storeWithAlicesFeed()
        // Alice's request was in flight when Bob signed in.
        let capturedForAlice = store.currentViewer
        viewer.viewer = bob
        #expect(try !store.replaceList("following", with: page(["alice-late"], cursor: nil), as: capturedForAlice))
        #expect(try !store.write([post("alice-late")], as: capturedForAlice))
        #expect(store.list("following") == nil)
        #expect(store.entity(postKey("alice-late")) == nil)
    }

    @Test func theNextViewersFirstWriteWipesThePreviousRows() throws {
        let store = try storeWithAlicesFeed()
        viewer.viewer = bob
        #expect(try store.replaceList("forYou", with: page(["b1"], cursor: nil), as: bob))
        #expect(ids(store.list("forYou")) == ["b1"])
        #expect(try store.rowCount("list") == 1, "Alice's following list is gone")
        #expect(try store.rowCount("entity") == 1)
        viewer.viewer = alice
        expectNothingReadable(store)
    }

    @Test func removeAllIsTheWipeOfAViewerChange() throws {
        let store = try storeWithAlicesFeed()
        store.removeAll()
        // Nothing readable from the moment it returns, before the rows go.
        expectNothingReadable(store)
        try expectWiped(store)
        #expect(store.usage.bytes == 0)
    }

    @Test func aWriteAfterTheWipeIsKept() throws {
        let store = try storeWithAlicesFeed()
        store.removeAll()
        // The next viewer's first page, written right after the call: it is
        // queued behind the wipe, never erased by it.
        viewer.viewer = bob
        #expect(try store.replaceList("forYou", with: page(["b1"], cursor: nil), as: bob))
        store.waitForPendingWrites()
        #expect(ids(store.list("forYou")) == ["b1"])
        #expect(try store.rowCount("entity") == 1)
    }

    @Test func aWriteWithAResolvedProfileRecordsIt() throws {
        let store = try LocalStore.test(in: folder, viewer: viewer)
        viewer.viewer = aliceUnresolved
        try store.replaceList("following", with: page(["p1"], cursor: nil), as: aliceUnresolved)
        viewer.viewer = alice
        try store.write([post("p2")], as: alice)
        // Recorded as prof-1 now: a switch to prof-2 is someone else.
        viewer.viewer = aliceSecondProfile
        #expect(store.list("following") == nil)
    }

    @Test func viewersMatchOnlyTheSamePerson() {
        #expect(alice.isSamePerson(as: alice))
        #expect(alice.isSamePerson(as: aliceUnresolved))
        #expect(aliceUnresolved.isSamePerson(as: aliceSecondProfile))
        #expect(!alice.isSamePerson(as: aliceSecondProfile))
        #expect(!alice.isSamePerson(as: bob))
        #expect(!alice.isSamePerson(as: .guest))
        #expect(LocalStoreViewer.guest.isSamePerson(as: .guest))
        for each in [alice, aliceUnresolved, bob, LocalStoreViewer.guest] {
            #expect(LocalStoreViewer(encoded: each.encoded) == each)
        }
    }
}
