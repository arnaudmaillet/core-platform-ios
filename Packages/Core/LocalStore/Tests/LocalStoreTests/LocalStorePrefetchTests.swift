import CacheKit
import Foundation
import Testing
@testable import LocalStore

/// Pages fetched ahead of the viewer (#970): stored `speculative`, promoted to
/// `recent` on their first display (`markShown`), and counted the way the
/// device cache counts every prefetched entry, so the speculative cap and the
/// waste ratio cover data too.
final class LocalStorePrefetchTests {
    private let folder = TemporaryFolder()
    private let viewer = ViewerBox(alice)
    private let clock = ManualCacheClock()

    private func open(limit: Int = .max, speculative: Int? = nil) throws -> LocalStore {
        try LocalStore.test(
            in: folder, viewer: viewer, clock: clock,
            limits: CacheLimits(bytes: limit, speculativeBytes: speculative ?? limit)
        )
    }

    /// Ten posts of 1 KB, as one page.
    private func tenPosts(_ prefix: String, cursor: String?, tier: CacheTier) -> LocalListPage {
        page((0..<10).map { "\(prefix)-\($0)" }, cursor: cursor, tier: tier, bytes: 1_000)
    }

    /// A first page and two pages fetched ahead.
    private func prefetchedList(_ store: LocalStore) throws {
        try store.replaceList("forYou", with: tenPosts("p0", cursor: "c1", tier: .retained), as: alice)
        #expect(try store.appendPage(tenPosts("p1", cursor: "c2", tier: .speculative), to: "forYou", after: "c1", as: alice))
        #expect(try store.appendPage(tenPosts("p2", cursor: "c3", tier: .speculative), to: "forYou", after: "c2", as: alice))
    }

    private func speculativeBytes(_ store: LocalStore) -> Int {
        store.usage.bytesByTier[.speculative, default: 0]
    }

    /// ⚠️ SHOWN, NOT READ. A post of the first prefetched page displayed:
    /// that page becomes `recent` and counts as used; the page after it
    /// stays speculative, under the cap. The second one shown: nothing is
    /// speculative any more.
    @Test func aPrefetchedPageShownBecomesRecentAndCountsAsUsed() throws {
        let store = try open()
        try prefetchedList(store)
        let both = speculativeBytes(store)
        #expect(both > 20_000)
        #expect(store.statistics.speculative.stored == 2)
        #expect(store.statistics.speculative.storedBytes == both)

        store.markShown(postKey("p1-3"), in: "forYou")
        store.waitForPendingWrites()
        let left = speculativeBytes(store)
        #expect(left > 0 && left < both, "the shown page left the speculative tier, the next one stayed")
        #expect(store.statistics.speculative.used == 1)
        #expect(store.statistics.speculative.usedBytes == both - left)

        store.markShown(postKey("p2-0"), in: "forYou")
        store.waitForPendingWrites()
        #expect(speculativeBytes(store) == 0)
        #expect(store.statistics.speculative.used == 2)
        #expect(store.statistics.speculative.wasteRatio == 0)
    }

    /// A post of the SECOND prefetched page shown first promotes the first
    /// one too: a page never outranks the one before it, so eviction keeps
    /// taking the list from its tail.
    @Test func showingALaterPagePromotesThePagesBeforeIt() throws {
        let store = try open()
        try prefetchedList(store)
        store.markShown(postKey("p2-9"), in: "forYou")
        store.waitForPendingWrites()
        #expect(speculativeBytes(store) == 0)
        #expect(store.statistics.speculative.used == 2)
        // Shown again, or a post of a page that is not prefetched: nothing.
        store.markShown(postKey("p2-1"), in: "forYou")
        store.markShown(postKey("p0-1"), in: "forYou")
        store.markShown(postKey("p1-1"), in: "other")
        store.waitForPendingWrites()
        #expect(store.statistics.speculative.used == 2)
    }

    /// A prefetched page trimmed away unread is WASTED: the waste ratio of
    /// the data lookahead.
    @Test func aPrefetchedPageEvictedUnreadIsWasted() throws {
        let store = try open()
        try prefetchedList(store)
        store.markShown(postKey("p1-0"), in: "forYou")
        store.trim(.speculative)
        store.waitForPendingWrites()
        #expect(ids(store.list("forYou")).count == 20, "the shown page stayed, the unread one went")
        let fates = store.statistics.speculative
        #expect(fates.used == 1)
        #expect(fates.wasted == 1)
        #expect(fates.wastedBytes > 0)
        #expect(fates.wasteRatio.map { $0 > 0.4 && $0 < 0.6 } == true)
    }

    /// Over the speculative cap, a prefetched page that does not fit beside
    /// the one before it is never kept: counted stored, then discarded, and
    /// the first page stays.
    @Test func aPrefetchedPageOverTheCapIsCountedAndDiscarded() throws {
        let store = try open(speculative: 15_000)
        try store.replaceList("forYou", with: tenPosts("p0", cursor: "c1", tier: .retained), as: alice)
        #expect(try store.appendPage(tenPosts("p1", cursor: "c2", tier: .speculative), to: "forYou", after: "c1", as: alice))
        #expect(try !store.appendPage(tenPosts("p2", cursor: "c3", tier: .speculative), to: "forYou", after: "c2", as: alice))
        #expect(speculativeBytes(store) <= 15_000)
        let fates = store.statistics.speculative
        // The second prefetched page did not fit beside the first: never kept.
        #expect(fates.stored == 2)
        #expect(fates.discarded == 1)
        #expect(fates.wasted == 0)
        #expect(ids(store.list(maxPages: 1, "forYou")).count == 10)
    }

    /// A refresh replaces the list: its unread prefetched pages are
    /// discarded, not wasted (nobody decided against them); a wipe too.
    @Test func aRefreshOrAWipeDiscardsUnreadPrefetchedPages() throws {
        let store = try open()
        try prefetchedList(store)
        try store.replaceList("forYou", with: tenPosts("n0", cursor: "d1", tier: .retained), as: alice)
        #expect(store.statistics.speculative.discarded == 2)
        #expect(store.statistics.speculative.wasted == 0)

        #expect(try store.appendPage(tenPosts("n1", cursor: "d2", tier: .speculative), to: "forYou", after: "d1", as: alice))
        store.removeAll()
        store.waitForPendingWrites()
        #expect(store.statistics.speculative.discarded == 3)
        #expect(store.statistics.speculative.storedBytes
            == store.statistics.speculative.discardedBytes + store.statistics.speculative.usedBytes
            + store.statistics.speculative.wastedBytes)
    }

    /// A cold start reading a prefetched page (offline paging) uses it, as
    /// a display does.
    @Test func readingAPrefetchedPageCountsAsUsed() throws {
        let store = try open()
        try prefetchedList(store)
        #expect(store.page(of: "forYou", after: "c1") != nil)
        store.waitForPendingWrites()
        #expect(store.statistics.speculative.used == 1)
    }
}

private extension LocalStore {
    func list(maxPages: Int, _ key: String) -> LocalList? { list(key, maxPages: maxPages) }
}
