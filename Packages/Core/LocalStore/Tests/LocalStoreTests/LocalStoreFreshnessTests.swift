import CacheKit
import Foundation
import Testing
@testable import LocalStore

/// The freshness windows (#893): what a reader judges from `fetchedAt` to
/// skip the network, per type.
final class LocalStoreFreshnessTests {
    private let folder = TemporaryFolder()
    private let viewer = ViewerBox(alice)
    private let clock = ManualCacheClock()

    @Test func aCopyIsFreshInsideItsWindowOnly() {
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        let window: TimeInterval = 60
        #expect(LocalStorePolicy.isFresh(fetchedAt: fetched, window: window, now: fetched))
        #expect(LocalStorePolicy.isFresh(fetchedAt: fetched, window: window, now: fetched.addingTimeInterval(30)))
        #expect(!LocalStorePolicy.isFresh(fetchedAt: fetched, window: window, now: fetched.addingTimeInterval(60)))
        #expect(!LocalStorePolicy.isFresh(fetchedAt: fetched, window: window, now: fetched.addingTimeInterval(3_600)))
    }

    @Test func aCopyFromTheFutureIsNotFresh() {
        // The clock moved back: the copy's age is unknown, so it revalidates.
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        #expect(!LocalStorePolicy.isFresh(fetchedAt: fetched, window: 60, now: fetched.addingTimeInterval(-5)))
    }

    @Test func aScreensWindowIsTheShortestOfWhatItDraws() {
        // A profile screen's header carries counters: never fresher than them.
        #expect(LocalStorePolicy.profileScreenRevalidation <= LocalStorePolicy.counterRevalidation)
        #expect(LocalStorePolicy.profileScreenRevalidation <= LocalStorePolicy.profileRevalidation)
        #expect(LocalStorePolicy.trendingRevalidation <= LocalStorePolicy.profileRevalidation)
        // A window never outlives the copy it applies to.
        #expect(LocalStorePolicy.trendingRevalidation < LocalStorePolicy.listLifetime)
        #expect(LocalStorePolicy.profileScreenRevalidation < LocalStorePolicy.profileLifetime)
    }

    @Test func readersJudgeFreshnessFromTheStoredFetchTime() throws {
        let store = try LocalStore.test(in: folder, viewer: viewer, clock: clock)
        try store.write([profile("p1")], as: alice)
        try store.replaceList("trending", with: page(["a"], cursor: nil), as: alice)
        let fetched = clock.now

        clock.advance(by: 30)
        let entity = try #require(store.entity(profileKey("p1")))
        let list = try #require(store.list("trending"))
        #expect(entity.fetchedAt == fetched)
        #expect(list.fetchedAt == fetched)
        #expect(LocalStorePolicy.isFresh(fetchedAt: entity.fetchedAt, window: LocalStorePolicy.profileScreenRevalidation, now: clock.now))

        clock.advance(by: 31)
        #expect(!LocalStorePolicy.isFresh(fetchedAt: entity.fetchedAt, window: LocalStorePolicy.profileScreenRevalidation, now: clock.now))
        #expect(LocalStorePolicy.isFresh(fetchedAt: list.fetchedAt, window: LocalStorePolicy.trendingRevalidation, now: clock.now))
    }
}
