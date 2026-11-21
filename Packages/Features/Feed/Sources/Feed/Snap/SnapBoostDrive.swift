import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import LaunchArguments
import PostSurfaces
import UIKit

/// What the full-screen feed's boost asks of its screen (#2514): the session
/// tally (`SnapBoostController`), the posts no longer available, the visible
/// cells and the toolbar's like.
///
/// A view controller: the member gate and the stake toast are presented from
/// it.
@MainActor
protocol SnapBoostDriveHost: UIViewController {
    var boost: SnapBoostController { get }
    var unavailablePostIDs: Set<PostID> { get }
    var orderedIDs: [PostID] { get }
    var collectionView: UICollectionView! { get }
    /// The settled page's model.
    var activeModel: FeedItemDisplayModel? { get }
    var toolbarComposer: SnapToolbarComposer { get }
    func snapCell(for id: PostID) -> SnapFeedCell?
}

/// The full-screen feed's boost, on screen (#2514): a spend through the
/// member gate, its haptics and the cell's theatre, the stake toast that is
/// the burst's undo window (#957, #1375), the session undo, and what every
/// visible boost anchor is told.
///
/// The arithmetic and the session tally are `SnapBoostController`'s, unit-
/// tested without a screen; this is the screen's half of the flow, and hears
/// plain values back from it.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — a tap, a page resigning, the
/// screen leaving, a wallet change.
@MainActor
final class SnapBoostDrive {
    private unowned let host: any SnapBoostDriveHost
    /// The viewer's point balance; nil drops every spend silently.
    private let wallet: (any WalletStaking)?

    init(host: any SnapBoostDriveHost, wallet: (any WalletStaking)?) {
        self.host = host
        self.wallet = wallet
    }

    /// One boost spend, wallet-first (`SnapBoostController.stake`). The
    /// verdict's role here (`commit`, `error`), visuals on the cell that
    /// asked. A nil wallet (unwired host) drops the
    /// tap silently; the mock store is always wired in the app itself.
    func performBoost(on id: PostID, spend: WalletStakeSpend, feedbackCell: SnapFeedCell?) {
        MemberGates.perform(.like, from: host) { [weak self, weak feedbackCell] in
            self?.commitBoost(on: id, spend: spend, feedbackCell: feedbackCell)
        }
    }

    private func commitBoost(on id: PostID, spend: WalletStakeSpend, feedbackCell: SnapFeedCell?) {
        // Nothing to like on a post the viewer may no longer see (#1409) — a
        // tap that finished a member gate after it turned unavailable.
        guard !host.unavailablePostIDs.contains(id), let verdict = host.boost.stake(spend, on: id) else { return }
        switch verdict {
        case .boosted(let targetTotal, let spent):
            Haptics.play(.commit)
            // Receipt before theatre: the anchor flips to (or grows) its
            // number face, then the "+N" float rises off it.
            feedbackCell?.setBoostTotal(targetTotal, animated: true)
            feedbackCell?.playBoostConfirmation(amount: spent)
            refreshVisibleBoostControls()
            // The burst so far, with Undo for all of it (#957): one toast
            // per post, updated by every tap.
            // ⚠️ THE TOAST IS THE UNDO WINDOW (#1375): it follows the
            // screen on top through a push or a pop, its Undo live until it
            // ends — when it sends the burst. Paging away or leaving no
            // longer closes it.
            stakeToastPostID = id
            host.boost.toastHolds = id
            let burst = stakeBursts[id] ?? StakeMenu.Burst()
            stakeBursts[id] = burst
            let generation = burst.next()
            let amount = host.boost.undoable(on: id)
            let wallet = wallet
            stakeToast = StakeMenu.undoToast(
                staked: amount, on: id.rawValue, from: host,
                commit: { [weak self] in
                    guard burst.isCurrent(generation) else { return }
                    wallet?.commitStakes(on: id.rawValue)
                    guard let self else { return }
                    stakeBursts[id] = nil
                    if host.boost.toastHolds == id { host.boost.toastHolds = nil }
                    if stakeToastPostID == id {
                        stakeToast = nil
                        stakeToastPostID = nil
                    }
                },
                undo: { [weak self] in
                    // The session still names the post: the screen's own
                    // undo. Moved on (paged away, or the screen is gone): the
                    // burst straight from the wallet.
                    if let self, host.boost.undoable(on: id) > 0 {
                        performBoostUndo(on: id, feedbackCell: host.snapCell(for: id))
                    } else if let refund = wallet?.undoBoost(targetID: id.rawValue, amount: amount) {
                        self?.host.snapCell(for: id)?.setBoostTotal(refund.targetTotal, animated: true)
                        self?.refreshVisibleBoostControls()
                    }
                    if self?.host.boost.toastHolds == id { self?.host.boost.toastHolds = nil }
                }
            )
            #if DEBUG
            if LaunchArgument.walletLog.isPassed(), let wallet {
                print("[wallet] boosted post=\(id.rawValue) requested=\(spend) spent=\(spent) targetTotal=\(targetTotal) balance=\(wallet.balance) shots=\(wallet.stakeShots)")
            }
            #endif
        case .refused(let refusal):
            // The refusal is drawn on the rail: no toast to say it twice.
            Haptics.play(.error)
            feedbackCell?.playBoostDenied()
            #if DEBUG
            if LaunchArgument.walletLog.isPassed(), let wallet {
                switch refusal {
                case .insufficientBalance(let balance):
                    print("[wallet] boost DENIED post=\(id.rawValue) spend=\(spend) balance=\(balance) shots=\(wallet.stakeShots)")
                case .targetCapReached(let targetTotal):
                    print("[wallet] boost CAP post=\(id.rawValue) targetTotal=\(targetTotal)")
                case .noShotsLeft, .shotDoesNotFit:
                    print("[wallet] shot REFUSED post=\(id.rawValue) outcome=\(refusal) shots=\(wallet.stakeShots)")
                }
            }
            #endif
        }
    }

