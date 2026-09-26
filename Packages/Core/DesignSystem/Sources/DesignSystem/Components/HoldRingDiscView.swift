import QuartzCore
import UIKit

/// The face of a press-and-hold (`HoldToArm`): a small Liquid Glass disc
/// carrying a glyph, with a ring round its rim that fills while the finger
/// stays down.
///
/// ```
///      resting            filling             armed
///     ╭──────╮           ╭──━━━━╮           ╭━━━━━━╮
///     │  ▣   │    ──▶    │  ▣   ┃    ──▶    ┃ ▣(w) ┃   accent fill, white ink,
///     ╰──────╯           ╰──────╯           ╰━━━━━━╯   one "ready" pop
/// ```
///
/// **Armed has to be unmistakable.** It is the difference between letting go
/// doing something and letting go doing nothing — the rule the inbox's
/// pull-to-search capsule follows by inverting. A ring at 97% and a ring at
/// 100% look the same, so arming does not rely on the ring: the disc fills
/// with the accent, the glyph turns white, and the disc gives one pop.
///
/// ⚠️ **THE ACCENT IS A FILL OVER THE GLASS, NOT A TINT OF IT — FILMED.** The
/// first build swapped the glass's `effect` for one with `tintColor` set,
/// inside an animation block. On the iOS 27 simulator that does not blend
/// one tint into the other: the material DEMATERIALISES and forms again, and
/// a 30 fps recording caught four frames (~130 ms) of an empty, washed-out
/// disc — ring and glyph gone — at the very moment the disc had to say
/// "ready". An ordinary accent circle faded in over the glass (`fill`, part
/// of `face`) crosses in one clean step, and the glass under it never moves.
///
/// ⚠️ **THE GLASS IS NEVER TRANSFORMED AND NEVER FADED** — the two glass rules
/// `ToastView` documents, learned elsewhere in this app: a transform moves the
/// RENDERED material (a stale backdrop, a softened edge), and alpha on a
/// `UIVisualEffectView` or any ancestor breaks the material. So the disc is
/// two siblings:
///   - `glass`, which grows, shrinks and rises by its FRAME, re-rendered at
///     its true size every frame, and arrives and leaves by swapping its
///     `effect` inside the animation block — how UIKit interpolates glass;
///   - `face` (ring + glyph), ordinary content over it, which scales and
///     fades freely.
/// This view itself is never faded either: it is removed once `dismiss`
/// has finished.
///
/// ⚠️ **REDUCE MOTION: FADES ONLY.** No growth, no rise, no pop — the glass
/// still materialises (a crossfade) and the face still fades. The ring keeps
/// filling: it is information, not motion, and without it the hold would
/// give no sign of how long is left.
@MainActor
public final class HoldRingDiscView: UIView {
    public enum Metrics {
        /// The disc, a little larger than a tab bubble's glyph area so the
        /// camera reads at a glance, small enough to sit over the bar's
        /// trailing bubble without leaving the screen.
        public static let diameter: CGFloat = 64
        /// The ring's stroke.
        public static let ringWidth: CGFloat = 3.5
        /// The ring's distance in from the glass's edge — inside the rim, so
        /// the ring reads as part of the disc rather than a halo round it.
        public static let ringInset: CGFloat = 5
        /// What the disc arrives from and retreats to, as a fraction of its
        /// size.
        public static let collapsedScale: CGFloat = 0.6
        /// How far below its resting place the disc starts, so it RISES out
        /// of whatever it is anchored to rather than appearing beside it.
        public static let rise: CGFloat = 14
        /// The arrival spring.
        public static let appearDuration: TimeInterval = 0.42
        public static let appearBounce: CGFloat = 0.32
        /// The "ready" pop: how much it swells, and the spring back.
        public static let armedSwell: CGFloat = 1.12
        public static let armedDuration: TimeInterval = 0.36
        /// A retreat has to be quicker than an arrival: the finger has
        /// already said no, and the disc must not linger over the bar.
        public static let retractDuration: TimeInterval = 0.2
        /// Firing: the disc swells a little as it dissolves, handing over to
        /// the sheet rising from below.
        public static let launchScale: CGFloat = 1.18
        public static let launchDuration: TimeInterval = 0.24
    }

