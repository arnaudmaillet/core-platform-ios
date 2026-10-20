import CoreStorage
import DesignSystem
import UIKit

/// What the Shop says after a purchase (#1475): one toast per outcome, the
/// same words on every shelf.
@MainActor
enum ShopPurchaseFeedback {
    /// The server could not be asked: nothing was charged.
    static let unreachable = "Couldn't reach the Shop. Nothing was charged — try again."

    /// The toast for buying `title`; `action` rides a success ("Apply").
    static func show(
        _ outcome: ProfileItemPurchase, title: String, from presenter: UIViewController,
        action: ToastView.Action? = nil
    ) {
        switch outcome {
        case .bought:
            HapticNotification().notificationOccurred(.success)
            Feedback.success("\(title) unlocked", from: presenter, action: action)
        case .alreadyOwned:
            break
        case .insufficientGems(let needed, let have):
            let missing = max(needed - have, 1)
            Feedback.failure(missing == 1 ? "1 more gem needed" : "\(missing) more gems needed", from: presenter)
        case .unavailable:
            Feedback.failure(PurchaseRestriction.message, from: presenter)
        case .priceChanged(let price):
            Feedback.failure(
                price.map { "The price changed: now \($0) gems. Nothing was charged." }
                    ?? "The price changed. Nothing was charged.",
                from: presenter
            )
        case .failed:
            Feedback.failure(unreachable, from: presenter)
        }
    }
}
