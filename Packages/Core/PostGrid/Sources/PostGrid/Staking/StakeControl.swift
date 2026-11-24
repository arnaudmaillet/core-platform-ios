import DesignSystem
import UIKit

/// A control that wears one post's stake and spends on it (#2532): the feed
/// rail's like pill, the comments bar's boost bubble, a card's like chip.
///
/// A `StakeSession` drives it: it pushes the total and the menu's state on
/// every change, and plays the receipts (DesignSystem's `StakeReceipt`,
/// #2529) on the control that asked. The control decides how it looks; the
/// session decides what happened.
@MainActor
public protocol StakeControl: AnyObject {
    /// The viewer's total on the post, and what the stake menu would offer
    /// now (balance, undoable tally, shots). `animated` for the viewer's own
    /// stake or undo; a change made elsewhere is drawn at once.
    func showStake(total: Int, state: StakeMenu.State, animated: Bool)
    /// The stake landed: the "+N", in what the wallet spent.
    func playStakeSpend(_ amount: Int)
    /// An undo gave likes back: the "−N", in what came back.
    func playStakeRefund(_ amount: Int)
    /// The wallet refused the stake: the head-shake.
    func playStakeRefusal()
}

/// A readout that wears a post's stake without spending (#2532): For You's
/// compact cards, a tile's heart. It is told the total, and nothing else.
@MainActor
public protocol StakeTotalShowing: AnyObject {
    func showStakeTotal(_ total: Int)
}
