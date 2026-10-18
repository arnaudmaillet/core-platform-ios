import UIKit

/// A glyph that a pull rings, then floods (the owner, 2026-10-18): the
/// Messages inbox's pull-to-search meter (`PullToSearchIndicatorView`) on a
/// glyph alone — for the shelves' pull past a row's end, which pushes "View
/// all" (`ShelfViewAllCell`).
///
/// - **Pulling:** a ring draws itself around the glyph as the pull grows
///   (`setProgress`), over a quiet track — full exactly at the threshold.
/// - **Armed** (past the threshold): the ring's ink floods the disc from the
///   glyph out, on a spring with a little bounce, the glyph inverting with
///   it, and the disc pops — a quick swell and a springy settle, in time with
///   the haptic the caller plays.
/// - **Disarmed:** the flood drains on an accelerating curve, no spring — a
///   retreat that wobbled would read as indecision.
/// - **Reduce Motion:** the inverted disc fades in and out in place.
///
/// The ring and the track show only while there is a pull: at rest the
/// glyph is alone, as it always was.
public final class PullRingGlyphView: UIView {
    /// The ring's diameter and stroke.
    public let diameter: CGFloat
    public static let ringWidth: CGFloat = 2

    /// Read on every change, so a Reduce Motion toggled mid-session is
    /// honoured on the next pull. Injected by the tests.
    public var reducesMotion: @MainActor () -> Bool = { MotionPreference.reducesMotion }

    public private(set) var progress: CGFloat = 0
    public private(set) var isArmed = false

    private let disc = UIView()
    private let ringTrack = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let restingGlyph = UIImageView()
    // Armed ink: the inverted disc, revealed through `bloom`.
    private let armedContent = UIView()
    private let bloom = UIView()
    private let armedGlyph = UIImageView()

    private static let collapsedBloom = CGAffineTransform(scaleX: 0.001, y: 0.001)

    public init(image: UIImage?, diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isUserInteractionEnabled = false
        disc.layer.cornerRadius = diameter / 2
        disc.clipsToBounds = true
        addSubview(disc)
        for track in [ringTrack, ring] {
            track.fillColor = nil
            track.lineWidth = Self.ringWidth
            track.lineCap = .round
            disc.layer.addSublayer(track)
        }
        ring.strokeEnd = 0
        ringTrack.opacity = 0
        ring.opacity = 0
        for glyph in [restingGlyph, armedGlyph] {
            glyph.image = image
            glyph.contentMode = .center
        }
        disc.addSubview(restingGlyph)
        armedContent.addSubview(armedGlyph)
        bloom.backgroundColor = .black
        bloom.transform = Self.collapsedBloom
        armedContent.mask = bloom
        armedContent.isHidden = true
        disc.addSubview(armedContent)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (self: Self, _: UITraitCollection) in
            self.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let side = diameter
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.center = CGPoint(x: bounds.midX, y: bounds.midY)
        restingGlyph.frame = disc.bounds
        armedContent.frame = disc.bounds
        armedGlyph.frame = armedContent.bounds
        // The flood: a circle from the glyph's centre, as wide as the disc.
        bloom.bounds = disc.bounds
        bloom.center = CGPoint(x: side / 2, y: side / 2)
        bloom.layer.cornerRadius = side / 2
        // The meter tracks the finger, not trailing it by a quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = (side - Self.ringWidth) / 2
        let path = UIBezierPath(
            arcCenter: CGPoint(x: side / 2, y: side / 2), radius: radius,
            startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true
        ).cgPath
        ringTrack.path = path
        ring.path = path
        CATransaction.commit()
    }

    private func applyColors() {
        restingGlyph.tintColor = .secondaryLabel
        // Layer colours do not follow the appearance on their own.
        ringTrack.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        // The meter is drawn in the ink the armed disc is FILLED with, so
        // the full ring and the flood that grows out of it read as one thing.
        ring.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        armedContent.backgroundColor = .label
        armedGlyph.tintColor = .systemBackground
    }

    /// The pull, 0 at rest and 1 at the threshold: the ring's stroke, and the
    /// ring itself showing as soon as there is a pull.
    public func setProgress(_ progress: CGFloat) {
        let progress = min(max(progress, 0), 1)
        guard progress != self.progress else { return }
        self.progress = progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = progress
        let shown: Float = progress > 0 ? Float(min(1, progress * 4)) : 0
        ringTrack.opacity = shown
        ring.opacity = shown
        CATransaction.commit()
    }

    /// Arms or disarms the glyph — animated, and reversible at any point of
    /// the animation (every block starts from what is on screen).
    public func setArmed(_ armed: Bool, animated: Bool = true) {
        guard armed != isArmed else { return }
        isArmed = armed
        guard animated, window != nil else {
            UIView.performWithoutAnimation {
                armedContent.alpha = 1
                bloom.transform = armed ? .identity : Self.collapsedBloom
                armedContent.isHidden = !armed
                disc.transform = .identity
            }
            return
        }
        if reducesMotion() { crossfade(armed: armed) } else { flood(armed: armed) }
    }

    private func flood(armed: Bool) {
        // Coming from a Reduce Motion crossfade, the inverted layer may be
        // faded out with the flood already open: close it first, unseen.
        if armedContent.alpha < 1 {
            UIView.performWithoutAnimation {
                bloom.transform = Self.collapsedBloom
                armedContent.alpha = 1
            }
        }
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        // ⚠️ The closed flood is still a speck that DRAWS: hidden whenever it
        // is fully drained (the inbox's finding).
        armedContent.isHidden = false
        if armed {
            UIView.animate(
                springDuration: 0.45, bounce: 0.15, initialSpringVelocity: 0, delay: 0, options: options
            ) {
                self.bloom.transform = .identity
            }
            // The pop, in time with the haptic. Only on arming.
            UIView.animate(withDuration: 0.1, delay: 0, options: options.union(.curveEaseOut)) {
                self.disc.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            } completion: { _ in
                UIView.animate(
                    springDuration: 0.4, bounce: 0.35, initialSpringVelocity: 0, delay: 0, options: options
                ) {
                    self.disc.transform = .identity
                }
            }
        } else {
            UIView.animate(withDuration: 0.22, delay: 0, options: options.union(.curveEaseIn)) {
                self.bloom.transform = Self.collapsedBloom
            } completion: { _ in
                if !self.isArmed { self.armedContent.isHidden = true }
            }
        }
    }

    /// Reduce Motion: the inverted disc fades in or out in place.
    private func crossfade(armed: Bool) {
        UIView.performWithoutAnimation {
            bloom.transform = .identity
            if armed {
                armedContent.alpha = 0
                armedContent.isHidden = false
            }
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.armedContent.alpha = armed ? 1 : 0
        } completion: { _ in
            if !self.isArmed { self.armedContent.isHidden = true }
        }
    }

    #if DEBUG
    /// What a test reads.
    public var debugRingStrokeEnd: CGFloat { ring.strokeEnd }
    public var debugRingShown: Bool { ring.opacity > 0 }
    public var debugFloodShown: Bool { !armedContent.isHidden }
    #endif
}
