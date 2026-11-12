import DesignSystem
import MediaCore
import UIKit

/// The pull to the next / previous post's pill (#2298 § 2): a small Liquid
/// Glass capsule coming out of the stream's edge, the target post's author
/// in a ring that fills with the pull.
///
/// ```
///   ( (◔) Next post )                     out of the edge, the ring filling
///   ( (●) Release for the next post )     the threshold: full, one tick
/// ```
///
/// - **The material is the system's** (`UIGlassEffect`), as the pull to go
///   back's pill (`PullToGoBackIndicator`) wears it: no hand-made blur.
/// - **The ring is the progress**, full exactly at the threshold
///   (`PostPullRule`); the words change there, with the app's threshold
///   haptic (`PullThresholdFeedback`, the `armed` role), once per crossing.
/// - **Reduce Motion:** it appears and goes without the pop, and the ring
///   does not fill with the pull — empty, then full at the threshold.
///
/// It takes no touches: it is the pull's answer, never a control.
@MainActor
final class PostPullPill: UIView {
    static let height: CGFloat = 40
    private static let avatarDiameter: CGFloat = 26
    private static let ringDiameter: CGFloat = 32
    private static let ringWidth: CGFloat = 2.5

    private(set) var direction: PostPullDirection = .next
    private(set) var isArmed = false
    private(set) var isShown = false
    /// 0…1, as the ring draws it.
    private(set) var progress: CGFloat = 0

    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let avatar = AvatarView(diameter: PostPullPill.avatarDiameter, size: .avatar)
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let label = UILabel()
    private let feedback = PullThresholdFeedback()
    private let reducesMotion: () -> Bool

    init(reducesMotion: @escaping () -> Bool = { MotionPreference.reducesMotion }) {
        self.reducesMotion = reducesMotion
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // The pill is read with the page, not as an element of its own: the
        // page's custom actions say the same without a pull.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        glass.clipsToBounds = true
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        for layer in [track, ring] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = Self.ringWidth
            layer.lineCap = .round
            glass.contentView.layer.addSublayer(layer)
        }
        track.strokeColor = UIColor.tertiaryLabel.cgColor
        ring.strokeColor = UIColor.label.cgColor
        ring.strokeEnd = 0
        glass.contentView.addSubview(avatar)
        label.font = .scaledFont(forTextStyle: .subheadline, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        glass.contentView.addSubview(label)
        glass.alpha = 0
        applyWords()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: PostPullPill, _) in
            pill.resolveInk()
        }
    }

    /// The ring's ink, resolved for the pill's style (layers hold no dynamic
    /// colour).
    private func resolveInk() {
        track.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        ring.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pull's target: its direction and its author.
    func configure(direction: PostPullDirection, target: PostPullTarget, pipeline: ImagePipeline?) {
        self.direction = direction
        avatar.setMonogram(target.monogram)
        avatar.setPicture(target.avatarURL, pipeline: pipeline)
        isArmed = false
        applyWords()
        setNeedsLayout()
    }

    /// The words for the state: "Next post", then "Release for the next post".
    static func words(_ direction: PostPullDirection, armed: Bool) -> String {
        switch (direction, armed) {
        case (.next, false): "Next post"
        case (.next, true): "Release for the next post"
        case (.previous, false): "Previous post"
        case (.previous, true): "Release for the previous post"
        }
    }

    private func applyWords() {
        label.text = Self.words(direction, armed: isArmed)
    }

    /// The pill's width for its words now, held to `limit`.
    func width(limit: CGFloat) -> CGFloat {
        let text = ((label.text ?? "") as NSString).size(withAttributes: [.font: label.font as Any]).width
        let leading = (Self.height - Self.ringDiameter) / 2
        let natural = leading + Self.ringDiameter + Spacing.sm + text.rounded(.up) + Spacing.md
        return min(limit, natural.rounded(.up))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let inset = (Self.height - Self.ringDiameter) / 2
        let ringFrame = CGRect(x: inset, y: (bounds.height - Self.ringDiameter) / 2,
                               width: Self.ringDiameter, height: Self.ringDiameter)
        let avatarSide = Self.avatarDiameter
        avatar.frame = CGRect(x: ringFrame.midX - avatarSide / 2, y: ringFrame.midY - avatarSide / 2,
                              width: avatarSide, height: avatarSide)
        // The ring starts at twelve o'clock and runs clockwise.
        let radius = (Self.ringDiameter - Self.ringWidth) / 2
        let path = UIBezierPath(
            arcCenter: CGPoint(x: ringFrame.midX, y: ringFrame.midY), radius: radius,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = path
        ring.path = path
        resolveInk()
        CATransaction.commit()
        let labelX = ringFrame.maxX + Spacing.sm
        label.frame = CGRect(x: labelX, y: 0, width: max(0, bounds.width - labelX - Spacing.md), height: bounds.height)
    }

    /// Re-reads the pull: out of the edge past a few points, the ring filling
    /// toward the threshold, the words and the tick at it.
    func apply(_ reading: PostPullTracker.Reading) {
        setShown(reading.isShown)
        progress = reading.progress
        if reading.isArmed != isArmed {
            isArmed = reading.isArmed
            applyWords()
            setNeedsLayout()
        }
        // The tick: once per crossing into the armed state, never on a bounce
        // (the tracker arms only under the finger).
        feedback.update(pulled: isArmed ? 1 : 0, threshold: 1, isTracking: isArmed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = reducesMotion() ? (isArmed ? 1 : 0) : (isArmed ? 1 : progress)
        CATransaction.commit()
    }

    /// The pull ended short or went home: the pill goes back into the edge.
    func retract() {
        guard isShown || isArmed else { return }
        isArmed = false
        applyWords()
        feedback.update(pulled: 0, threshold: 1, isTracking: false)
        setShown(false)
    }

    /// Readies the tick, as a pull begins.
    func prepare() { feedback.prepare() }

    /// Gone at once (a commit's page has left, the stream reset).
    func clear() {
        isShown = false
        isArmed = false
        applyWords()
        progress = 0
        glass.layer.removeAllAnimations()
        glass.alpha = 0
        glass.transform = .identity
        ring.strokeEnd = 0
        feedback.update(pulled: 0, threshold: 1, isTracking: false)
    }

    private func setShown(_ show: Bool) {
        guard show != isShown else { return }
        isShown = show
        guard window != nil, !reducesMotion() else {
            glass.alpha = show ? 1 : 0
            glass.transform = .identity
            return
        }
        // Out of the edge: from small and a little inside it, a spring with
        // some give — the go-back pill's pop.
        let inward: CGFloat = direction == .next ? Self.height / 2 : -Self.height / 2
        if show {
            glass.alpha = 0
            glass.transform = CGAffineTransform(translationX: 0, y: inward).scaledBy(x: 0.5, y: 0.5)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.glass.alpha = 1
                self.glass.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.glass.alpha = 0
                self.glass.transform = CGAffineTransform(translationX: 0, y: inward).scaledBy(x: 0.6, y: 0.6)
            }
        }
    }

    #if DEBUG
    var debugLine: String? { label.text }
    var debugRingFill: CGFloat { ring.strokeEnd }
    #endif
}
