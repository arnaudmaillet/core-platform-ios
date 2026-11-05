import UIKit

/// The "go back" pull's indicator (#2045, #2046): an elastic glass pill in
/// the gap the pulled page opens.
///
/// ```
///   ( ↑ )                         it pops in, a 40 pt disc
///   ( ↑  Pull to go back     )    it stretches with the pull, a grey bubble
///                                 filling it from the chevron
///   ( ‹  Release to go back  )    the threshold: all filled, a jelly, one tick
/// ```
///
/// Built from the conventions the platforms share for an overscroll that
/// does something: the progress follows the pull's distance; the threshold
/// is felt once, as the image changes (one haptic, in sync); the shape
/// squashes and stretches as the rubber band does; a spring absorbs the
/// gesture's tension rather than a cut (Android's predictive back, the
/// pull-to-refresh's guidance, Telegram's pull to the next channel).
///
/// - **The threshold is the app's pull distance** (`HeroPullToRefreshView
///   .threshold`): every pull in the app costs the same effort.
/// - **Falling back under it reverses everything,** and the tick fires once
///   per crossing, never on a bounce (`PullThresholdFeedback`).
/// - **Reduce Motion:** no pop, no jelly, no stretch spring — plain changes.
public final class PullToGoBackIndicator: UIView {
    public enum Direction: Sendable {
        /// Pulled up from the end of a list (#2045).
        case up
        /// Pulled down from its top (#2046).
        case down
    }

    public static let height: CGFloat = 40
    /// The lift at which the pill pops in.
    static let appearLift: CGFloat = 8

    public let direction: Direction
    public private(set) var isArmed = false
    /// How far toward the threshold, 0…1.
    public private(set) var progress: CGFloat = 0

    private let pill = UIVisualEffectView(effect: UIGlassEffect())
    private let fill = UIView()
    private let chevron = UIImageView()
    private let label = UILabel()
    private let feedback = PullThresholdFeedback()
    private var shown = false
    private var fullWidth: CGFloat = 200
    private let reducesMotion: () -> Bool

