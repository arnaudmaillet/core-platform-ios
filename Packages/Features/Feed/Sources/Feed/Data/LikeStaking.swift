import AuthInterface
import CoreContracts
import CoreStorage
import Foundation
import SwiftProtobuf
import UIKit

/// How a batch of likes reaches the server (#676): `wallet.v1.WalletService/
/// Stake`. A like is a point; there is no unlike.
public protocol LikeStaking: Sendable {
    /// Commits one batch. Throws on a transport failure — the batch is then
    /// retried with the same key; any answer, refusals included, is final.
    func stake(_ batch: LikeOutbox.Batch) async throws -> LikeStakeAnswer
}

/// The server's word on a batch.
public struct LikeStakeAnswer: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `spent` points went on the target — maybe fewer than asked,
        /// clamped to its room (250 per account), the balance or the hour's
        /// room (1,000).
        case staked
        case insufficientBalance
        case targetNotStakeable
        case rateLimited
        case targetCapReached
        case noStakeShots
        case shotDoesNotFit
        /// The first tap was over 24 h ago: nothing spent.
        case expired
        /// One's own post or comment.
        case ownContent
        /// From a newer server.
        case unknown
    }

    public let outcome: Outcome
    public let spent: Int
    /// The account's points on the target after this batch: what fills the
    /// heart.
    public let myTotal: Int

    public init(outcome: Outcome, spent: Int, myTotal: Int) {
        self.outcome = outcome
        self.spent = spent
        self.myTotal = myTotal
    }
}

/// A stake the server will never take, however often it is sent (#796): the
/// request itself is wrong (no account any more, a target that is gone, an
/// argument refused). Its batch leaves the outbox and its likes go back,
/// rather than holding every batch behind it.
public struct LikeStakeRejected: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// `LikeStaking` over the edge, as the signed-in account.
public actor WalletLikeStaking: LikeStaking {
    private let walletClient: any Wallet_V1_WalletServiceClientInterface
    private let viewer: any ViewerProviding

    public init(walletClient: any Wallet_V1_WalletServiceClientInterface, viewer: any ViewerProviding) {
        self.walletClient = walletClient
        self.viewer = viewer
    }

    public func stake(_ batch: LikeOutbox.Batch) async throws -> LikeStakeAnswer {
        guard case .member(let account, _) = await viewer.current() else {
            // No member to stake as: the batch can never go (#796).
            throw LikeStakeRejected(reason: "not a member")
        }
        var request = Wallet_V1_StakeRequest()
        request.accountID = batch.accountID ?? account.rawValue
        if let profile = batch.profileID {
            request.profileID = profile
        } else {
            request.profileID = try await viewer.activeProfileID().rawValue
        }
        switch batch.target {
        case .post(let id): request.postID = id
        case .comment(let id): request.commentID = id
        }
        if batch.usesStakeShot {
            request.useStakeShot = true
        } else {
            request.points = Int32(clamping: batch.points)
        }
        request.idempotencyKey = batch.idempotencyKey
        request.firstTapAt = Google_Protobuf_Timestamp(date: batch.firstTapAt)
        let response = await walletClient.stake(request: request, headers: [:])
        if let error = response.error {
            // ⚠️ A REFUSAL IS NOT A LOST CONNECTION (#796): these codes answer
            // the same however often the batch is resent.
            switch error.code {
            case .invalidArgument, .notFound, .alreadyExists, .permissionDenied,
                 .failedPrecondition, .outOfRange, .unimplemented:
                throw LikeStakeRejected(reason: error.message ?? "code \(error.code)")
            default:
                throw FeedError.transport(message: error.message ?? "code \(error.code)")
            }
        }
        guard let message = response.message else {
            throw FeedError.transport(message: "empty stake response")
        }
        return LikeStakeAnswer(
            outcome: Self.outcome(message.outcome),
            spent: Int(message.spent),
            myTotal: Int(message.myTotal)
        )
    }

    static func outcome(_ outcome: Wallet_V1_StakeOutcome) -> LikeStakeAnswer.Outcome {
        switch outcome {
        case .staked: .staked
        case .insufficientBalance: .insufficientBalance
        case .targetNotStakeable: .targetNotStakeable
        case .rateLimited: .rateLimited
        case .targetCapReached: .targetCapReached
        case .noStakeShots: .noStakeShots
        case .shotDoesNotFit: .shotDoesNotFit
        case .expired: .expired
        case .ownContent: .ownContent
        default: .unknown
        }
    }
}

