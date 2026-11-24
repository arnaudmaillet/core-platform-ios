import DesignSystem
import UIKit

/// The stake session's view of a card (#2532): a readout wears the total in
/// its heart, and the list's card is a control besides — its like chip
/// stakes, and plays the session's receipts.
extension PostCardLikeReadout {
    public func showStakeTotal(_ total: Int) { setViewerStake(total) }
}

extension PostGridListRowCell: StakeControl {
    /// The chip draws the total in its heart; the menu it raises is built
    /// when it is pressed (`stakeMenu`), so the state is not kept.
    public func showStake(total: Int, state: StakeMenu.State, animated: Bool) {
        setViewerStake(total)
    }

    public func playStakeSpend(_ amount: Int) { playStakeConfirmation(amount: amount) }
    public func playStakeRefund(_ amount: Int) { playStakeRefund(amount: amount) }
    public func playStakeRefusal() { playStakeDenied() }
}
