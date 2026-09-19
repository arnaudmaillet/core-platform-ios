import QuartzCore
import UIKit

/// The shutter: a white disc in a ring, which becomes a red disc while a clip
/// is held and a red square while it records hands-free, with the take's clips
/// laid around it as segments of a ring that fills as the camera records.
///
/// ```
///        ╭──────╮        idle: a white disc
///      ╭─┤ ●●●● ├─╮      held: a smaller red disc, the ring filling
///      ╰─┤ ●●●● ├─╯      locked: a red rounded square — a stop button
///        ╰──────╯
/// ```
///
/// ⚠️ **IT REPORTS GESTURES; IT DECIDES NOTHING.** What a tap or a hold means
/// depends on the take and on the phase (`CaptureShutterLogic`), which the
/// screen owns. This view only tells a tap from a hold and draws what it is
/// told.
///
/// ⚠️ **ONE RECOGNISER, NOT A TAP AND A LONG PRESS.** Two recognisers either
/// race or wait for each other: a tap made to wait for the long press to fail
/// delays every photograph by the press duration. A zero-duration press sees
/// the finger land and lift itself, and a hold is simply a finger still down
/// after `holdDelay`.
@MainActor
final class CaptureShutterView: UIView {
    enum Look: Equatable {
        case idle
        case holding
        case locked
        /// Busy — a photograph being written, a take being stitched.
        case busy
    }

    static let side: CGFloat = 84
    /// How long a finger must stay down before a press is a hold. Short enough
    /// that a hold starts where the thumb expects, long enough that a firm tap
    /// is still a photograph.
    static let holdDelay: TimeInterval = 0.28

    var onTap: (() -> Void)?
    var onHoldBegan: (() -> Void)?
    var onHoldMoved: ((CGPoint) -> Void)?
    var onHoldEnded: (() -> Void)?

    private let ring = CAShapeLayer()
    private let segmentsLayer = CALayer()
    private let liveSegment = CAShapeLayer()
    private let core = UIView()
    private let press = UILongPressGestureRecognizer()
    private var holdTimer: Timer?
    private var isHolding = false
    private var pressStart: CGPoint = .zero
    private(set) var look: Look = .idle

    private static let ringWidth: CGFloat = 5
    /// The clear arc between two clips, and between the last clip and the one
    /// recording: 3° of the ring.
    ///
    /// ⚠️ **WAS 0.4% — 1.4° — AND DID NOT READ AS A BOUNDARY.** Asked for: "une
    /// meilleure visualisation de séparation entre les segments". At 3° the
    /// white ring shows through between two reds as an unmistakable notch,
    /// over dark footage and bright alike (the ring and the segments carry a
    /// soft shadow for the bright case).
    static let segmentGap: Double = 3.0 / 360

    /// However short a clip, it is never drawn shorter than 1° — its boundary
    /// must still be seen. A clip shorter than the gap then gives up gap
    /// rather than vanish.
    static let shortestDrawn: Double = 1.0 / 360