    /// Takes back the whole session spend on `id` — the menu's Undo entry
    /// (`SnapBoostController.undo`).
    func performBoostUndo(on id: PostID, feedbackCell: SnapFeedCell?) {
        guard let refund = takeBackSessionStake(on: id, feedbackCell: feedbackCell, withFeedback: true) else { return }
        #if DEBUG
        if LaunchArgument.walletLog.isPassed() {
            print("[wallet] boost UNDO post=\(id.rawValue) refunded=\(refund.refunded) targetTotal=\(refund.targetTotal) balance=\(refund.newBalance)")
        }
        #endif
    }

    /// The stake toast up (#957), and the post its burst is on.
    private weak var stakeToast: ToastView?
    private var stakeToastPostID: PostID?

    /// Takes back the session's spend on `id` and settles its toast — the
    /// menu's Undo (`withFeedback`: the refund's float, and no haptic:
    /// turning off is silent, #1881) and a post that turned unavailable
    /// (#1409), quietly. Nil when there was nothing to take back.
    @discardableResult
    func takeBackSessionStake(
        on id: PostID, feedbackCell: SnapFeedCell?, withFeedback: Bool
    ) -> SnapBoostController.Refund? {
        guard let refund = host.boost.undo(on: id) else { return nil }
        // Taken back: the toast closing must not send it.
        _ = stakeBursts.removeValue(forKey: id)?.next()
        if host.boost.toastHolds == id { host.boost.toastHolds = nil }
        feedbackCell?.setBoostTotal(refund.targetTotal, animated: withFeedback)
        if withFeedback { feedbackCell?.playBoostRefund(amount: refund.refunded) }
        refreshVisibleBoostControls()
        closeStakeToastIfSettled()
        return refund
    }

    /// Closes the stake toast once its burst can no longer be taken back —
    /// undone from the menu, or finalized by paging away or leaving — so its
    /// Undo never outlives the session tally it would take back.
    func closeStakeToastIfSettled() {
        // A toast whose burst moved on (paged away, the screen leaving) stays:
        // it is the undo window now (#1375). Only a burst taken back closes it.
        guard let id = stakeToastPostID, host.boost.undoable(on: id) == 0, host.boost.toastHolds != id else { return }
        StakeMenu.closeUndoToast(stakeToast)
        stakeToast = nil
        stakeToastPostID = nil
    }

    /// Numbers each post's stake toasts (`StakeMenu.Burst`) — per post: a
    /// stake on the next post settles the previous post's toast (the one
    /// undo slot), which must still send ITS burst.
    private var stakeBursts: [PostID: StakeMenu.Burst] = [:]

    func refreshVisibleBoostControls() {
        host.toolbarComposer.refreshFooterLike(for: host.activeModel, animated: true)
        guard host.boost.wallet != nil else { return }
        for indexPath in host.collectionView.indexPathsForVisibleItems {
            guard host.orderedIDs.indices.contains(indexPath.item),
                  let cell = host.collectionView.cellForItem(at: indexPath) as? SnapFeedCell,
                  let context = host.boost.anchorContext(for: host.orderedIDs[indexPath.item]) else { continue }
            cell.setBoostContext(
                balance: context.balance, undoable: context.undoable, stakeShots: context.stakeShots
            )
        }
    }
}