    public init(direction: Direction, reducesMotion: @escaping () -> Bool = { MotionPreference.reducesMotion }) {
        self.direction = direction
        self.reducesMotion = reducesMotion
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        pill.clipsToBounds = true
        pill.cornerConfiguration = .capsule()
        // A NEUTRAL fill, not the brand's (the owner, 2026-11-05): a grey
        // bubble, its leading edge round — a capsule of its own.
        fill.backgroundColor = .systemGray4
        fill.layer.cornerRadius = Self.height / 2
        fill.layer.cornerCurve = .continuous
        fill.isUserInteractionEnabled = false
        pill.contentView.addSubview(fill)
        chevron.contentMode = .center
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        chevron.image = UIImage(systemName: direction == .up ? "chevron.up" : "chevron.down")
        label.font = .scaledFont(forTextStyle: .subheadline, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail
        label.text = "Pull to go back"
        label.alpha = 0
        pill.contentView.addSubview(chevron)
        pill.contentView.addSubview(label)
        addSubview(pill)
        pill.alpha = 0
        applyInk(armed: false)
        accessibilityLabel = label.text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: CGSize { CGSize(width: fullWidth, height: Self.height) }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width, measuredFullWidth()), height: Self.height)
    }

    /// The pill at its widest: the chevron, the longer line, the padding.
    private func measuredFullWidth() -> CGFloat {
        let text = ("Release to go back" as NSString).size(withAttributes: [.font: label.font as Any]).width
        return (Self.height + text.rounded(.up) + 18).rounded(.up)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        fullWidth = min(bounds.width, measuredFullWidth())
        layoutPill()
    }

    /// The pill's width for the pull: a disc that stretches into the pill —
    /// slowly at first, faster under tension, as a band does.
    private func layoutPill() {
        let eased = pow(progress, 1.6)
        let width = Self.height + (fullWidth - Self.height) * eased
        pill.bounds = CGRect(x: 0, y: 0, width: width, height: Self.height)
        pill.center = CGPoint(x: bounds.midX, y: bounds.midY)
        chevron.frame = CGRect(x: 0, y: 0, width: Self.height, height: Self.height)
        label.frame = CGRect(x: Self.height - 4, y: 0, width: max(0, width - Self.height - 10), height: Self.height)
        // The fill is a bubble: a disc under the chevron from the first point,
        // growing toward the trailing end with a round front.
        let filled = progress > 0 ? Self.height + (width - Self.height) * progress : 0
        fill.frame = CGRect(x: 0, y: 0, width: isArmed ? width : filled, height: Self.height)
    }

    /// Readies the tick, at the pull's begin.
    public func prepare() { feedback.prepare() }

    /// The page's visible lift: the pill pops in, stretches and fills; at the
    /// threshold it is all filled, its chevron turns to ‹, it jiggles, and
    /// one tick plays while the finger is down.
    public func setPull(_ lift: CGFloat, isTracking: Bool = true) {
        let threshold = HeroPullToRefreshView.threshold
        progress = min(1, max(0, lift / threshold))
        feedback.update(pulled: lift, threshold: threshold, isTracking: isTracking)
        setShown(lift >= Self.appearLift)
        let armed = lift >= threshold
        if armed != isArmed { arm(armed) }
        // Text once the pill is wide enough to hold it.
        label.alpha = isArmed ? 1 : min(1, max(0, (progress - 0.35) / 0.35))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutPill()
        CATransaction.commit()
        accessibilityLabel = label.text
    }

    // MARK: - Motion

    private func setShown(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        guard window != nil, !reducesMotion() else {
            pill.alpha = show ? 1 : 0
            pill.transform = .identity
            return
        }
        if show {
            // The pop: up from small, a spring with some give.
            pill.alpha = 0
            pill.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
                           options: [.allowUserInteraction]) {
                self.pill.alpha = 1
                self.pill.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.pill.alpha = 0
                self.pill.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            }
        }
    }

    private func arm(_ armed: Bool) {
        isArmed = armed
        label.text = armed ? "Release to go back" : "Pull to go back"
        let turn: CGFloat = direction == .up ? -.pi / 2 : .pi / 2
        let animated = window != nil && !reducesMotion()
        let apply = {
            self.applyInk(armed: armed)
            // ↑ or ↓ turns to ‹: the release is the back button.
            self.chevron.transform = armed ? CGAffineTransform(rotationAngle: turn) : .identity
        }
        guard animated else { return apply() }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        if armed { jiggle() }
    }

    /// The threshold's squash and stretch, in time with the tick: wide and
    /// flat, then narrow and tall, then rest.
    private func jiggle() {
        let squash = CAKeyframeAnimation(keyPath: "transform.scale.x")
        squash.values = [1, 1.12, 0.96, 1.02, 1]
        let stretch = CAKeyframeAnimation(keyPath: "transform.scale.y")
        stretch.values = [1, 0.86, 1.06, 0.99, 1]
        for animation in [squash, stretch] {
            animation.keyTimes = [0, 0.25, 0.55, 0.8, 1]
            animation.duration = 0.42
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        let group = CAAnimationGroup()
        group.animations = [squash, stretch]
        group.duration = 0.42
        pill.layer.add(group, forKey: "jiggle")
    }

    private func applyInk(armed: Bool) {
        // The ink stays the label's: grey under it, never the brand.
        chevron.tintColor = .label
        label.textColor = .label
        fill.alpha = armed ? 1 : 0.85
    }

    #if DEBUG
    public var debugShown: Bool { shown }
    public var debugSymbolTurned: Bool { chevron.transform != .identity }
    public var debugLine: String? { label.text }
    public var debugPillWidth: CGFloat { pill.bounds.width }
    public var debugFillWidth: CGFloat { fill.frame.width }
    #endif
}
