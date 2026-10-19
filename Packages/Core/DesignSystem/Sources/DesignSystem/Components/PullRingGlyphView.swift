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
///
/// **A flood beyond the disc** (`floodBeyond(_:)`, #1368): the Messages
/// inbox's capsule is inverted whole when armed — its words too — so a host
/// hands the glyph its region and its inverted content (`floodContent`), and
/// the one flood fills both, from the glyph out. One implementation for both
/// pulls.
public final class PullRingGlyphView: UIView {
    /// The ring's diameter and stroke.
    public let diameter: CGFloat
    public static let ringWidth: CGFloat = 2

    /// Read on every change, so a Reduce Motion toggled mid-session is
    /// honoured on the next pull. Injected by the tests.
    public var reducesMotion: @MainActor () -> Bool = { MotionPreference.reducesMotion }

    public private(set) var progress: CGFloat = 0
    public private(set) var isArmed = false
    /// Whether arming pops the disc. A host that pops itself (the inbox's
    /// capsule) turns it off.
    public var popsOnArm = true
    /// Whether the ring's track shows for as long as the glyph does — a host
    /// that fades the whole thing in with the pull — rather than only once
    /// there is a pull (the shelves).
    public var ringShownAtRest = false {
        didSet { applyRingVisibility() }
    }

