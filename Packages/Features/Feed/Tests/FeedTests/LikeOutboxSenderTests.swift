import CoreStorage
import Foundation
import Testing
@testable import Feed

/// Answers or fails as told, and records every batch it is handed.
private final class ScriptedStaking: LikeStaking, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<LikeStakeAnswer, Error>] = []
    private(set) var batches: [LikeOutbox.Batch] = []

    func then(_ result: Result<LikeStakeAnswer, Error>) { lock.withLock { script.append(result) } }
    var sent: [LikeOutbox.Batch] { lock.withLock { batches } }

    func stake(_ batch: LikeOutbox.Batch) async throws -> LikeStakeAnswer {
        let next: Result<LikeStakeAnswer, Error> = lock.withLock {
            batches.append(batch)
            return script.isEmpty ? .success(LikeStakeAnswer(outcome: .staked, spent: batch.points, myTotal: batch.points)) : script.removeFirst()
        }
        return try next.get()
    }
}

private struct Offline: Error {}

/// The sender commits the outbox (#676): each due batch once, retried with
/// its key after a failure, settled against the wallet when answered.
@MainActor
struct LikeOutboxSenderTests {
    private func make() -> (LikeOutboxSender, WalletStore, LikeOutbox, ScriptedStaking) {
        let name = "like-sender-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let scope = StorageScope(owner: .member(account: "acct-1", profile: "prof-1"))
        let wallet = WalletStore(defaults: defaults, scope: scope)
        let outbox = LikeOutbox(defaults: defaults, scope: scope)
        wallet.likeOutbox = outbox
        let staking = ScriptedStaking()
        let sender = LikeOutboxSender(outbox: outbox, wallet: wallet, staking: staking, retryDelays: [3600])
        return (sender, wallet, outbox, staking)
    }

    @Test func aSealedBatchIsCommittedOnceAndLeaves() async {
        let (sender, wallet, outbox, staking) = make()
        wallet.stake(.points(1), on: "p1")
        wallet.stake(.points(1), on: "p1")
        wallet.commitStakes(on: "p1")
        await sender.flush()
        #expect(staking.sent.map(\.points) == [2])
        #expect(staking.sent.first?.target == .post("p1"))
        #expect(outbox.batches.isEmpty)
        #expect(wallet.boostTotal(forTarget: "p1") == 2)
    }

    /// An open batch waits for its 10 s.
    @Test func anOpenBatchIsNotCommittedEarly() async {
        let (sender, wallet, outbox, staking) = make()
        wallet.stake(.points(1), on: "p1")
        await sender.flush()
        #expect(staking.sent.isEmpty)
        #expect(outbox.pendingPoints(on: .post("p1")) == 1)
    }

    /// A lost connection keeps the batch, and the retry carries the SAME
    /// key — the server credits it once.
    @Test func aFailedCommitIsRetriedWithTheSameKey() async {
        let (sender, wallet, outbox, staking) = make()
        staking.then(.failure(Offline()))
        wallet.stake(.points(1), on: "p1")
        wallet.commitStakes(on: "p1")
        await sender.flush()
        #expect(outbox.batches.count == 1, "a failed commit dropped the likes")
        await sender.flush()
        #expect(staking.sent.count == 2)
        #expect(staking.sent[0].idempotencyKey == staking.sent[1].idempotencyKey)
        #expect(outbox.batches.isEmpty)
    }

    /// What the server clamped off goes back to the balance.
    @Test func aClampedBatchGivesTheRestBack() async {
        let (sender, wallet, _, staking) = make()
        let start = wallet.balance
        staking.then(.success(LikeStakeAnswer(outcome: .staked, spent: 2, myTotal: 250)))
        wallet.stake(.points(5), on: "p1")
        wallet.commitStakes(on: "p1")
        await sender.flush()
        #expect(wallet.balance == start - 2)
        #expect(wallet.boostTotal(forTarget: "p1") == 2)
    }

    /// A refusal — expired, one's own post — gives it all back.
    @Test func aRefusedBatchGivesItAllBack() async {
        let (sender, wallet, outbox, staking) = make()
        let start = wallet.balance
        staking.then(.success(LikeStakeAnswer(outcome: .ownContent, spent: 0, myTotal: 0)))
        wallet.stake(.points(3), on: "p1")
        wallet.commitStakes(on: "p1")
        await sender.flush()
        #expect(wallet.balance == start)
        #expect(wallet.boostTotal(forTarget: "p1") == 0)
        #expect(outbox.batches.isEmpty, "a refusal is an answer: the batch leaves")
    }
}