/// Commits the like outbox (#676): each batch once it falls due — 10 s
/// after its last tap, when the viewer moves on from the post, when the app
/// goes to the background — retried with its key after a lost connection,
/// and settled against the local wallet when answered: what the server did
/// not spend goes back to the balance.
@MainActor
public final class LikeOutboxSender {
    private let outbox: LikeOutbox
    private let wallet: WalletStore
    private let staking: any LikeStaking
    /// Waits after a failed commit, the last repeated.
    private let retryDelays: [TimeInterval]
    private var failures = 0
    private var isSending = false
    private var timer: Timer?
    /// Removed with the sender (the token bag's deinit, not a main-actor one).
    private let observers = NotificationObserverTokenBag()

    public init(
        outbox: LikeOutbox, wallet: WalletStore, staking: any LikeStaking,
        retryDelays: [TimeInterval] = [2, 5, 15, 60]
    ) {
        self.outbox = outbox
        self.wallet = wallet
        self.staking = staking
        self.retryDelays = retryDelays
    }

    /// Starts committing: now for anything left from before, then whenever
    /// a batch falls due.
    public func start() {
        let center = NotificationCenter.default
        observers.tokens = [
            center.addObserver(forName: LikeOutbox.didChangeNotification, object: outbox, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        ]
        schedule()
    }

    /// The app is leaving: every open batch is committed, with a little time
    /// asked of the system to finish.
    private func enterBackground() {
        outbox.sealAll()
        let task = UIApplication.shared.beginBackgroundTask(withName: "likes.commit")
        Task { @MainActor in
            await flush()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Arms the timer for the next due batch, or commits now.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard !isSending else { return }
        let batches = outbox.batches
        guard !batches.isEmpty else { return }
        if batches.contains(where: \.isSealed) {
            Task { @MainActor in await flush() }
            return
        }
        guard let due = outbox.nextDueDate else { return }
        let wait = max(0.05, due.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.flush() }
            }
        }
    }

    /// Commits every due batch, in order; stops at the first failure that a
    /// retry may cure and tries again after a growing wait.
    ///
    /// ⚠️ A BATCH THE SERVER REFUSES FOR GOOD LEAVES (#796). Every failure used
    /// to stop the flush and retry forever, so one batch that could never go
    /// (signed out, a deleted post, a refused argument) held every like queued
    /// behind it. It is dropped with its likes given back, and the flush moves
    /// on.
    func flush() async {
        guard !isSending else { return }
        isSending = true
        var failed = false
        for batch in outbox.takeDue() {
            do {
                let answer = try await staking.stake(batch)
                outbox.complete(batch.idempotencyKey)
                settle(batch, with: answer)
                failures = 0
            } catch is LikeStakeRejected {
                outbox.complete(batch.idempotencyKey)
                settle(batch, with: LikeStakeAnswer(outcome: .unknown, spent: 0, myTotal: 0))
            } catch {
                failed = true
                failures += 1
                break
            }
        }
        isSending = false
        if failed {
            let delay = retryDelays[min(failures - 1, retryDelays.count - 1)]
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { @MainActor in await self.flush() }
                }
            }
        } else {
            schedule()
        }
    }

    /// What the server did not spend leaves the post's stake and returns to
    /// the balance: a clamp, a refusal, an expired batch.
    private func settle(_ batch: LikeOutbox.Batch, with answer: LikeStakeAnswer) {
        guard case .post(let postID) = batch.target else { return }
        let spent = answer.outcome == .staked ? answer.spent : 0
        wallet.settleCommittedStake(targetID: postID, asked: batch.points, spent: spent)
    }
}