    /// Where each clip is drawn on the ring: each one short of the next by the
    /// gap, the last one to its end.
    static func strokes(for segments: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        segments.enumerated().map { index, range in
            guard index < segments.count - 1 else { return range }
            let end = max(range.lowerBound + shortestDrawn, range.upperBound - segmentGap)
            return range.lowerBound...min(max(range.lowerBound, end), range.upperBound)
        }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isAccessibilityElement = true
        accessibilityTraits = [.button, .startsMediaSession]
        accessibilityLabel = "Shutter"
        accessibilityHint = "Takes a photo. Touch and hold to record a video."

        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = Self.ringWidth
        // A soft shadow under the ring and its segments, so the white gaps
        // between clips still read over bright footage.
        for layer in [ring, segmentsLayer, liveSegment] as [CALayer] {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 2
            layer.shadowOffset = .zero
        }
        layer.addSublayer(ring)
        layer.addSublayer(segmentsLayer)
        liveSegment.fillColor = UIColor.clear.cgColor
        liveSegment.strokeColor = UIColor.systemRed.cgColor
        liveSegment.lineWidth = Self.ringWidth
        liveSegment.lineCap = .butt
        // ⚠️ EMPTY UNTIL A CLIP RECORDS. A shape layer strokes 0…1 by default,
        // which drew a full red ring round an idle shutter — seen on the first
        // simulator run.
        liveSegment.strokeStart = 0
        liveSegment.strokeEnd = 0
        liveSegment.isHidden = true
        layer.addSublayer(liveSegment)

        core.backgroundColor = .white
        core.isUserInteractionEnabled = false
        addSubview(core)

        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.cancelsTouchesInView = true
        press.addTarget(self, action: #selector(pressed(_:)))
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.side, height: Self.side) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.ringWidth / 2
        let path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        ring.frame = bounds
        ring.path = path.cgPath
        segmentsLayer.frame = bounds
        liveSegment.frame = bounds
        liveSegment.path = Self.arc(in: bounds)
        for case let segment as CAShapeLayer in segmentsLayer.sublayers ?? [] {
            segment.frame = bounds
            segment.path = Self.arc(in: bounds)
        }
        applyCore(animated: false)
    }

    /// A full circle starting at twelve o'clock, drawn clockwise, which the
    /// segments cut with `strokeStart`/`strokeEnd`.
    private static func arc(in bounds: CGRect) -> CGPath {
        let inset = ringWidth / 2
        let radius = bounds.width / 2 - inset
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        return UIBezierPath(
            arcCenter: centre, radius: radius, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        ).cgPath
    }

    // MARK: - What it shows

    /// ⚠️ **A SPRING, AND IT HONOURS REDUCE MOTION.** The morph is the one thing
    /// that tells the author the camera heard the hold; with motion reduced it
    /// still changes — instantly.
    func setLook(_ look: Look, animated: Bool) {
        guard look != self.look else { return }
        self.look = look
        accessibilityValue = switch look {
        case .idle: nil
        case .holding: "Recording"
        case .locked: "Recording, hands-free. Tap to stop."
        case .busy: "Working"
        }
        applyCore(animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    private func applyCore(animated: Bool) {
        let full = bounds.width - Self.ringWidth * 2 - 8
        let (side, radius, colour): (CGFloat, CGFloat, UIColor) = switch look {
        case .idle: (full, full / 2, .white)
        case .holding: (full * 0.78, full * 0.39, .systemRed)
        case .locked: (full * 0.42, 8, .systemRed)
        case .busy: (full * 0.9, full * 0.45, UIColor.white.withAlphaComponent(0.5))
        }
        let apply = {
            self.core.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            self.core.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            self.core.layer.cornerRadius = radius
            self.core.layer.cornerCurve = .continuous
            self.core.backgroundColor = colour
        }
        guard animated else {
            apply()
            return
        }
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction], animations: apply
        )
    }

    /// Lays the take's clips around the ring, as fractions of the budget.
    /// `armedLast` paints the last one as the undo would take it.
    func setSegments(_ segments: [ClosedRange<Double>], armedLast: Bool) {
        segmentsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        hasSegments = !segments.isEmpty
        for (index, range) in Self.strokes(for: segments).enumerated() {
            let segment = CAShapeLayer()
            segment.frame = bounds
            segment.path = Self.arc(in: bounds)
            segment.fillColor = UIColor.clear.cgColor
            let armed = armedLast && index == segments.count - 1
            // ⚠️ YELLOW AND BREATHING, NOT WHITE: the ring under the segments is
            // white, and a white segment on it is no segment at all.
            segment.strokeColor = (armed ? UIColor.systemYellow : UIColor.systemRed).cgColor
            if armed, !UIAccessibility.isReduceMotionEnabled {
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = 1
                breath.toValue = 0.35
                breath.duration = 0.5
                breath.autoreverses = true
                breath.repeatCount = .infinity
                segment.add(breath, forKey: "armed")
            }
            segment.lineWidth = Self.ringWidth
            segment.strokeStart = range.lowerBound
            segment.strokeEnd = range.upperBound
            segmentsLayer.addSublayer(segment)
        }
        debugSegmentCount = segments.count
        debugArmedLast = armedLast && !segments.isEmpty
    }

