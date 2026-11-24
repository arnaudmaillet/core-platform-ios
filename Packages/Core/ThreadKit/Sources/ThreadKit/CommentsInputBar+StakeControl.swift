import DesignSystem
import PostGrid
import UIKit

/// The boost bubble as a stake control (#2532): the session pushes the total
/// and the menu's state, and plays the receipts. The bar builds its own menu
/// from that state when it is pressed (`currentBoostMenuActions`).
extension CommentsInputBar: StakeControl {
    public func showStake(total: Int, state: StakeMenu.State, animated: Bool) {
        setBoostTotal(total, animated: animated)
        setBoostContext(balance: state.balance, undoableAmount: state.undoable, stakeShots: state.shotsLeft)
    }

    public func playStakeSpend(_ amount: Int) { playBoostConfirmation(amount: amount) }
    public func playStakeRefund(_ amount: Int) { playBoostRefund(amount: amount) }
    public func playStakeRefusal() { playBoostDenied() }
}
