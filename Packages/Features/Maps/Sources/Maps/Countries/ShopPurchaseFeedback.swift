import CoreStorage
import DesignSystem
import UIKit

/// What the Shop says after a purchase (#1475): one toast per outcome, the
/// same words on every shelf.
@MainActor
enum ShopPurchaseFeedback {
    /// The server could not be asked: nothing was charged.
    static let unreachable = "Couldn't reach the Shop. Nothing was charged — try again."

    /// A purchase under way (#1775): "Buying Gold…" past the loader's grace,
    /// the outcome's toast in its place.
    static func pending(_ title: String, from presenter: UIViewController) -> PendingFeedback {
        PendingFeedback("Buying \(title)…", from: presenter)
    }

    /// The toast for buying `title`, in `pending`'s place; `action` rides a
    /// success ("Apply").
    static func show(
        _ outcome: ProfileItemPurchase, title: String, pending: PendingFeedback,
        action: ToastView.Action? = nil
    ) {
        switch outcome {
        case .bought:
            HapticNotification().notificationOccurred(.success)
            pending.succeed("\(title) unlocked", action: action)
        case .alreadyOwned:
            pending.end()
        case .insufficientGems(let needed, let have):
            let missing = max(needed - have, 1)
            pending.fail(missing == 1 ? "1 more gem needed" : "\(missing) more gems needed")
        case .unavailable:
            pending.fail(PurchaseRestriction.message)
        case .priceChanged(let price):
            pending.fail(
                price.map { "The price changed: now \($0) gems. Nothing was charged." }
                    ?? "The price changed. Nothing was charged."
            )
        case .failed:
            pending.fail(unreachable)
        }
    }
}
