import CacheKit
import Foundation
import Testing
@testable import LocalStore

/// The store within its budget: tails before first pages, LRU, the
/// speculative cap, trims, and the file on disk (#893).
final class LocalStoreBudgetTests {
    private let folder = TemporaryFolder()
    private let viewer = ViewerBox(alice)
    private let clock = ManualCacheClock()

    private func open(limit: Int = .max, speculative: Int? = nil) throws -> LocalStore {
        try LocalStore.test(
            in: folder, viewer: viewer, clock: clock,
            limits: CacheLimits(bytes: limit, speculativeBytes: speculative ?? limit)
        )
    }

    /// Ten posts of `bytes` each, as one page.
    private func bigPage(_ prefix: String, cursor: String?, tier: CacheTier, bytes: Int = 10_000) -> LocalListPage {
        page((0..<10).map { "\(prefix)-\($0)" }, cursor: cursor, tier: tier, bytes: bytes)
    }

    @Test func theCoordinatorBudgetsItAndWipesItOnAViewerChange() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1"], cursor: nil), as: alice)
        let coordinator = CacheCoordinator(device: CacheDevice(
            physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) }
        ))
        coordinator.register(store)
        store.waitForPendingWrites()
        // The `.localStore` pool: 100 MB in Automatic, a ninth of a user limit.
        #expect(store.limits.bytes == DiskPool.localStore.automaticBytes)
        coordinator.setStorageLimit(.halfGigabyte)
        #expect(store.limits.bytes == CacheBytes.gigabyte / 2 / 9)
        #expect(coordinator.usage().usage(of: "localStore", medium: .disk)?.bytes == store.usage.bytes)

        coordinator.trim(.viewerChanged)
        #expect(store.list("forYou") == nil, "nothing readable from the moment the signal lands")
        store.waitForPendingWrites()
        #expect(try store.rowCount("entity") == 0)
    }

    @Test func usageCountsPayloadsAndRows() throws {
        let store = try open()
        try store.replaceList("forYou", with: page(["p1"], cursor: nil, bytes: 1_000), as: alice)
        let usage = store.usage
        #expect(usage.bytes > 1_000)
        #expect(usage.bytes < 1_400)
        #expect(usage.count == 1)
        #expect(usage.bytesByTier[.retained] == usage.bytes, "a first page holds its posts as retained")
    }

    @Test func aSmallerBudgetTakesListTailsBeforeFirstPages() throws {
        let store = try open()
        try store.replaceList("forYou", with: bigPage("fy0", cursor: "fy-c1", tier: .retained), as: alice)
        try store.appendPage(bigPage("fy1", cursor: "fy-c2", tier: .recent), to: "forYou", after: "fy-c1", as: alice)
        clock.advance(by: 10)
        try store.replaceList("following", with: bigPage("fo0", cursor: "fo-c1", tier: .retained), as: alice)
        try store.appendPage(bigPage("fo1", cursor: "fo-c2", tier: .recent), to: "following", after: "fo-c1", as: alice)
        #expect(store.usage.bytes > 400_000)

        // Room for about three pages: the least recently used tail goes.
        store.setLimits(CacheLimits(bytes: 330_000, speculativeBytes: 330_000))
        store.waitForPendingWrites()
        #expect(store.usage.bytes <= 330_000)
        let forYou = try #require(store.list("forYou"))
        #expect(ids(forYou).count == 10, "For You lost its tail")
        #expect(forYou.nextCursor == "fy-c1", "and pages again from where its first page stops")
        #expect(ids(store.list("following")).count == 20)

        // Room for two: both tails, never a first page while a tail is left.
        store.setLimits(CacheLimits(bytes: 230_000, speculativeBytes: 230_000))
        store.waitForPendingWrites()
        #expect(ids(store.list("forYou")).count == 10)
        #expect(ids(store.list("following")).count == 10)
        #expect(store.list("following")?.nextCursor == "fo-c1")
    }

    @Test func retainedFirstPagesGoLastAndLeastRecentlyUsedFirst() throws {
        let store = try open()
        try store.replaceList("a", with: bigPage("a", cursor: nil, tier: .retained), as: alice)
        clock.advance(by: 10)
        try store.replaceList("b", with: bigPage("b", cursor: nil, tier: .recent), as: alice)
        clock.advance(by: 10)
        try store.replaceList("c", with: bigPage("c", cursor: nil, tier: .retained), as: alice)
        clock.advance(by: 10)
        // Reading `a` makes it the most recently used retained list.
        _ = store.list("a")
        store.waitForPendingWrites()

        store.setLimits(CacheLimits(bytes: 230_000, speculativeBytes: 230_000))

        store.waitForPendingWrites()
        #expect(try store.listKeys() == ["a", "c"], "the recent list goes before any retained one")

        store.setLimits(CacheLimits(bytes: 120_000, speculativeBytes: 120_000))

        store.waitForPendingWrites()
        #expect(try store.listKeys() == ["a"], "then the least recently used retained list")
    }

    @Test func writesStayWithinTheBudget() throws {
        let store = try open(limit: 250_000)
        try store.replaceList("forYou", with: bigPage("f0", cursor: "f1", tier: .retained), as: alice)
        #expect(try store.appendPage(bigPage("f1", cursor: "f2", tier: .recent), to: "forYou", after: "f1", as: alice))
        clock.advance(by: 10)
        // A new first page: For You's tail makes room for it.
        #expect(try store.replaceList("following", with: bigPage("g0", cursor: "g1", tier: .retained), as: alice))
        #expect(store.usage.bytes <= 250_000)
        #expect(ids(store.list("forYou")).count == 10)
        // A deep page of Following does not displace For You's first page: it
        // does not fit, and Following's cursor stays where its pages stop.
        #expect(try !store.appendPage(bigPage("g1", cursor: "g2", tier: .recent), to: "following", after: "g1", as: alice))
        #expect(store.usage.bytes <= 250_000)
        #expect(ids(store.list("forYou")).count == 10)
        #expect(store.list("following")?.nextCursor == "g1")
        #expect(try store.listKeys() == ["forYou", "following"])
        #expect(store.statistics.evictions > 0)
    }

    @Test func prefetchedPagesStayUnderTheirCapUntilRead() throws {
        let store = try open(limit: 1_000_000, speculative: 150_000)
        try store.replaceList("forYou", with: bigPage("p0", cursor: "c1", tier: .retained), as: alice)
        // The lookahead fetched two pages the viewer has not reached.
        #expect(try store.appendPage(bigPage("p1", cursor: "c2", tier: .speculative), to: "forYou", after: "c1", as: alice))
        #expect(store.usage.bytesByTier[.speculative, default: 0] > 0)
        #expect(try !store.appendPage(bigPage("p2", cursor: "c3", tier: .speculative), to: "forYou", after: "c2", as: alice),
                "the second prefetched page does not fit beside the first")
        #expect(store.usage.bytesByTier[.speculative, default: 0] <= 150_000)
        #expect(ids(store.list("forYou")).count == 20)

        // Read: the prefetched page is `recent` now, out of the cap.
        store.waitForPendingWrites()
        #expect(store.usage.bytesByTier[.speculative, default: 0] == 0)
    }

    @Test func trimsCutByDepth() throws {
        let store = try open()
        try store.replaceList("forYou", with: bigPage("r", cursor: "c1", tier: .retained), as: alice)
        try store.appendPage(bigPage("s", cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice)
        try store.replaceList("visited", with: bigPage("v", cursor: nil, tier: .recent), as: alice)
        try store.write([profile("loose", tier: .recent)], as: alice)

        store.trim(.speculative)

        store.waitForPendingWrites()
        #expect(ids(store.list("forYou")).count == 20, "nothing speculative to cut")

        store.trim(.belowRetained)

        store.waitForPendingWrites()
        #expect(ids(store.list("forYou")).count == 10, "the retained first page stays")
        #expect(store.list("visited") == nil)
        #expect(store.entity(profileKey("loose")) == nil)

        store.trim(.allButPinned)

        store.waitForPendingWrites()
        #expect(store.list("forYou") == nil)
        #expect(store.usage.bytes == 0)
    }

    @Test func theFileShrinksBackAfterATrim() throws {
        let store = try open()
        for index in 0..<10 {
            try store.replaceList("list-\(index)", with: bigPage("l\(index)", cursor: nil, tier: .recent, bytes: 20_000), as: alice)
        }
        store.flush()
        store.waitForPendingWrites()
        #expect(store.fileBytes > 1_500_000)

        store.setLimits(CacheLimits(bytes: 500_000, speculativeBytes: 500_000))

        store.waitForPendingWrites()
        store.flush()
        store.waitForPendingWrites()
        #expect(store.usage.bytes <= 500_000)
        // Freed pages go back to the file system (incremental vacuum): the
        // file follows the budget, it does not keep its high-water mark.
        #expect(store.fileBytes < 900_000, "file \(store.fileBytes) bytes")
    }
}
