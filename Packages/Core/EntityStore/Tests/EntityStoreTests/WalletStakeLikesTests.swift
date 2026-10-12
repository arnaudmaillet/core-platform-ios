import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import EntityStore

/// Every point the viewer stakes, wherever, moves the post's count once — and
/// every undo or refund moves it back (#896).
@MainActor
struct WalletStakeLikesTests {
    private nonisolated static func defaults() -> UserDefaults {
        let name = "wallet-stake-likes-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private struct Fixture {
        let scope = StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
        let entities = EntityStore()
        let wallet: WalletStore
        let bridge: WalletStakeLikes

        init() {
            wallet = WalletStore(defaults: WalletStakeLikesTests.defaults(), scope: scope)
            bridge = WalletStakeLikes(wallet: wallet, entities: entities, scope: scope)
            entities.setLikeCount(40, for: PostID("p1"))
        }
    }

    @Test func aStakeMovesThePostsCountAndAnUndoMovesItBack() {
        let fixture = Fixture()
        var heard: [Int64?] = []
        let observation = fixture.entities.observePost(PostID("p1")) { id in
            heard.append(fixture.entities.post(id)?.likeCount)
        }

        _ = fixture.wallet.stake(.points(2), on: "p1")
        _ = fixture.wallet.stake(.points(1), on: "p1")
        _ = fixture.wallet.undoBoost(targetID: "p1", amount: 3)

        #expect(heard == [42, 43, 40])
        withExtendedLifetime((observation, fixture.bridge)) {}
    }

    /// The server clamped a committed batch: what it did not spend leaves the
    /// count with the balance.
    @Test func aRefundAfterACommitMovesTheCountBack() {
        let fixture = Fixture()
        _ = fixture.wallet.stake(.points(5), on: "p1")
        fixture.wallet.settleCommittedStake(targetID: "p1", asked: 5, spent: 2)
        #expect(fixture.entities.post(PostID("p1"))?.likeCount == 42)
        withExtendedLifetime(fixture.bridge) {}
    }

    /// Another account's stakes are not points placed now: a change of owner
    /// is a new baseline.
    @Test func aViewerChangeIsNotAStake() {
        let fixture = Fixture()
        fixture.scope.owner = .member(account: "acc-2", profile: nil)
        _ = fixture.wallet.stake(.points(4), on: "p1")
        fixture.scope.owner = .member(account: "acc-1", profile: "prof-1")
        #expect(fixture.entities.post(PostID("p1"))?.likeCount == 44, "only acc-2's own stake moved the count")
        withExtendedLifetime(fixture.bridge) {}
    }

    /// A balance change that stakes nothing (a claim) moves no count.
    @Test func aClaimMovesNoCount() {
        let fixture = Fixture()
        var calls = 0
        let observation = fixture.entities.observePost(PostID("p1")) { _ in calls += 1 }
        fixture.wallet.credit(10)
        #expect(calls == 0)
        withExtendedLifetime((observation, fixture.bridge)) {}
    }
}
