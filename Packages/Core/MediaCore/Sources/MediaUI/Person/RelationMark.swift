import DesignSystem
import MediaCore
import UIKit

/// The relation mark's sizes for a face of a given diameter (#2014): the
/// badge's side, worn by the author pill's 36 pt face, the inbox row's 48 pt
/// one and the profile header's 96 to 110 pt one alike. The mark is the
/// badge alone: no face wears a ring (#2082, the owner 2026-11-03).
///
/// ⚠️ NOT A RATIO. At the pill's 36 pt the badge is 20 pt (#1277); kept in
/// proportion, a 96 pt face would wear a 53 pt badge. Between the pill's
/// face and the header's, the side runs from 20 to 28 pt, on to the header's
/// Dynamic-Type cap (110 pt), and no further — rounded to half points, so a
/// badge never lands between pixels.
public nonisolated struct RelationMarkMetrics: Equatable, Sendable {
    /// The pill's face, where the mark is today's.
    public static let pillFace: CGFloat = 36
    /// The profile header's face (`HeroHeaderView`'s avatar).
    public static let headerFace: CGFloat = 96
    /// The header's Dynamic-Type cap: no face's mark grows past it.
    public static let largestFace: CGFloat = 110
    /// The clear gap round the badge, cut out of the face.
    public static let cutoutGap: CGFloat = 1.5

    public let faceDiameter: CGFloat
    /// The badge's side.
    public let badgeDiameter: CGFloat

    public init(faceDiameter: CGFloat) {
        self.faceDiameter = faceDiameter
        let face = min(max(faceDiameter, Self.pillFace), Self.largestFace)
        let progress = (face - Self.pillFace) / (Self.headerFace - Self.pillFace)
        badgeDiameter = Self.halfPoint(20 + 8 * progress)
    }

    /// How far the badge's trailing and bottom edges sit past the face's
    /// (#1793): its centre on the face's circle at 45°, `r·cos 45°` from the
    /// face's centre on both axes.
    public var cornerOffset: CGFloat {
        badgeDiameter / 2 - faceDiameter / 2 * (1 - cos(.pi / 4))
    }

    /// The most the badge could reach past the face: half its side.
    public var overhang: CGFloat { badgeDiameter / 2 }

    /// The badge's cutout: its radius and the gap.
    public var cutoutRadius: CGFloat { badgeDiameter / 2 + Self.cutoutGap }

    /// The circled symbol's size on the badge (#1199): as large as its side
    /// allows.
    public var glyphPointSize: CGFloat { badgeDiameter - 3 }

    /// The badge's centre in the face's own space: on its circle, 45° below
    /// its trailing side.
    public func badgeCentre(inFaceOfSide side: CGFloat, rightToLeft: Bool) -> CGPoint {
        let radius = side / 2
        let reach = radius * cos(.pi / 4)
        return CGPoint(x: rightToLeft ? radius - reach : radius + reach, y: radius + reach)
    }

    private static func halfPoint(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}

/// What the relation mark draws, apart from its size (#2014) — shared by the
/// author pill and the profile header.
public enum RelationMark {
    /// The face's mask reaches far past any face: only the cutout is out.
    static let faceMaskReach = CGRect(x: -500, y: -500, width: 1000, height: 1000)

    /// A face's mask with the badge's disc taken out (#1912): everything
    /// but `cutout`, filled even-odd, whatever the face's size — the mask
    /// never depends on bounds that might not be final.
    public static func faceMaskPath(cutout: UIBezierPath) -> CGPath {
        let path = UIBezierPath(rect: faceMaskReach)
        path.append(cutout)
        return path.cgPath
    }

    /// The badge's cutout, a disc round `centre`.
    public static func cutout(centre: CGPoint, metrics: RelationMarkMetrics) -> UIBezierPath {
        UIBezierPath(arcCenter: centre, radius: metrics.cutoutRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
    }
}

/// A face's mask with the relation badge's disc cut out (#1912): the one
/// owner of that mask for every face that wears the mark: the author pill,
/// the inbox rows, the profile header (#2098).
///
/// Cut from the badge's centre in the face's own space, never the badge's
/// frame, which may not be laid out yet.
///
/// ⚠️ EVERY CHANGE ON SCREEN IS ANIMATED, NEVER A CUT (#2419, the owner
/// 2026-11-13). Most faces end with no badge now (every author the viewer
/// doesn't follow), so the cutout opens and closes on most rows:
/// - **closed** (a skeleton that turned out to be no badge, an unfollow):
///   the disc shrinks to nothing while the badge's bone fades or the badge
///   shrinks into its centre, and the mask leaves at the end;
/// - **opened** (a follow, a relation that changed): the disc grows from
///   nothing as the badge grows in;
/// - each one starts from where the cutout IS: a change that reverses
///   mid-way never jumps;
/// - under Reduce Motion the cutout cross-fades instead (its `veil`, a disc
///   filling the hole, fades in or out with the badge's cross-fade).
@MainActor
public final class FaceCutout {
    /// The mask set on the face while it is cut.
    public let mask = CAShapeLayer()
    /// The hole's fill, faded for Reduce Motion's cross-fade: clear while
    /// the face is cut, opaque where the cutout is gone.
    private let veil = CAShapeLayer()
    private var centre: CGPoint?
    private var metrics: RelationMarkMetrics?
    /// A close under way: the mask leaves the face when it ends.
    public private(set) var isClosing = false
    /// An open under way: a layout pass leaves it to finish.
    public private(set) var isOpening = false
    /// Which animation a completion belongs to: one replaced by another
    /// must not end the new one early.
    private var generation = 0
    static let closeKey = "faceCutout.close"
    static let openKey = "faceCutout.open"

    /// Whether motion is reduced: the system setting, unless a test says.
    public var reducesMotion: @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    public init() {
        mask.fillRule = .evenOdd
        veil.fillColor = UIColor.black.cgColor
        veil.opacity = 0
        mask.addSublayer(veil)
    }

    /// Whether `face` wears this cutout now.
    public func isCut(_ face: CALayer) -> Bool { face.mask === mask }

    /// Cuts the badge's disc round `centre` (in `face`'s space) out of
    /// `face`, at once. A layout pass: an open under way to the same disc
    /// runs to its end; a close under way is cancelled.
    public func cut(_ face: CALayer, centre: CGPoint, metrics: RelationMarkMetrics) {
        if isOpening, isCut(face), self.centre == centre, self.metrics == metrics { return }
        stopAnimations()
        self.centre = centre
        self.metrics = metrics
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = face.bounds
        mask.path = Self.maskPath(centre: centre, radius: metrics.cutoutRadius)
        veil.path = Self.disc(centre: centre, radius: metrics.cutoutRadius).cgPath
        veil.opacity = 0
        CATransaction.commit()
        face.mask = mask
    }

    /// Opens the cutout round `centre`: animated, the disc grows from
    /// nothing, or from where a close under way has brought it; at once
    /// otherwise, or when the face is already cut.
    public func open(_ face: CALayer, centre: CGPoint, metrics: RelationMarkMetrics, animated: Bool) {
        let wasCut = isCut(face)
        guard animated, !wasCut || isClosing else {
            cut(face, centre: centre, metrics: metrics)
            return
        }
        let reduced = reducesMotion()
        let fromPath = wasCut ? (mask.presentation()?.path ?? mask.path) : Self.maskPath(centre: centre, radius: 0.01)
        let fromVeil = wasCut ? (veil.presentation()?.opacity ?? veil.opacity) : 1
        stopAnimations()
        self.centre = centre
        self.metrics = metrics
        let full = Self.maskPath(centre: centre, radius: metrics.cutoutRadius)
        isOpening = true
        generation += 1
        let generation = generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.isOpening = false
            }
        }
        mask.frame = face.bounds
        mask.path = full
        veil.path = Self.disc(centre: centre, radius: metrics.cutoutRadius).cgPath
        veil.opacity = 0
        if reduced {
            veil.add(Self.animation("opacity", from: fromVeil, to: Float(0)), forKey: Self.openKey)
        } else {
            mask.add(Self.animation("path", from: fromPath, to: full), forKey: Self.openKey)
        }
        CATransaction.commit()
        face.mask = mask
    }

    /// Gives `face` back whole: at once, or (animated) the disc shrinks to
    /// nothing from where it is, over a skeleton's exit
    /// (`UIView.skeletonFadeDuration`), and the mask leaves at the end. A
    /// layout pass leaves a close under way to finish (`isClosing`).
    public func close(_ face: CALayer, animated: Bool) {
        guard isCut(face) else { return }
        guard animated, let centre else {
            stopAnimations()
            face.mask = nil
            return
        }
        guard !isClosing else { return }
        let reduced = reducesMotion()
        let fromPath = mask.presentation()?.path ?? mask.path
        let fromVeil = veil.presentation()?.opacity ?? veil.opacity
        stopAnimations()
        isClosing = true
        generation += 1
        let generation = generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak face] in
            MainActor.assumeIsolated {
                guard let self, self.isClosing, self.generation == generation else { return }
                self.isClosing = false
                if let face, self.isCut(face) { face.mask = nil }
            }
        }
        if reduced {
            veil.opacity = 1
            veil.add(Self.animation("opacity", from: fromVeil, to: Float(1)), forKey: Self.closeKey)
        } else {
            let shut = Self.maskPath(centre: centre, radius: 0.01)
            mask.path = shut
            mask.add(Self.animation("path", from: fromPath, to: shut), forKey: Self.closeKey)
        }
        CATransaction.commit()
    }

    /// Matches the face to `mark` (#2419): a mark that draws nothing closes
    /// the cutout, one that draws a badge opens it, animated where the
    /// change is seen. Without a centre yet (the face not laid out), the
    /// host's next layout pass cuts it.
    public func wear(
        _ mark: PersonRelationBadge, on face: CALayer, centre: CGPoint?, metrics: RelationMarkMetrics, animated: Bool
    ) {
        guard mark.cutsTheFace else {
            close(face, animated: animated)
            return
        }
        guard let centre else { return }
        open(face, centre: centre, metrics: metrics, animated: animated)
    }

    private func stopAnimations() {
        isClosing = false
        isOpening = false
        mask.removeAnimation(forKey: Self.closeKey)
        mask.removeAnimation(forKey: Self.openKey)
        veil.removeAllAnimations()
    }

    private static func disc(centre: CGPoint, radius: CGFloat) -> UIBezierPath {
        UIBezierPath(arcCenter: centre, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
    }

    private static func maskPath(centre: CGPoint, radius: CGFloat) -> CGPath {
        RelationMark.faceMaskPath(cutout: disc(centre: centre, radius: radius))
    }

    private static func animation(_ keyPath: String, from: Any?, to: Any?) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = UIView.skeletonFadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    #if DEBUG
    /// The hole's fill's opacity: 0 while cut, 1 where Reduce Motion's
    /// close ended. Tests.
    public var debugVeilOpacity: Float { veil.opacity }
    /// Whether an open or a close is animating. Tests.
    public var debugIsAnimating: Bool {
        [mask.animation(forKey: Self.openKey), mask.animation(forKey: Self.closeKey),
         veil.animation(forKey: Self.openKey), veil.animation(forKey: Self.closeKey)].contains { $0 != nil }
    }
    #endif
}

