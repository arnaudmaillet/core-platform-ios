import CoreStorage
import DesignSystem
import UIKit

/// Tells the viewer when staked likes came back (#1775): the server refused a
/// stake, clamped it or let its batch expire, and the likes it did not spend
/// returned to the balance (`WalletStore.settleCommittedStake`).
///
/// The commit is optimistic — the like count moved at the tap, the undo toast
/// went away — so without this a final failure was silent: a stake a little
/// smaller than the one made, and a balance a little larger, with nothing to
/// say why. The toast rides whatever screen is in front: the stake may settle
/// long after the post was left.
///
/// ⚠️ SELECTOR-BASED (`WalletBadgeInstaller`'s rule): the registration goes
/// with the notifier.
@MainActor
final class StakeRefundNotifier {
    private let window: UIWindow

    init(wallet: WalletStore, window: UIWindow) {
        self.window = window
        NotificationCenter.default.addObserver(
            self, selector: #selector(stakeRefunded(_:)),
            name: WalletStore.stakeRefundedNotification, object: wallet
        )
    }

    /// The toast's words for `amount` likes back.
    static func message(amount: Int) -> String {
        amount == 1
            ? "1 like couldn't be staked and is back in your balance"
            : "\(amount) likes couldn't be staked and are back in your balance"
    }

    @objc private nonisolated func stakeRefunded(_ note: Notification) {
        let amount = note.userInfo?[WalletStore.stakeRefundAmountKey] as? Int ?? 0
        guard amount > 0 else { return }
        Task { @MainActor [weak self] in self?.tell(amount) }
    }

    private func tell(_ amount: Int) {
        guard var front = window.rootViewController else { return }
        while let presented = front.presentedViewController, !presented.isBeingDismissed { front = presented }
        Feedback.warning(Self.message(amount: amount), from: front, id: "stake.refund")
    }
}