    /// The region the armed ink floods past the disc, nil for the disc alone
    /// (`floodBeyond(_:)`).
    public private(set) weak var floodRegion: UIView?
    /// The inverted region, laid in `floodRegion` under the glyph: the host
    /// puts its inverted content in it (the inbox's "Release to search").
    public let floodContent = UIView()
    private let floodBloom = UIView()
    /// How far the flood reaches from the glyph's centre; nil, the region's
    /// far corner. A region that grows while it floods (the capsule re-fits
    /// to its longer words) gives the reach of its widest self.
    public var floodReach: CGFloat? {
        didSet { setNeedsLayout() }
    }

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
        // ⚠️ NOT CLIPPED: the ring's stroke reaches the disc's very edge, and
        // a round clip there shaved its outer edge (#1368, measured against
        // the inbox's meter). The flood is round by its own mask.
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
        floodBloom.backgroundColor = .black
        floodBloom.transform = Self.collapsedBloom
        floodContent.mask = floodBloom
        floodContent.isHidden = true
        floodContent.isUserInteractionEnabled = false
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
        // The flood: a circle from the glyph's centre, as wide as the disc —
        // or, flooding a region too, as wide as the REGION's flood, so the
        // two circles are one at every frame and the glyph inverts exactly
        // when the wavefront crosses it (#1368).
        let reach = floodRegion == nil ? side / 2 : regionReach
        bloom.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
        bloom.center = CGPoint(x: side / 2, y: side / 2)
        bloom.layer.cornerRadius = reach
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
        layoutFlood()
    }

    // MARK: - A flood beyond the disc (#1368)

    /// Floods `region` too when armed: `floodContent` — the region inverted,
    /// with whatever the host puts in it — is laid in `region` under the
    /// glyph and revealed through a circle from the glyph's centre, on the
    /// disc's own curves. `region` must contain the glyph.
    public func floodBeyond(_ region: UIView) {
        guard let branch = sequence(first: self as UIView, next: { $0.superview }).first(where: { $0.superview === region })
        else { return assertionFailure("the flood's region must contain the glyph") }
        floodRegion = region
        floodContent.removeFromSuperview()
        region.insertSubview(floodContent, belowSubview: branch)
        floodContent.isHidden = !isArmed
        floodBloom.transform = isArmed ? .identity : Self.collapsedBloom
        setNeedsLayout()
        layoutFlood()
    }

    /// Lays the region's flood where the glyph is: called by the glyph's own
    /// layout, and by a host that moves the glyph or resizes the region.
    public func layoutFlood() {
        guard let region = floodRegion else { return }
        floodContent.frame = region.bounds
        let centre = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: region)
        let reach = regionReach
        floodBloom.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
        floodBloom.center = centre
        floodBloom.layer.cornerRadius = reach
    }

    /// How far the region's flood reaches from the glyph's centre.
    private var regionReach: CGFloat {
        if let floodReach { return floodReach }
        guard let region = floodRegion else { return diameter / 2 }
        let centre = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: region)
        return Self.farthestCorner(from: centre, in: region.bounds) + 1
    }

    static func farthestCorner(from point: CGPoint, in rect: CGRect) -> CGFloat {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { hypot($0.x - point.x, $0.y - point.y) }.max() ?? 0
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
        floodContent.backgroundColor = .label
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
        applyRingVisibility()
        CATransaction.commit()
    }

    private func applyRingVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shown: Float = ringShownAtRest ? 1 : progress > 0 ? Float(min(1, progress * 4)) : 0
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
            // The state the motion would have ended on: under Reduce Motion
            // the flood fades and stays open, otherwise it drains.
            let fades = reducesMotion()
            UIView.performWithoutAnimation {
                for (content, mask) in floods {
                    content.alpha = armed || !fades ? 1 : 0
                    mask.transform = armed || fades ? .identity : Self.collapsedBloom
                    content.isHidden = !armed
                }
                disc.transform = .identity
            }
            return
        }
        if reducesMotion() { crossfade(armed: armed) } else { flood(armed: armed) }
    }

    /// The inverted layers and their masks: the disc's, and the region's
    /// when there is one.
    private var floods: [(content: UIView, mask: UIView)] {
        [(armedContent, bloom)] + (floodRegion == nil ? [] : [(floodContent, floodBloom)])
    }

    private func flood(armed: Bool) {
        // Coming from a Reduce Motion crossfade, the inverted layer may be
        // faded out with the flood already open: close it first, unseen.
        for (content, mask) in floods where content.alpha < 1 {
            UIView.performWithoutAnimation {
                mask.transform = Self.collapsedBloom
                content.alpha = 1
            }
        }
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        // ⚠️ The closed flood is still a speck that DRAWS: hidden whenever it
        // is fully drained (the inbox's finding).
        for (content, _) in floods { content.isHidden = false }
        if armed {
            UIView.animate(
                springDuration: 0.45, bounce: 0.15, initialSpringVelocity: 0, delay: 0, options: options
            ) {
                for (_, mask) in self.floods { mask.transform = .identity }
            }
            guard popsOnArm else { return }
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
                for (_, mask) in self.floods { mask.transform = Self.collapsedBloom }
            } completion: { _ in
                guard !self.isArmed else { return }
                for (content, _) in self.floods { content.isHidden = true }
            }
        }
    }

    /// Reduce Motion: the inverted disc fades in or out in place.
    private func crossfade(armed: Bool) {
        UIView.performWithoutAnimation {
            for (content, mask) in floods {
                // An open flood keeps its alpha: only a closed one starts
                // from nothing.
                if armed, content.isHidden || mask.transform != .identity { content.alpha = 0 }
                mask.transform = .identity
                if armed { content.isHidden = false }
            }
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            for (content, _) in self.floods { content.alpha = armed ? 1 : 0 }
        } completion: { _ in
            guard !self.isArmed else { return }
            for (content, _) in self.floods { content.isHidden = true }
        }
    }

    #if DEBUG
    /// What a test reads.
    public var debugRingStrokeEnd: CGFloat { ring.strokeEnd }
    public var debugRingShown: Bool { ring.opacity > 0 }
    public var debugFloodShown: Bool { !armedContent.isHidden }
    /// The region's flood: its mask's model scale, ~0 closed and 1 open.
    public var debugRegionFloodScale: CGFloat { floodBloom.transform.a }
    /// The region's inverted layer's model alpha, 0 when hidden.
    public var debugRegionFloodAlpha: CGFloat { floodContent.isHidden ? 0 : floodContent.alpha }
    /// The two floods' radii at full scale: one circle when there is a region.
    public var debugFloodRadii: (disc: CGFloat, region: CGFloat) { (bloom.bounds.width / 2, floodBloom.bounds.width / 2) }
    /// The disc's model scale — what the pop changes.
    public var debugDiscScale: CGFloat { disc.transform.a }
    #endif
}
