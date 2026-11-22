import DesignSystem
import UIKit

/// What the boost receipts ask of the chrome (#2521): the like pill they play
/// on, and the view they float their numbers in — itself.
@MainActor
protocol SnapBoostReceiptsHost: UIView {
    var boostButton: SnapRailBoostButton { get }
}

/// The like pill's receipts for a spend, out of `SnapChromeView` (#2521): the
/// gold "+N" that rises, the "−N" that sinks and the refusal's shake. The
/// screen's wallet verdict picks which one plays.
@MainActor
final class SnapBoostReceipts {
    private unowned let host: any SnapBoostReceiptsHost

    init(host: any SnapBoostReceiptsHost) {
        self.host = host
    }

    /// The spend's visible receipt: a gold "+N" born on the boost anchor
    /// that rises and dissolves; the anchor itself moves only by the glass's
    /// own press. Pure theatre over state that already changed — the wallet
    /// debited synchronously before this runs, so the animation can be
    /// dropped (hidden anchor, mid-reuse) without the count going wrong.
    func playBoostConfirmation(amount: Int) {
        guard !host.boostButton.isHidden, host.boostButton.bounds.width > 0 else { return }

        let label = UILabel()
        label.text = "+\(amount)"
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .heavy, relativeTo: .headline, maximumPointSize: 24
        )
        label.textColor = .systemYellow
        // The scrim under it is a gradient, not a guarantee — the same
        // legibility shadow the nav glyphs wear over live media.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        label.center = CGPoint(x: host.boostButton.center.x, y: host.boostButton.frame.minY - Spacing.md)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        host.addSubview(label)

        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                label.center.y -= 18
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                label.center.y -= 26
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            label.removeFromSuperview()
        }

        // ⚠️ NO DIP OF ITS OWN (#1186): the pill is a glass button, whose
        // native press already acknowledges the tap. A spring scale here ran
        // on top of it and read as a tremble (the owner, on a device).
    }

    /// The refund's receipt: a cool "−N" that sinks and dissolves — the
    /// confirmation float mirrored, in the direction money leaves the post.
    /// White, not gold: gold is the earning color, and an undo is not a
    /// payout.
    func playBoostRefund(amount: Int) {
        guard !host.boostButton.isHidden, host.boostButton.bounds.width > 0 else { return }
        let label = UILabel()
        label.text = "−\(amount)"
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .heavy, relativeTo: .headline, maximumPointSize: 24
        )
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        label.center = CGPoint(x: host.boostButton.center.x, y: host.boostButton.frame.minY - Spacing.md)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        host.addSubview(label)
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                label.center.y += 14
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                label.center.y += 20
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    /// The refusal: a horizontal head-shake on the anchor — the wallet
    /// couldn't cover the spend, and nothing changed. Paired with the
    /// error haptic the owner fires; deliberately no floating label (a
    /// "-0" would read as a payout).
    func playBoostDenied() {
        guard !host.boostButton.isHidden else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -7, 6, -4, 3, -1, 0]
        shake.duration = 0.4
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        host.boostButton.layer.add(shake, forKey: "boost.denied")
    }
}