/// The relation badge (#925): a disc on the face's rim wearing the relation's
/// symbol, at the size its face's metrics give. The author pill's, the
/// profile header's (#2014) and every marked face's.
///
/// PASSIVE (#2419, the owner 2026-11-13): information, never a control. It
/// takes no touch on any host: a tap on the face does what the face does
/// (the person opening contract, #2145). Following is the Follow button's.
///
/// ONE CIRCLED SF SYMBOL in a palette (#1199): the disc and the mark are one
/// symbol, so a change of relation is ONE replace. To or from no badge, the
/// same symbol in clear ink: the badge grows in from its centre, or shrinks
/// into it, while its face's cutout opens or closes (`FaceCutout`). Under
/// Reduce Motion the glyph cross-fades.
///
/// ⚠️ FIXED INK, and a disc that is a SYMBOL, not a background. On glass a
/// semantic ink pair draws vibrant and an inverted badge vanishes in dark mode
/// (memory `sheet-glass-vibrancy-ink`), and the glass repaints a subview's
/// `backgroundColor` with its own corner (`glass-paints-background-color`).
public final class RelationBadgeView: UIView {
    /// The sizes it is drawn at.
    public private(set) var metrics: RelationMarkMetrics
    private let glyph = UIImageView()
    /// The skeleton's disc while the relation is not known (#2098): the
    /// kit's bone, the badge's whole side, under the glyph.
    private let bone = SkeletonBoneView(rounding: .capsule)
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    /// The badge on screen.
    public private(set) var drawn: PersonPill.Badge = .none
    /// Changes drawn with an animation (the replace, or the cross-fade).
    public private(set) var replaceCount = 0
    /// Whether motion is reduced: the system setting, unless a test says.
    public var reducesMotion: @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    public init(metrics: RelationMarkMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        // Never a control (#2419): touches go through to the face's host.
        isUserInteractionEnabled = false
        bone.isUserInteractionEnabled = false
        bone.isHidden = true
        bone.pin(to: self)
        glyph.isUserInteractionEnabled = false
        glyph.contentMode = .center
        glyph.constrain(in: self) { parent in
            glyph.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            glyph.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // Its size is its own and never the host's to negotiate.
        let width = widthAnchor.constraint(equalToConstant: metrics.badgeDiameter)
        let height = heightAnchor.constraint(equalToConstant: metrics.badgeDiameter)
        NSLayoutConstraint.activate([width, height])
        widthConstraint = width
        heightConstraint = height
        glyph.image = Self.glyphImage(.none, metrics: metrics)
        applyAccessibility(for: .none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var glyphImage: UIImage? { glyph.image }
    /// Whether the skeleton's bone shows. Tests.
    public var showsBone: Bool { !bone.isHidden }

    /// Resizes the badge for a face whose side layout resolved (a Dynamic
    /// Type face): its side and its glyph, in place.
    public func setMetrics(_ metrics: RelationMarkMetrics) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
        widthConstraint?.constant = metrics.badgeDiameter
        heightConstraint?.constant = metrics.badgeDiameter
        glyph.image = Self.glyphImage(drawn, metrics: metrics)
    }

    /// Draws `badge`. The skeleton's bone shows for `.loading`; leaving it,
    /// the bone fades out as a skeleton's exit (#1769) while the mark comes in
    /// through the badge's replace, in place (#2098). Every change seen is
    /// animated (#2419); a host filling a face afresh passes `animated:
    /// false` and the final state is drawn at once.
    public func show(_ badge: PersonPill.Badge, animated: Bool) {
        guard badge != drawn else { return }
        let wasLoading = drawn == .loading
        drawn = badge
        applyAccessibility(for: badge)
        if badge == .loading {
            bone.showSkeleton()
        } else if wasLoading {
            if animated { bone.fadeOutSkeleton() } else { bone.isHidden = true }
        }
        let image = Self.glyphImage(badge, metrics: metrics)
        guard animated else {
            glyph.image = image
            return
        }
        replaceCount += 1
        if reducesMotion() {
            // The glyph's cross-fade borrows the bone's timing; named apart, so the
            // skeleton guard does not read it as a skeleton leaving.
            let crossFade = UIView.skeletonFadeDuration
            UIView.transition(
                with: glyph, duration: crossFade,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
            ) { self.glyph.image = image }
        } else {
            glyph.setSymbolImage(image, contentTransition: .replace)
        }
    }

    /// Whether the badge is its own accessibility element (#2050): the state
    /// read as words ("Following", "Friends"), never a button. False where
    /// the host speaks for it: the pill and the rows say the relation with
    /// the face.
    public var speaksForItself = false {
        didSet { applyAccessibility(for: drawn) }
    }

    private func applyAccessibility(for badge: PersonPill.Badge) {
        isAccessibilityElement = speaksForItself && badge.accessibilityLabel != nil
        accessibilityLabel = speaksForItself ? badge.accessibilityLabel : nil
        accessibilityTraits = .none
    }

    /// The disc's ink for a badge (#1197, the owner 2026-10-15): a FOLLOWED
    /// check on grey, its mark pink; FRIENDS dark grey (`48484A`, `3A3A3C` in
    /// the dark, #2476), their mark mint (#2440); clear for none.
    public static func discInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none, .loading: .clear
        case .following: PersonPillBadgeInks.quietDisc
        case .friends: PersonPillBadgeInks.friendsDisc
        }
    }

    /// The glyph's ink for a badge: pink on the grey disc, mint on Friends'
    /// dark one (#2440).
    public static func glyphInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none, .loading: .clear
        case .following: PersonPillBadgeInks.accent
        case .friends: PersonPillBadgeInks.friendsGlyph
        }
    }

    /// ⚠️ A palette is fixed ink already (no tint reaches it), and must NOT
    /// be re-marked `.alwaysOriginal`: that drops the palette and draws the
    /// whole symbol in the view's tint (measured: the system blue).
    private static func glyphImage(_ badge: PersonPill.Badge, metrics: RelationMarkMetrics) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: metrics.glyphPointSize, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [glyphInk(for: badge), discInk(for: badge)]))
        return UIImage(systemName: badge.circledSymbolName)?
            .applyingSymbolConfiguration(configuration)
            ?? UIImage()
    }
}
