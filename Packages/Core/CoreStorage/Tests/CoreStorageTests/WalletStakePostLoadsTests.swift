import Foundation
import Testing
@testable import CoreStorage

/// The wallet sheet's stake rows: each post looked up once, a missing answer
/// failing, and Try Again asking only for what failed (#834).
struct WalletStakePostLoadsTests {
    private static let epoch = Date(timeIntervalSince1970: 1_755_000_000)

    private static func stake(_ id: String, settled: Bool = false) -> WalletStake {
        WalletStake(
            targetID: id, amount: 10, stakedAt: epoch, settlesAt: epoch.addingTimeInterval(3600),
            outcome: settled ? .noReward : nil
        )
    }

    // MARK: - Loads

    @Test func aPostIsAskedForOnceWhateverTheRefreshes() {
        var loads = WalletStakePostLoads()
        #expect(loads.begin(["a", "b"]) == ["a", "b"])
        #expect(loads.state(of: "a") == .loading)
        // A refresh while the lookup is out asks for nothing new…
        #expect(loads.begin(["a", "b"]).isEmpty)
        loads.finish(requested: ["a", "b"], found: ["a", "b"])
        // …and neither does one after it answered.
        #expect(loads.begin(["a", "b", "c"]) == ["c"])
        #expect(loads.state(of: "a") == .loaded)
    }

    @Test func aDuplicateIdIsAskedForOnce() {
        var loads = WalletStakePostLoads()
        #expect(loads.begin(["a", "a"]) == ["a"])
    }

