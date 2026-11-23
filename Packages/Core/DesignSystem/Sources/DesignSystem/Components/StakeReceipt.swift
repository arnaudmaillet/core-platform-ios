import UIKit

/// The receipts a stake control plays (#2529): the "+N" that rises off it
/// for a spend, the "−N" that sinks off it for an undo, and the head-shake
/// of a refusal. One implementation for the feed rail's like pill, the
/// comments bar's boost bubble and the list card's like chip, so one spend
/// looks the same wherever it was made.
///
/// The values are the owner's (2026-11-23, #2529):
/// - "+N" in the points' pink (`LikesSymbol.tint`), rising;
/// - "−N" sinking, because an undo is not a payout, in the ground's ink
///   (`Ground`);
/// - both born above the control, at the style's gap: the space above a
///   stake control is free on every surface, while below it stand the rail's
///   share bubble, the bar's input row or the next card;
/// - two sizes (`Style`), each with one gap to the control;
/// - Reduce Motion: the number fades in place, with no travel and no pop;
/// - no press of its own on the control: a glass button's native press
///   already acknowledges the tap, and a spring on top of it read as a
///   tremble (#1186). A card's heart that has no press of its own pops
///   (`pop`).
///
/// Pure theatre over state that already changed: the wallet debited before
/// any of this runs, so a receipt dropped (hidden control, cell mid-reuse)
/// leaves nothing wrong.
@MainActor
public final class StakeReceipt {
    /// The control the receipts play on, and the ancestor the numbers float
    /// in: it must not clip them, which the control itself often does (its
    /// capsule). Held weakly, so a host may keep its receipts in a stored
    /// property.
    private weak var anchor: UIView?
    private weak var host: UIView?
    private let style: Style
    private let ground: Ground

    public init(anchor: UIView, host: UIView, style: Style, ground: Ground) {
        self.anchor = anchor
        self.host = host
        self.style = style
        self.ground = ground
    }

    /// The number's size, its gap to the control and how far it travels.
    public struct Style: Equatable, Sendable {
        let pointSize: CGFloat
        let textStyle: UIFont.TextStyle
        let maximumPointSize: CGFloat
        /// Between the control's edge and the number's centre, at birth.
        let offset: CGFloat
        /// The two legs of the travel: the fade-in's, then the glide's.
        let firstLeg: CGFloat
        let secondLeg: CGFloat

        /// Over a post's media: the feed rail and the comments bar.
        public static let regular = Style(
            pointSize: 17, textStyle: .headline, maximumPointSize: 24,
            offset: Spacing.md, firstLeg: 18, secondLeg: 26
        )
        /// On a list card, beside a smaller chip.
        public static let compact = Style(
            pointSize: 15, textStyle: .subheadline, maximumPointSize: 22,
            offset: Spacing.xs, firstLeg: 14, secondLeg: 18
        )

        var font: UIFont {
            .scaledMonospacedDigitSystemFont(
                ofSize: pointSize, weight: .heavy, relativeTo: textStyle, maximumPointSize: maximumPointSize
            )
        }
    }

    /// What the number is drawn over, which picks the undo's ink and whether
    /// the number wears a legibility shadow.
    public enum Ground: Sendable {
        /// Live media: the scrim under it is a gradient, not a guarantee.
        case media
        /// A plain page.
        case page

        var refundInk: UIColor {
            switch self {
            case .media: UIColor.white.withAlphaComponent(0.9)
            case .page: .secondaryLabel
            }
        }
    }

    /// The refusal's head-shake, in points, and its length.
    static let shakeValues: [CGFloat] = [0, -7, 6, -4, 3, -1, 0]
    static let shakeDuration: CFTimeInterval = 0.4
    static let shakeKey = "stakeReceipt.denied"

    /// A spend landed: "+N" born above the control, rising and dissolving.
    public func spend(_ amount: Int) {
        guard let anchor, let host else { return }
        Self.float(amount, rising: true, from: anchor, in: host, style: style, ground: ground,
                   moves: !MotionPreference.reducesMotion)
    }

    /// An undo landed: "−N" born above the control, sinking back into it and
    /// dissolving.
    public func refund(_ amount: Int) {
        guard let anchor, let host else { return }
        Self.float(amount, rising: false, from: anchor, in: host, style: style, ground: ground,
                   moves: !MotionPreference.reducesMotion)
    }

    /// The wallet refused: the control shakes its head, and nothing changed.
    /// No number flies (a "−0" would read as a payout); the host pairs it
    /// with the error haptic.
    public func refuse() {
        guard let anchor else { return }
        Self.shake(anchor)
    }

    /// Additive, so the shake composes with a press still springing back.
    static func shake(_ anchor: UIView) {
        guard !anchor.isHidden else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.isAdditive = true
        shake.values = shakeValues
        shake.duration = shakeDuration
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anchor.layer.add(shake, forKey: shakeKey)
    }

    /// A heart with no press of its own pops: a card's chip, which has no
    /// rail to confirm the spend. Still under Reduce Motion.
    public static func pop(_ icon: UIView) {
        pop(icon, moves: !MotionPreference.reducesMotion)
    }

    static func pop(_ icon: UIView, moves: Bool) {
        guard moves else { return }
        icon.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            icon.transform = .identity
        }
    }

    /// The float itself: "+N" in the points' pink, or "−N" in the ground's
    /// ink; `moves` false fades it in place. Returns the label, or nil when
    /// the control is not on screen.
    @discardableResult
    static func float(
        _ amount: Int, rising: Bool, from anchor: UIView, in host: UIView,
        style: Style, ground: Ground, moves: Bool
    ) -> UILabel? {
        guard !anchor.isHidden, anchor.bounds.width > 0, anchor.window != nil else { return nil }
        let label = UILabel()
        label.text = rising ? "+\(amount)" : "−\(amount)"
        label.font = style.font
        label.textColor = rising ? LikesSymbol.tint : ground.refundInk
        if ground == .media {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }
        label.sizeToFit()
        let frame = anchor.convert(anchor.bounds, to: host)
        label.center = CGPoint(x: frame.midX, y: frame.minY - style.offset)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        host.addSubview(label)
        let step: CGFloat = moves ? (rising ? -1 : 1) : 0
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                label.center.y += step * style.firstLeg
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                label.center.y += step * style.secondLeg
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            // UIKit calls an animation's completion on the main thread.
            MainActor.assumeIsolated { label.removeFromSuperview() }
        }
        return label
    }
}
