import Foundation
import Testing
@testable import CoreStorage

private func makeDefaults() -> UserDefaults {
    let name = "like-outbox-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

private let member = StorageScope(owner: .member(account: "acct-1", profile: "prof-1"))

/// The like outbox (#676): taps batch per post, a batch falls due 10 s after
/// its last tap or when sealed, keeps one key across retries, and remembers
/// who tapped.
struct LikeOutboxTests {
    private func makeOutbox(defaults: UserDefaults = makeDefaults(), clock: Clock = Clock()) -> LikeOutbox {
        LikeOutbox(defaults: defaults, scope: member, now: { clock.now })
    }

    @Test func tapsOnAPostGatherInOneBatch() throws {
        let outbox = makeOutbox()
        outbox.record(points: 1, on: .post("p1"))
        outbox.record(points: 1, on: .post("p1"))
        outbox.record(points: 1, on: .post("p2"))
        let batches = outbox.batches
        #expect(batches.count == 2)
        let first = try #require(batches.first)
        #expect(first.target == .post("p1"))
        #expect(first.points == 2)
        #expect(first.accountID == "acct-1")
        #expect(first.profileID == "prof-1")
        #expect((8...64).contains(first.idempotencyKey.count))
        #expect(first.idempotencyKey.allSatisfy { $0.isLetter || $0.isNumber })
    }

    /// Due 10 s after the LAST tap — a tap restarts the wait.
    @Test func aBatchFallsDueTenSecondsAfterItsLastTap() {
        let clock = Clock()
        let outbox = makeOutbox(clock: clock)
        outbox.record(points: 1, on: .post("p1"))
        clock.advance(by: 6)
        outbox.record(points: 1, on: .post("p1"))
        clock.advance(by: 6)
        #expect(outbox.takeDue().isEmpty, "due before the 10 s since the last tap")
        clock.advance(by: 4)
        let due = outbox.takeDue()
        #expect(due.map(\.points) == [2])
        #expect(due.first?.isSealed == true)
    }

    /// Moving on from the post commits it now; a tap after that opens a new
    /// batch, with its own key.
    @Test func sealingCommitsNowAndTheNextTapOpensANewBatch() {
        let outbox = makeOutbox()
        outbox.record(points: 3, on: .post("p1"))
        outbox.seal(target: .post("p1"))
        let due = outbox.takeDue()
        #expect(due.map(\.points) == [3])
        outbox.record(points: 1, on: .post("p1"))
        #expect(outbox.batches.count == 2)
        #expect(outbox.batches[0].idempotencyKey != outbox.batches[1].idempotencyKey)
        #expect(outbox.pendingPoints(on: .post("p1")) == 1)
    }

    /// A batch keeps its key until it is answered, and leaves when it is.
    @Test func aBatchKeepsItsKeyUntilAnswered() {
        let outbox = makeOutbox()
        outbox.record(points: 1, on: .post("p1"))
        outbox.sealAll()
        let key = outbox.takeDue().first?.idempotencyKey
        // Unanswered (a lost connection): still due, same key.
        #expect(outbox.takeDue().first?.idempotencyKey == key)
        outbox.complete(key ?? "")
        #expect(outbox.batches.isEmpty)
    }

    /// Only taps not yet committed can be taken back.
    @Test func onlyUncommittedTapsCanBeTakenBack() {
        let outbox = makeOutbox()
        outbox.record(points: 3, on: .post("p1"))
        #expect(outbox.cancel(points: 2, on: .post("p1")) == 2)
        #expect(outbox.pendingPoints(on: .post("p1")) == 1)
        outbox.seal(target: .post("p1"))
        #expect(outbox.cancel(points: 1, on: .post("p1")) == 0, "a committed like is final")
    }

    /// A shot is a batch of its own, due at once.
    @Test func aShotIsItsOwnBatchDueAtOnce() {
        let outbox = makeOutbox()
        outbox.record(points: 1, on: .post("p1"))
        outbox.recordShot(on: .post("p1"), points: 100)
        let due = outbox.takeDue()
        #expect(due.count == 1)
        #expect(due.first?.usesStakeShot == true)
        #expect(outbox.pendingPoints(on: .post("p1")) == 1)
    }

    /// The queue survives a relaunch.
    @Test func theQueueSurvivesARelaunch() {
        let defaults = makeDefaults()
        makeOutbox(defaults: defaults).record(points: 2, on: .comment("c1"))
        let reopened = makeOutbox(defaults: defaults)
        #expect(reopened.batches.map(\.target) == [.comment("c1")])
        #expect(reopened.batches.first?.points == 2)
    }
}

/// The wallet and the outbox (#676): a member's stakes go to the outbox, an
/// undo takes back only what is not committed, and the server's answer
/// settles what it did not spend.
struct WalletLikeOutboxTests {
    private func make() -> (WalletStore, LikeOutbox) {
        let defaults = makeDefaults()
        let wallet = WalletStore(defaults: defaults, scope: member)
        let outbox = LikeOutbox(defaults: defaults, scope: member)
        wallet.likeOutbox = outbox
        return (wallet, outbox)
    }

    @Test func aStakeIsRecordedForCommit() {
        let (wallet, outbox) = make()
        wallet.stake(.points(1), on: "p1")
        wallet.stake(.points(1), on: "p1")
        #expect(outbox.pendingPoints(on: .post("p1")) == 2)
    }

    @Test func anUndoTakesBackOnlyUncommittedTaps() {
        let (wallet, outbox) = make()
        let start = wallet.balance
        wallet.stake(.points(3), on: "p1")
        #expect(wallet.undoBoost(targetID: "p1", amount: 1) != nil)
        #expect(wallet.balance == start - 2)
        wallet.commitStakes(on: "p1")
        #expect(wallet.undoBoost(targetID: "p1", amount: 2) == nil, "a committed like came back")
        #expect(wallet.balance == start - 2)
        #expect(outbox.batches.first?.points == 2)
    }

    /// What the server did not spend goes back to the balance and off the
    /// post's stake.
    @Test func whatTheServerDidNotSpendComesBack() {
        let (wallet, _) = make()
        let start = wallet.balance
        wallet.stake(.points(5), on: "p1")
        wallet.settleCommittedStake(targetID: "p1", asked: 5, spent: 3)
        #expect(wallet.balance == start - 3)
        #expect(wallet.boostTotal(forTarget: "p1") == 3)
        // A refusal (expired, own content): all of it.
        wallet.stake(.points(2), on: "p2")
        wallet.settleCommittedStake(targetID: "p2", asked: 2, spent: 0)
        #expect(wallet.boostTotal(forTarget: "p2") == 0)
        #expect(wallet.balance == start - 3)
    }

    /// A guest's likes are the welcome gift's: nothing goes to the outbox.
    @Test func aGuestRecordsNothing() {
        let defaults = makeDefaults()
        let guest = StorageScope(owner: .guest)
        let wallet = WalletStore(defaults: defaults, scope: guest)
        let outbox = LikeOutbox(defaults: defaults, scope: guest)
        wallet.likeOutbox = outbox
        wallet.stake(.points(1), on: "p1")
        #expect(outbox.batches.isEmpty)
    }
}