    /// How the disc leaves.
    public enum Exit: Sendable {
        /// Let go early, drifted off, or cancelled: it shrinks back to where
        /// it came from.
        case retract
        /// The hold fired: it swells as it dissolves.
        case launch
    }

    private let glass = UIVisualEffectView(effect: nil)
    private let face = UIView()
    /// The accent disc that says "armed", faded in over the glass.
    private let fill = UIView()
    private let glyph = UIImageView()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()

    /// The glass's diameter and how far below rest its centre is — the two
    /// things the arrival, the pop and the exits animate, through layout.
    private var glassScale: CGFloat = 1
    private var glassDrop: CGFloat = 0

    public private(set) var progress: CGFloat = 0
    public private(set) var isArmed = false
    public private(set) var isDismissing = false
    public let reducesMotion: @MainActor () -> Bool

    public init(
        symbolName: String,
        reducesMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    ) {
        self.reducesMotion = reducesMotion
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: Metrics.diameter, height: Metrics.diameter)))
        isUserInteractionEnabled = false
        // A shortcut for a gesture that has a button twin — the Create menu's
        // Camera row, which is VoiceOver's road. Nothing here to focus.
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        glass.cornerConfiguration = .capsule()
        addSubview(glass)

        face.isUserInteractionEnabled = false
        face.frame = bounds
        face.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(face)

        fill.isUserInteractionEnabled = false
        fill.alpha = 0
        face.addSubview(fill)

        for shape in [track, ring] {
            shape.fillColor = nil
            shape.lineWidth = Metrics.ringWidth
            shape.lineCap = .round
            face.layer.addSublayer(shape)
        }
        ring.strokeEnd = 0

        glyph.image = UIImage(systemName: symbolName)
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        glyph.contentMode = .center
        glyph.tintColor = .label
        face.addSubview(glyph)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyColors()
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width * glassScale
        glass.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glass.center = CGPoint(x: bounds.midX, y: bounds.midY + glassDrop)
        glyph.frame = face.bounds
        fill.frame = face.bounds
        fill.layer.cornerRadius = face.bounds.width / 2
        let circle = UIBezierPath(
            arcCenter: CGPoint(x: face.bounds.midX, y: face.bounds.midY),
            radius: face.bounds.width / 2 - Metrics.ringInset - Metrics.ringWidth / 2,
            // From twelve o'clock, clockwise — how every timer fills.
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
        ).cgPath
        track.path = circle
        ring.path = circle
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    // MARK: - Progress

    /// Fills the ring to `value` (clamped to 0...1), with no implicit
    /// animation: the owner calls this every frame from its own clock.
    public func setProgress(_ value: CGFloat) {
        progress = min(max(value, 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = progress
        CATransaction.commit()
    }

    // MARK: - Arrival

    /// Brings the disc in: it rises out of its anchor, grows from
    /// `collapsedScale` with a little bounce, and the glass materialises.
    /// Call once the disc is in a window.
    public func appear() {
        let reduced = reducesMotion()
        glassScale = reduced ? 1 : Metrics.collapsedScale
        glassDrop = reduced ? 0 : Metrics.rise
        face.alpha = 0
        face.transform = reduced ? .identity : Self.faceTransform(scale: Metrics.collapsedScale, drop: Metrics.rise)
        UIView.performWithoutAnimation { layoutIfNeeded() }

        UIView.animate(
            springDuration: Metrics.appearDuration, bounce: reduced ? 0 : Metrics.appearBounce,
            initialSpringVelocity: 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.glassScale = 1
            self.glassDrop = 0
            self.glass.effect = self.window == nil ? nil : self.makeGlass()
            self.face.transform = .identity
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        // The fade on its own curve: a spring's overshoot has nowhere to go
        // on an alpha, and a face fully opaque before the glass under it has
        // formed reads as a glyph floating on nothing.
        UIView.animate(withDuration: reduced ? 0.2 : 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.face.alpha = 1
        }
    }

    // MARK: - Armed

    /// Says the hold is ready: an accent fill, white ink, a full ring, one
    /// pop.
    public func setArmed(_ armed: Bool) {
        guard armed != isArmed, !isDismissing else { return }
        isArmed = armed
        let reduced = reducesMotion()
        if armed { setProgress(1) }
        // Ink and ring switch at once, under the fill as it arrives: a
        // crossfaded glyph passes through grey, which reads as "disabled".
        applyColors()
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.fill.alpha = armed ? 1 : 0
        }
        guard armed, !reduced else { return }
        // The pop: a quick swell, then a spring home — the disc "clicks".
        UIView.animate(withDuration: 0.09, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.glassScale = Metrics.armedSwell
            self.face.transform = CGAffineTransform(scaleX: Metrics.armedSwell, y: Metrics.armedSwell)
            self.setNeedsLayout()
            self.layoutIfNeeded()
        } completion: { _ in
            guard !self.isDismissing else { return }
            UIView.animate(
                springDuration: Metrics.armedDuration, bounce: 0.45,
                initialSpringVelocity: 0, delay: 0, options: [.beginFromCurrentState]
            ) {
                self.glassScale = 1
                self.face.transform = .identity
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }

    // MARK: - Exit

    /// Takes the disc away and removes it from its superview when done.
    /// Idempotent: a second call while leaving is ignored.
    public func dismiss(_ exit: Exit, completion: (@MainActor () -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        let reduced = reducesMotion()
        let duration = exit == .launch ? Metrics.launchDuration : Metrics.retractDuration
        let scale: CGFloat = reduced ? 1 : (exit == .launch ? Metrics.launchScale : Metrics.collapsedScale)
        let drop: CGFloat = reduced || exit == .launch ? 0 : Metrics.rise * 0.6

        if exit == .retract {
            // The ring drains with the disc rather than vanishing with it:
            // the hold visibly running backwards is what says "not this time".
            let drain = CABasicAnimation(keyPath: "strokeEnd")
            drain.fromValue = ring.presentation()?.strokeEnd ?? ring.strokeEnd
            drain.toValue = 0
            drain.duration = duration
            drain.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ring.strokeEnd = 0
            ring.add(drain, forKey: "drain")
            progress = 0
        }

        UIView.animate(
            withDuration: duration, delay: 0,
            options: [exit == .launch ? .curveEaseOut : .curveEaseIn, .beginFromCurrentState]
        ) {
            self.glassScale = scale
            self.glassDrop = drop
            self.glass.effect = nil
            self.face.alpha = 0
            self.face.transform = Self.faceTransform(scale: scale, drop: drop)
            self.setNeedsLayout()
            self.layoutIfNeeded()
        } completion: { _ in
            self.removeFromSuperview()
            completion?()
        }
    }

    // MARK: - Drawing

    private static func faceTransform(scale: CGFloat, drop: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: drop).scaledBy(x: scale, y: scale)
    }

    /// Regular glass — the bar's own material.
    private func makeGlass() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        return effect
    }

    private func applyColors() {
        // Resolved by hand: a layer's CGColor does not follow the trait
        // collection the way a view's colours do.
        let traits = traitCollection
        glyph.tintColor = isArmed ? .white : .label
        fill.backgroundColor = tintColor
        track.strokeColor = (isArmed ? UIColor.white.withAlphaComponent(0.3) : UIColor.label.withAlphaComponent(0.12))
            .resolvedColor(with: traits).cgColor
        ring.strokeColor = (isArmed ? UIColor.white : tintColor ?? .tintColor).resolvedColor(with: traits).cgColor
    }

    #if DEBUG
    /// The accent fill's opacity, for tests: 0 at rest, 1 once armed.
    var debugFillAlpha: CGFloat { fill.alpha }
    var debugHasGlass: Bool { glass.effect != nil }
    var debugRingStrokeEnd: CGFloat { ring.strokeEnd }
    #endif
}
