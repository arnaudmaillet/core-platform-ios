import DesignSystem
import UIKit

/// The receipts the list's card plays for a stake (`PostGridListRowCell`) —
/// the "+N" float, the heart's pop, the refusal's shake.
@MainActor
enum StakeReceipt {
    /// A number floating off `chip`, then dissolving, drawn in `host` (the
    /// card's content view) because the chip clips to its own box. Pure
    /// theatre over state the wallet already changed.
    static func float(_ text: String, color: UIColor, rising: Bool, from chip: UIView, in host: UIView) {
        let label = UILabel()
        label.text = text
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .heavy)
        label.textColor = color
        label.sizeToFit()
        let frame = chip.convert(chip.bounds, to: host)
        label.center = CGPoint(x: frame.midX, y: rising ? frame.minY - 4 : frame.maxY + 4)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        host.addSubview(label)
        let step: CGFloat = rising ? -1 : 1
        let moves = !MotionPreference.reducesMotion
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                if moves { label.center.y += step * 14 }
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                if moves { label.center.y += step * 18 }
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            // UIKit calls an animation's completion on the main thread.
            MainActor.assumeIsolated { label.removeFromSuperview() }
        }
    }

    /// The heart pops: the rail's confirmation, on a card.
    static func pop(_ icon: UIView) {
        guard !MotionPreference.reducesMotion else { return }
        icon.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            icon.transform = .identity
        }
    }

    /// The control shakes its head. Additive, so it composes with the press
    /// still springing back.
    static func shake(_ view: UIView) {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.isAdditive = true
        shake.values = [0, -6, 6, -4, 4, 0]
        shake.duration = 0.35
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer.add(shake, forKey: "stakeDenied")
    }
}
