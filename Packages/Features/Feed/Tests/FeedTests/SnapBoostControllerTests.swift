import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import Feed

/// THE BOOST FLOW, WITHOUT THE SCREEN.
///
/// `SnapBoostController` turns the wallet's answer to a spend into a verdict,
/// keeps the session tally (the one post still undoable, and how much), and
/// finalizes it when the page resigns or the screen leaves — committing the
/// taps through the wallet's outbox (#676).
///
/// Every test owns a fresh `UserDefaults` suite: a seeded wallet of
/// `Policy.seededBalance` points, nothing shared.
@MainActor
struct SnapBoostControllerTests {
    private let first = PostID("post-1")
    private let second = PostID("post-2")

    private static func member() -> (SnapBoostController, WalletStore, LikeOutbox) {
        let name = "snap-boost-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let scope = StorageScope(owner: .member(account: "acct-1", profile: "prof-1"))
        let wallet = WalletStore(defaults: defaults, scope: scope)
        let outbox = LikeOutbox(defaults: defaults, scope: scope)
        wallet.likeOutbox = outbox
        return (SnapBoostController(wallet: wallet), wallet, outbox)
    }

    // MARK: - Spends

    @Test func anOptimisticStakeDebitsAtOnceAndOpensTheTally() {
        let (boost, wallet, _) = Self.member()
        let before = wallet.balance
        let verdict = boost.stake(.points(1), on: first)
        #expect(verdict == .boosted(targetTotal: 1, spent: 1))
        #expect(wallet.balance == before - 1, "the debit lands before any feedback")
        #expect(boost.sessionID == first)
        #expect(boost.undoable(on: first) == 1)
        #expect(boost.undoable(on: second) == 0)
    }

    @Test func stakesOnTheSamePostGrowTheTally() {
        let (boost, _, _) = Self.member()
        _ = boost.stake(.points(1), on: first)
        let verdict = boost.stake(.points(4), on: first)
        #expect(verdict == .boosted(targetTotal: 5, spent: 4))
        #expect(boost.undoable(on: first) == 5)
    }

    @Test func aStakeOnAnotherPostRestartsTheTallyOnIt() {
        let (boost, _, _) = Self.member()
        _ = boost.stake(.points(3), on: first)
        _ = boost.stake(.points(2), on: second)
        #expect(boost.sessionID == second)
        #expect(boost.undoable(on: second) == 2)
        #expect(boost.undoable(on: first) == 0)
    }

    @Test func aNearCapStakeIsClampedAndTheTallyHoldsWhatWasSpent() {
        let (boost, _, _) = Self.member()
        let cap = WalletStore.Policy.perTargetBoostCap
        _ = boost.stake(.points(cap - 5), on: first)
        let verdict = boost.stake(.points(10), on: first)
        #expect(verdict == .boosted(targetTotal: cap, spent: 5), "the clamp, not the request")
        #expect(boost.undoable(on: first) == cap)
    }

    @Test func theLimitReachedIsARefusalThatLeavesTheTally() {
        let (boost, wallet, _) = Self.member()
        let cap = WalletStore.Policy.perTargetBoostCap
        _ = boost.stake(.points(cap), on: first)
        let balance = wallet.balance
        let verdict = boost.stake(.points(1), on: first)
        #expect(verdict == .refused(.targetCapReached(targetTotal: cap)))
        #expect(wallet.balance == balance, "a refusal moves nothing")
        #expect(boost.undoable(on: first) == cap)
    }

    @Test func anEmptyBalanceIsRefusedWithItsReason() {
        let (boost, wallet, _) = Self.member()
        // The seeded balance fits on one post exactly: spend it there.
        _ = boost.stake(.points(wallet.balance), on: first)
        #expect(wallet.balance == 0)
        let verdict = boost.stake(.points(1), on: second)
        #expect(verdict == .refused(.insufficientBalance(balance: 0)))
        #expect(boost.sessionID == first, "a refused spend does not move the tally")
    }

    @Test func aShotWithNoPackIsRefused() {
        let (boost, _, _) = Self.member()
        #expect(boost.stake(.shot, on: first) == .refused(.noShotsLeft))
        #expect(boost.sessionID == nil)
    }

    @Test func withoutAWalletASpendIsDropped() {
        let boost = SnapBoostController(wallet: nil)
        #expect(boost.stake(.points(1), on: first) == nil)
        #expect(boost.undo(on: first) == nil)
        #expect(boost.anchorContext(for: first) == nil)
        #expect(boost.boostTotal(on: first) == nil)
        boost.finalize()
        #expect(boost.sessionID == nil)
    }

    // MARK: - Undo

    @Test func undoGivesTheWholeSessionSpendBack() {
        let (boost, wallet, _) = Self.member()
        let before = wallet.balance
        _ = boost.stake(.points(2), on: first)
        _ = boost.stake(.points(3), on: first)
        let refund = boost.undo(on: first)
        #expect(refund == Refund(refunded: 5, targetTotal: 0, newBalance: before))
        #expect(wallet.balance == before)
        #expect(boost.sessionID == nil)
        #expect(boost.undo(on: first) == nil, "nothing left to take back")
    }

    @Test func undoOnAPostTheTallyDoesNotNameDoesNothing() {
        let (boost, wallet, _) = Self.member()
        _ = boost.stake(.points(2), on: first)
        let balance = wallet.balance
        #expect(boost.undo(on: second) == nil)
        #expect(wallet.balance == balance)
        #expect(boost.undoable(on: first) == 2)
    }

    // MARK: - Page change

    @Test func thePageResigningFinalizesItsTallyAndCommitsItsTaps() {
        let (boost, wallet, outbox) = Self.member()
        _ = boost.stake(.points(2), on: first)
        #expect(outbox.batches.map(\.isSealed) == [false])
        boost.pageResigned(first)
        #expect(boost.sessionID == nil)
        #expect(boost.undoable(on: first) == 0)
        #expect(outbox.batches.map(\.isSealed) == [true], "committed now, not 10 s later")
        #expect(boost.undo(on: first) == nil, "the undo window was the post's time on screen")
        #expect(wallet.boostTotal(forTarget: first.rawValue) == 2, "the spend is final")
    }

    @Test func anotherPageResigningLeavesTheTally() {
        let (boost, _, outbox) = Self.member()
        _ = boost.stake(.points(2), on: first)
        boost.pageResigned(second)
        #expect(boost.undoable(on: first) == 2)
        #expect(outbox.batches.map(\.isSealed) == [false])
    }

    @Test func leavingTheScreenFinalizesTheTally() {
        let (boost, _, outbox) = Self.member()
        _ = boost.stake(.points(1), on: first)
        boost.finalize()
        #expect(boost.sessionID == nil)
        #expect(outbox.batches.map(\.isSealed) == [true])
    }

    // MARK: - Anchors

    @Test func theAnchorContextIsTheWalletsAnswerAndTheTally() {
        let (boost, wallet, _) = Self.member()
        _ = boost.stake(.points(3), on: first)
        #expect(boost.anchorContext(for: first) == AnchorContext(
            balance: wallet.stakeableBalance, undoable: 3, stakeShots: 0
        ))
        #expect(boost.anchorContext(for: second)?.undoable == 0)
        #expect(boost.boostTotal(on: first) == 3)
        #expect(boost.boostTotal(on: second) == 0)
    }

    private typealias Refund = SnapBoostController.Refund
    private typealias AnchorContext = SnapBoostController.AnchorContext
}
