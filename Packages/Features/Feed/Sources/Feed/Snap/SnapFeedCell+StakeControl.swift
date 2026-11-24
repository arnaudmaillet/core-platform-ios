import DesignSystem
import PostGrid
import UIKit

/// The page's like pill as a stake control (#2532): the screen's stakes push
/// the total and the menu's state, and play the receipts on it. The pill
/// builds its own menu from that state when it is pressed.
extension SnapFeedCell: StakeControl {
    func showStake(total: Int, state: StakeMenu.State, animated: Bool) {
        setBoostTotal(total, animated: animated)
        setBoostContext(balance: state.balance, undoable: state.undoable, stakeShots: state.shotsLeft)
    }

    func playStakeSpend(_ amount: Int) { playBoostConfirmation(amount: amount) }
    func playStakeRefund(_ amount: Int) { playBoostRefund(amount: amount) }
    func playStakeRefusal() { playBoostDenied() }
}
