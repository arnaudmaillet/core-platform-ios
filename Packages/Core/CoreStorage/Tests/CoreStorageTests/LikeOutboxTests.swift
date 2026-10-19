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

    /// ⚠️ UNSENT LIKES SURVIVE THE RENAME (#1397): a batch kept by a build
    /// that still called the currency "points" is read back whole, and is
    /// written back under the same key.
    @Test func aBatchKeptBeforeTheRenameIsReadBack() throws {
        let defaults = makeDefaults()
        let kept = """
        [{"target":{"post":{"_0":"p1"}},"points":3,"usesStakeShot":false,"idempotencyKey":"batch-key-0001",\
        "firstTapAt":800000000,"lastTapAt":800000005,"isSealed":false,"accountID":"acct-1","profileID":"prof-1"}]
        """
        defaults.set(Data(kept.utf8), forKey: "likes.outbox.v1")
        let outbox = makeOutbox(defaults: defaults)
        let batch = try #require(outbox.batches.first, "the kept batch was dropped")
        #expect(batch.target == .post("p1"))
        #expect(batch.likes == 3)
        #expect(batch.idempotencyKey == "batch-key-0001")
        let written = try #require(String(data: JSONEncoder().encode(batch), encoding: .utf8))
        #expect(written.contains("\"points\":3"), "the stored key changed: \(written)")
    }

    @Test func tapsOnAPostGatherInOneBatch() throws {
        let outbox = makeOutbox()
        outbox.record(likes: 1, on: .post("p1"))
        outbox.record(likes: 1, on: .post("p1"))
        outbox.record(likes: 1, on: .post("p2"))
        let batches = outbox.batches
        #expect(batches.count == 2)
        let first = try #require(batches.first)
        #expect(first.target == .post("p1"))
        #expect(first.likes == 2)
        #expect(first.accountID == "acct-1")
        #expect(first.profileID == "prof-1")
        #expect((8...64).contains(first.idempotencyKey.count))
        #expect(first.idempotencyKey.allSatisfy { $0.isLetter || $0.isNumber })
    }

    /// Due 10 s after the LAST tap — a tap restarts the wait.
    @Test func aBatchFallsDueTenSecondsAfterItsLastTap() {
        let clock = Clock()
        let outbox = makeOutbox(clock: clock)
        outbox.record(likes: 1, on: .post("p1"))
        clock.advance(by: 6)
        outbox.record(likes: 1, on: .post("p1"))
        clock.advance(by: 6)
        #expect(outbox.takeDue().isEmpty, "due before the 10 s since the last tap")
        clock.advance(by: 4)
        let due = outbox.takeDue()
        #expect(due.map(\.likes) == [2])
        #expect(due.first?.isSealed == true)
    }

    /// Moving on from the post commits it now; a tap after that opens a new
    /// batch, with its own key.
    @Test func sealingCommitsNowAndTheNextTapOpensANewBatch() {
        let outbox = makeOutbox()
        outbox.record(likes: 3, on: .post("p1"))
        outbox.seal(target: .post("p1"))
        let due = outbox.takeDue()
        #expect(due.map(\.likes) == [3])
        outbox.record(likes: 1, on: .post("p1"))
        #expect(outbox.batches.count == 2)
        #expect(outbox.batches[0].idempotencyKey != outbox.batches[1].idempotencyKey)
        #expect(outbox.pendingLikes(on: .post("p1")) == 1)
    }

    /// A batch keeps its key until it is answered, and leaves when it is.
    @Test func aBatchKeepsItsKeyUntilAnswered() {
        let outbox = makeOutbox()
        outbox.record(likes: 1, on: .post("p1"))
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
        outbox.record(likes: 3, on: .post("p1"))
        #expect(outbox.cancel(likes: 2, on: .post("p1")) == 2)
        #expect(outbox.pendingLikes(on: .post("p1")) == 1)
        outbox.seal(target: .post("p1"))
        #expect(outbox.cancel(likes: 1, on: .post("p1")) == 0, "a committed like is final")
    }

    /// A shot is a batch of its own, due at once.
    @Test func aShotIsItsOwnBatchDueAtOnce() {
        let outbox = makeOutbox()
        outbox.record(likes: 1, on: .post("p1"))
        outbox.recordShot(on: .post("p1"), likes: 100)
        let due = outbox.takeDue()
        #expect(due.count == 1)
        #expect(due.first?.usesStakeShot == true)
        #expect(outbox.pendingLikes(on: .post("p1")) == 1)
    }

    /// The queue survives a relaunch.
    @Test func theQueueSurvivesARelaunch() {
        let defaults = makeDefaults()
        makeOutbox(defaults: defaults).record(likes: 2, on: .comment("c1"))
        let reopened = makeOutbox(defaults: defaults)
        #expect(reopened.batches.map(\.target) == [.comment("c1")])
        #expect(reopened.batches.first?.likes == 2)
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
        wallet.stake(.likes(1), on: "p1")
        wallet.stake(.likes(1), on: "p1")
        #expect(outbox.pendingLikes(on: .post("p1")) == 2)
    }

    @Test func anUndoTakesBackOnlyUncommittedTaps() {
        let (wallet, outbox) = make()
        let start = wallet.balance
        wallet.stake(.likes(3), on: "p1")
        #expect(wallet.undoBoost(targetID: "p1", amount: 1) != nil)
        #expect(wallet.balance == start - 2)
        wallet.commitStakes(on: "p1")
        #expect(wallet.undoBoost(targetID: "p1", amount: 2) == nil, "a committed like came back")
        #expect(wallet.balance == start - 2)
        #expect(outbox.batches.first?.likes == 2)
    }

    /// What the server did not spend goes back to the balance and off the
    /// post's stake.
    @Test func whatTheServerDidNotSpendComesBack() {
        let (wallet, _) = make()
        let start = wallet.balance
        wallet.stake(.likes(5), on: "p1")
        wallet.settleCommittedStake(targetID: "p1", asked: 5, spent: 3)
        #expect(wallet.balance == start - 3)
        #expect(wallet.boostTotal(forTarget: "p1") == 3)
        // A refusal (expired, own content): all of it.
        wallet.stake(.likes(2), on: "p2")
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
        wallet.stake(.likes(1), on: "p1")
        #expect(outbox.batches.isEmpty)
    }
}