    /// The clip being recorded, from where the take stands to where it has
    /// reached. Called every frame while recording; no implicit animation, so
    /// the ring follows the clock rather than easing behind it.
    ///
    /// ⚠️ **AFTER THE SAME GAP AS BETWEEN TWO CLIPS**, so the clip being
    /// recorded reads as a new segment from its first frame.
    func setLive(from start: Double, to end: Double) {
        let begins = hasSegments && end > start ? start + Self.segmentGap : start
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveSegment.strokeStart = begins
        liveSegment.strokeEnd = max(begins, end)
        liveSegment.isHidden = end <= begins
        CATransaction.commit()
    }

    /// Whether the take already holds a clip — the live segment keeps its
    /// distance from the last one.
    private var hasSegments = false

    /// Internal for tests: where the clips and the live clip are drawn.
    var debugSegmentStrokes: [ClosedRange<Double>] {
        (segmentsLayer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            .map { Double($0.strokeStart)...Double($0.strokeEnd) }
    }
    var debugLiveStroke: ClosedRange<Double>? {
        liveSegment.isHidden ? nil : Double(liveSegment.strokeStart)...Double(liveSegment.strokeEnd)
    }

    private(set) var debugSegmentCount = 0
    private(set) var debugArmedLast = false

    // MARK: - The gesture

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            pressStart = gesture.location(in: self)
            isHolding = false
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdRecognised() }
            }
            // A press that lands reads as pressed at once, whatever it becomes.
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.core.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            }
        case .changed:
            guard isHolding else { return }
            let point = gesture.location(in: self)
            onHoldMoved?(CGPoint(x: point.x - pressStart.x, y: point.y - pressStart.y))
        case .ended, .cancelled, .failed:
            holdTimer?.invalidate()
            holdTimer = nil
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.core.transform = .identity
            }
            if isHolding {
                isHolding = false
                onHoldEnded?()
            } else if gesture.state == .ended {
                onTap?()
            }
        default:
            break
        }
    }

    private func holdRecognised() {
        holdTimer = nil
        guard press.state == .began || press.state == .changed else { return }
        isHolding = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onHoldBegan?()
    }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }
}

/// The padlock a held finger slides onto to record hands-free. It appears
/// beside the shutter when a hold begins and fills as the finger travels.
@MainActor
final class CaptureLockView: UIView {
    private let glass = UIVisualEffectView(effect: nil)
    private let icon = UIImageView()
    private let track = UIView()
    private(set) var progress: CGFloat = 0

    static let side: CGFloat = 48

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        glass.pin(to: self)
        icon.image = UIImage(systemName: "lock.open.fill")
        icon.tintColor = .white
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.pin(to: glass.contentView)
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ **THE GLASS IS MATERIALISED ON ARRIVAL, NOT IN `init`** — the
    /// `IconSelectorBar` rule: a glass effect made before a window exists
    /// contacts the render server and has stalled headless CI.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, glass.effect == nil { glass.effect = UIGlassEffect() }
    }

    /// How far the finger is towards it, 0...1: the padlock grows and brightens
    /// as it is reached — a pull the thumb can feel before it lands.
    func setProgress(_ value: CGFloat) {
        progress = value
        let scale = 1 + 0.25 * value
        transform = CGAffineTransform(scaleX: scale, y: scale)
        icon.tintColor = value >= 1 ? .systemYellow : .white
    }

    func setLocked(_ locked: Bool) {
        icon.image = UIImage(systemName: locked ? "lock.fill" : "lock.open.fill")
        icon.tintColor = locked ? .systemYellow : .white
    }
}