    @Test func whatTheLookupDidNotReturnFails() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a", "b"])
        loads.finish(requested: ["a", "b"], found: ["a"])
        #expect(loads.state(of: "a") == .loaded)
        #expect(loads.state(of: "b") == .failed)
        #expect(loads.hasFailures)
        #expect(!loads.failedAfterRetry, "a first failure is not a failed retry")
    }

    @Test func anEmptyAnswerFailsEverythingAskedFor() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a", "b"])
        loads.finish(requested: ["a", "b"], found: [])
        #expect(loads.state(of: "a") == .failed)
        #expect(loads.state(of: "b") == .failed)
    }

    @Test func aFailedPostIsNotAskedForAgainByARefresh() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a"])
        loads.finish(requested: ["a"], found: [])
        #expect(loads.begin(["a"]).isEmpty)
        #expect(loads.state(of: "a") == .failed)
    }

    @Test func tryAgainAsksOnlyForTheFailedPosts() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a", "b", "c"])
        loads.finish(requested: ["a", "b", "c"], found: ["b"])
        #expect(loads.retry() == ["a", "c"])
        #expect(loads.state(of: "a") == .loading)
        #expect(loads.state(of: "b") == .loaded)
        #expect(loads.isRetrying("a"))
        #expect(!loads.isRetrying("b"))
    }

    @Test func theFailedRowStaysWhileTheRetryIsOut() {
        var loads = WalletStakePostLoads()
        let stakes = [Self.stake("a"), Self.stake("b")]
        _ = loads.begin(["a", "b"])
        loads.finish(requested: ["a", "b"], found: ["b"])
        _ = loads.retry()
        #expect(loads.isRetrying)
        // Removed under the finger, every row below it slid up.
        #expect(WalletStakeList(stakes: stakes, loads: loads).active == [.postsFailed, .stake("a"), .stake("b")])
    }

    @Test func theFailedRowLeavesOnlyOnceTheRetrySucceeds() {
        var loads = WalletStakePostLoads()
        let stakes = [Self.stake("a")]
        _ = loads.begin(["a"])
        loads.finish(requested: ["a"], found: [])
        var again = loads.retry()
        loads.finish(requested: again, found: [])
        #expect(!loads.isRetrying)
        #expect(WalletStakeList(stakes: stakes, loads: loads).active == [.postsFailed, .stake("a")])
        again = loads.retry()
        loads.finish(requested: again, found: ["a"])
        #expect(WalletStakeList(stakes: stakes, loads: loads).active == [.stake("a")])
    }

    @Test func aRetryThatSucceedsClearsTheFailure() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a"])
        loads.finish(requested: ["a"], found: [])
        let again = loads.retry()
        loads.finish(requested: again, found: ["a"])
        #expect(loads.state(of: "a") == .loaded)
        #expect(!loads.hasFailures)
        #expect(!loads.failedAfterRetry)
    }

    @Test func aRetryThatFailsAgainSaysSo() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a"])
        loads.finish(requested: ["a"], found: [])
        let fresh = loads.begin(["b"])
        let firstAnswerFailedARetry = loads.finish(requested: fresh, found: [])
        #expect(!firstAnswerFailedARetry)
        let again = loads.retry()
        #expect(again == ["a", "b"])
        let retryFailed = loads.finish(requested: again, found: ["b"])
        #expect(retryFailed, "the moment the sheet warns")
        #expect(loads.state(of: "a") == .failed)
        #expect(loads.failedAfterRetry)
    }

    @Test func aFreshFailureAfterAFailedRetryIsAFirstFailureAgain() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a"])
        loads.finish(requested: ["a"], found: [])
        let again = loads.retry()
        loads.finish(requested: again, found: [])
        #expect(loads.failedAfterRetry)
        // A new stake whose post then fails was never retried.
        _ = loads.begin(["b"])
        loads.finish(requested: ["b"], found: [])
        #expect(!loads.failedAfterRetry)
    }

    // MARK: - List

    @Test func noStakeShowsTheEmptyCardAndNoSettledSection() {
        let list = WalletStakeList(stakes: [], loads: WalletStakePostLoads())
        #expect(list.active == [.noActiveStakes])
        #expect(list.settled == nil)
    }

    @Test func rowsStillLoadingAreStakeRows() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a"])
        let list = WalletStakeList(stakes: [Self.stake("a")], loads: loads)
        #expect(list.active == [.stake("a")])
    }

    @Test func settledStakesGetTheirOwnSection() {
        let list = WalletStakeList(
            stakes: [Self.stake("a"), Self.stake("b", settled: true)], loads: WalletStakePostLoads()
        )
        #expect(list.active == [.stake("a")])
        #expect(list.settled == [.stake("b")])
    }

    @Test func onlySettledFailuresPutTheFailedRowUnderSettledNeverBesideNoActiveStakes() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["b"])
        loads.finish(requested: ["b"], found: [])
        let list = WalletStakeList(stakes: [Self.stake("b", settled: true)], loads: loads)
        #expect(list.active == [.noActiveStakes])
        #expect(list.settled == [.postsFailed, .stake("b")])
    }

    @Test func settledFailuresBesideHealthyActiveStakesStayUnderSettled() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a", "b"])
        loads.finish(requested: ["a", "b"], found: ["a"])
        let list = WalletStakeList(stakes: [Self.stake("a"), Self.stake("b", settled: true)], loads: loads)
        #expect(list.active == [.stake("a")])
        #expect(list.settled == [.postsFailed, .stake("b")])
    }

    @Test func failuresInBothSectionsShowOneFailedRowUnderActive() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["a", "b"])
        loads.finish(requested: ["a", "b"], found: [])
        let list = WalletStakeList(stakes: [Self.stake("a"), Self.stake("b", settled: true)], loads: loads)
        #expect(list.active == [.postsFailed, .stake("a")])
        #expect(list.settled == [.stake("b")])
    }

    @Test func aSettledRetryKeepsItsFailedRowUnderSettled() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["b"])
        loads.finish(requested: ["b"], found: [])
        _ = loads.retry()
        let list = WalletStakeList(stakes: [Self.stake("b", settled: true)], loads: loads)
        #expect(list.active == [.noActiveStakes])
        #expect(list.settled == [.postsFailed, .stake("b")])
    }

    @Test func aFailureAboutAStakeNoLongerListedShowsNothing() {
        var loads = WalletStakePostLoads()
        _ = loads.begin(["gone"])
        loads.finish(requested: ["gone"], found: [])
        let list = WalletStakeList(stakes: [Self.stake("a")], loads: loads)
        #expect(list.active == [.stake("a")])
    }
}
