import CacheKit
import Foundation
import Testing
@testable import LocalStore

/// Lists, pages, cursors, expiry, and one row per entity across lists (#893).
final class LocalStoreListTests {
    private let folder = TemporaryFolder()
    private let viewer = ViewerBox(alice)
    private let clock = ManualCacheClock()

    private func open() throws -> LocalStore {
        try LocalStore.test(in: folder, viewer: viewer, clock: clock)
    }

    // MARK: - Pages and cursors

    @Test func nextPagesAppendInOrderAndMoveTheCursor() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1", "p2"], cursor: "c1"), as: alice)
        #expect(try store.appendPage(page(["p3", "p4"], cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice))
        #expect(try store.appendPage(page(["p5"], cursor: nil, tier: .recent), to: "forYou", after: "c2", as: alice))
        let list = try #require(store.list("forYou"))
        #expect(ids(list) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(list.nextCursor == nil, "the list ends with its last page")
        #expect(list.pageCount == 3)
    }

    @Test func theFirstPageReadsAloneWithItsOwnCursor() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1", "p2"], author: "a1", cursor: "c1"), as: alice)
        try store.appendPage(page(["p3"], author: "a2", cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice)
        let first = try #require(store.list("forYou", maxPages: 1))
        #expect(ids(first) == ["p1", "p2"])
        #expect(first.nextCursor == "c1", "the first load's answer goes on from here")
        #expect(first.pageCount == 1)
        #expect(Set(first.attachments.keys) == [profileKey("a1")])
    }

    @Test func aStoredPageIsFoundByTheCursorThatFetchesIt() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1"], author: "a1", cursor: "c1"), as: alice)
        try store.appendPage(page(["p2", "p1"], cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice)
        try store.appendPage(page(["p3"], author: "a3", cursor: nil, tier: .recent), to: "forYou", after: "c2", as: alice)
        let second = try #require(store.page(of: "forYou", after: "c1"))
        #expect(ids(second) == ["p2"], "its own entries; p1 stays on the page that first carried it")
        #expect(second.nextCursor == "c2")
        #expect(second.attachments[profileKey("a1")] != nil, "with the attachments of the pages before it")
        let third = try #require(store.page(of: "forYou", after: "c2"))
        #expect(ids(third) == ["p3"])
        #expect(third.nextCursor == nil)
        #expect(store.page(of: "forYou", after: "unknown") == nil)
        viewer.viewer = bob
        #expect(store.page(of: "forYou", after: "c1") == nil, "another viewer reads no page either")
    }

    @Test func aPageThatDoesNotFollowTheStoredOnesIsRefused() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1"], cursor: "c1"), as: alice)
        // Fetched with a cursor of a list a refresh has since replaced.
        #expect(try !store.appendPage(page(["stale"], cursor: "c9", tier: .recent), to: "forYou", after: "c0", as: alice))
        // A list that is not stored at all.
        #expect(try !store.appendPage(page(["x"], cursor: nil, tier: .recent), to: "missing", after: "c1", as: alice))
        #expect(ids(store.list("forYou")) == ["p1"])
        #expect(store.list("missing") == nil)
    }

    @Test func aRefreshReplacesTheWholeListAndItsCursor() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1", "p2"], cursor: "c1"), as: alice)
        try store.appendPage(page(["p3"], cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice)
        try store.replaceList("forYou", with: page(["n1", "p1"], cursor: "d1"), as: alice)
        let list = try #require(store.list("forYou"))
        #expect(ids(list) == ["n1", "p1"])
        #expect(list.nextCursor == "d1")
        #expect(list.pageCount == 1)
        // p2 and p3 were held by the old pages alone: gone with them.
        #expect(store.entity(postKey("p2")) == nil)
        #expect(store.entity(postKey("p3")) == nil)
        #expect(store.entity(postKey("p1")) != nil)
    }

    @Test func anEntryServedAgainOnALaterPageKeepsItsFirstPlace() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1", "p2"], cursor: "c1"), as: alice)
        // The ranking moved p2 onto page 2 as well.
        try store.appendPage(page(["p2", "p3"], cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice)
        #expect(ids(store.list("forYou")) == ["p1", "p2", "p3"])
    }

    @Test func attachmentsRideWithTheirPage() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1"], author: "a1", cursor: "c1"), as: alice)
        try store.appendPage(page(["p2"], author: "a2", cursor: nil, tier: .recent), to: "forYou", after: "c1", as: alice)
        let list = try #require(store.list("forYou"))
        #expect(ids(list) == ["p1", "p2"], "attachments are not entries")
        #expect(Set(list.attachments.keys) == [profileKey("a1"), profileKey("a2")])
    }

    // MARK: - One row per entity

    @Test func aPostInTwoListsIsOneRowAndBothReadTheFreshestCopy() throws {
        let store = try open()
        try store.replaceList("forYou", with: LocalListPage(
            items: [postKey("shared"), postKey("f1")],
            entities: [post("shared", "v1: 3 likes"), post("f1")],
            nextCursor: nil, tier: .retained
        ), as: alice)
        try store.replaceList("following", with: LocalListPage(
            items: [postKey("shared")],
            entities: [post("shared", "v2: 4 likes")],
            nextCursor: nil, tier: .retained
        ), as: alice)
        #expect(try store.rowCount("entity") == 2, "the shared post is stored once")
        let forYou = try #require(store.list("forYou"))
        let following = try #require(store.list("following"))
        #expect(text(forYou.entries.first) == "v2: 4 likes", "For You reads what Following fetched last")
        #expect(text(following.entries.first) == "v2: 4 likes")
    }

    @Test func aSharedPostOutlivesTheListThatGoes() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["shared", "f1"], cursor: nil), as: alice)
        try store.replaceList("following", with: page(["shared"], cursor: nil), as: alice)
        try store.removeList("forYou")
        #expect(store.entity(postKey("f1")) == nil, "held by For You alone")
        #expect(ids(store.list("following")) == ["shared"])
    }

    @Test func aRemovedEntityLeavesEveryList() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["gone", "f1"], cursor: nil), as: alice)
        try store.replaceList("following", with: page(["gone"], cursor: nil), as: alice)
        try store.removeEntities([postKey("gone")])
        #expect(ids(store.list("forYou")) == ["f1"])
        #expect(ids(store.list("following")) == [])
    }

    @Test func anEntityWrittenOnItsOwnSurvivesTheListsThatCarriedIt() throws {
        let store = try open()
        try store.write([profile("visited", tier: .recent)], as: alice)
        try store.replaceList("forYou", with: LocalListPage(
            items: [postKey("p1")], entities: [post("p1"), profile("visited")], nextCursor: nil, tier: .retained
        ), as: alice)
        try store.removeList("forYou")
        #expect(store.entity(profileKey("visited")) != nil)
    }

    // MARK: - Expiry

    @Test func aListExpiresADayAfterItsFirstPage() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1"], cursor: "c1"), as: alice)
        clock.advance(by: LocalStorePolicy.listLifetime - 60)
        // A later page does not extend the list's life.
        #expect(try store.appendPage(page(["p2"], cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice))
        #expect(ids(store.list("forYou")) == ["p1", "p2"])
        clock.advance(by: 120)
        #expect(store.list("forYou") == nil)
        #expect(try !store.appendPage(page(["p3"], cursor: nil, tier: .recent), to: "forYou", after: "c2", as: alice))
    }

    @Test func anExpiredEntityIsLeftOutOfItsList() throws {
        let store = try open()
        try store.replaceList("forYou", with: LocalListPage(
            items: [postKey("short"), postKey("long")],
            entities: [
                LocalEntityWrite(key: postKey("short"), payload: Data("s".utf8), lifetime: 60),
                post("long")
            ],
            nextCursor: nil, tier: .retained
        ), as: alice)
        clock.advance(by: 61)
        #expect(ids(store.list("forYou")) == ["long"])
        #expect(store.entity(postKey("short")) == nil)
    }

    @Test func theExpiredTrimSweepsExpiredRows() throws {
        let store = try open()
        try store.replaceList("old", with: page(["o1"], author: "a1", cursor: nil), as: alice)
        clock.advance(by: LocalStorePolicy.listLifetime + 1)
        try store.replaceList("new", with: page(["n1"], cursor: nil), as: alice)
        store.trim(.expired)
        store.waitForPendingWrites()
        #expect(try store.rowCount("list") == 1)
        #expect(store.entity(postKey("o1")) == nil)
        #expect(store.entity(profileKey("a1")) == nil, "the old list's attachments went with it")
        #expect(store.statistics.expirations >= 1)
    }

    @Test func aReadEntityKeepsItsFetchDate() throws {
        let store = try open()
        let fetched = clock.now
        try store.write([post("p1")], as: alice)
        clock.advance(by: 3_600)
        let entity = try #require(store.entity(postKey("p1")))
        #expect(entity.fetchedAt == fetched, "readers revalidate from the fetch date")
        #expect(entity.expiresAt == fetched.addingTimeInterval(LocalStorePolicy.postLifetime))
    }
}
