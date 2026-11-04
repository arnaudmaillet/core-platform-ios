import DesignSystem
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
/// owner of that mask for every face that wears the mark — the author pill,
/// the inbox rows, the profile header (#2098).
///
/// Cut from the badge's centre in the face's own space, never the badge's
/// frame, which may not be laid out yet. Closed, the face is whole again: at
/// once, or — a skeleton badge that turned out to be no badge — the disc
/// shrinks to nothing while the bone fades, in one motion.
@MainActor
public final class FaceCutout {
    /// The mask set on the face while it is cut.
    public let mask = CAShapeLayer()
    private var centre: CGPoint?
    /// A close under way: the mask leaves the face when it ends.
    public private(set) var isClosing = false
    /// Which close the running animation's end belongs to: one cancelled by a
    /// cut, then followed by another close, must not end the new one early.
    private var closeGeneration = 0
    private static let closeKey = "faceCutout.close"

    public init() {
        mask.fillRule = .evenOdd
    }

    /// Whether `face` wears this cutout now.
    public func isCut(_ face: CALayer) -> Bool { face.mask === mask }

    /// Cuts the badge's disc round `centre` (in `face`'s space) out of `face`.
    public func cut(_ face: CALayer, centre: CGPoint, metrics: RelationMarkMetrics) {
        cancelClose()
        self.centre = centre
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = face.bounds
        mask.path = RelationMark.faceMaskPath(cutout: RelationMark.cutout(centre: centre, metrics: metrics))
        CATransaction.commit()
        face.mask = mask
    }

    /// Gives `face` back whole: at once, or — animated — the disc shrinks to
    /// nothing over a skeleton's exit (`UIView.skeletonFadeDuration`), the
    /// badge's bone fading with it, and the mask leaves at the end. A layout
    /// pass leaves a close under way to finish (`isClosing`).
    public func close(_ face: CALayer, animated: Bool) {
        guard isCut(face) else { return }
        guard animated, let from = mask.path, let centre else {
            cancelClose()
            face.mask = nil
            return
        }
        guard !isClosing else { return }
        isClosing = true
        closeGeneration += 1
        let generation = closeGeneration
        let to = RelationMark.faceMaskPath(
            cutout: UIBezierPath(arcCenter: centre, radius: 0.01, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        )
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak face] in
            MainActor.assumeIsolated {
                guard let self, self.isClosing, self.closeGeneration == generation else { return }
                self.isClosing = false
                if let face, self.isCut(face) { face.mask = nil }
            }
        }
        let shrink = CABasicAnimation(keyPath: "path")
        shrink.fromValue = from
        shrink.toValue = to
        shrink.duration = UIView.skeletonFadeDuration
        shrink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.setDisableActions(true)
        mask.path = to
        mask.add(shrink, forKey: Self.closeKey)
        CATransaction.commit()
    }

    private func cancelClose() {
        guard isClosing else { return }
        isClosing = false
        mask.removeAnimation(forKey: Self.closeKey)
    }
}

/// The relation badge (#925): a disc on the face's rim wearing the relation's
/// symbol — the author pill's, and the profile header's (#2014), at the size
/// its face's metrics give.
///
/// ONE CIRCLED SF SYMBOL in a palette (#1199): the disc and the mark are one
/// symbol, so a change of relation is ONE replace — and to or from no badge
/// the same symbol in clear ink, so appearing and disappearing are replaces
/// too. The badge is never faded, scaled or hidden by hand.
///
/// ⚠️ FIXED INK, and a disc that is a SYMBOL, not a background. On glass a
/// semantic ink pair draws vibrant and an inverted badge vanishes in dark mode
/// (memory `sheet-glass-vibrancy-ink`), and the glass repaints a subview's
/// `backgroundColor` with its own corner (`glass-paints-background-color`).
public final class RelationBadgeView: UIButton {
    /// The touch area around the disc: a 20pt disc is still too small a target.
    private static let touchOutset: CGFloat = 8

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
    /// Changes drawn through the replace transition.
    public private(set) var replaceCount = 0

    public init(metrics: RelationMarkMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
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
        apply(interactionFor: .none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchOutset, dy: -Self.touchOutset).contains(point)
    }

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
    /// through the badge's replace — the disc's content changes, nothing
    /// moves (#2098).
    public func show(_ badge: PersonPill.Badge, animated: Bool) {
        guard badge != drawn else { return }
        let wasLoading = drawn == .loading
        drawn = badge
        apply(interactionFor: badge)
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
        glyph.setSymbolImage(image, contentTransition: .replace)
    }

    /// Whether the badge is its own accessibility element (#2050): a
    /// button, "Follow", while it shows the "+"; the state read as words
    /// otherwise. False where the host speaks for it — the pill says the
    /// relation, and offers the follow as a custom action.
    public var speaksForItself = false {
        didSet { apply(interactionFor: drawn) }
    }

    /// Only the "+" takes touches — a state mark lets them through to its
    /// host's own tap.
    private func apply(interactionFor badge: PersonPill.Badge) {
        isUserInteractionEnabled = badge == .follow
        isAccessibilityElement = speaksForItself && badge.accessibilityLabel != nil
        accessibilityLabel = speaksForItself ? Self.spokenState(badge) : nil
        accessibilityTraits = speaksForItself && badge == .follow ? .button : .none
    }

    /// The badge's words for VoiceOver. Nil for none.
    static func spokenState(_ badge: PersonPill.Badge) -> String? {
        switch badge {
        case .none, .loading: nil
        case .follow: "Follow"
        case .following: "Following"
        case .friends: "Friends"
        case .pending: "Requested"
        }
    }

    /// The disc's ink for a badge (#1197, the owner 2026-10-15): the "+"
    /// black; a FOLLOWED check and a pending request grey, their mark pink;
    /// FRIENDS pink, their mark white; clear for none.
    public static func discInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none, .loading: .clear
        case .follow: PersonPillBadgeInks.restingDisc
        case .following, .pending: PersonPillBadgeInks.quietDisc
        case .friends: PersonPillBadgeInks.accent
        }
    }

    /// The glyph's ink for a badge: pink on the grey discs, white elsewhere.
    public static func glyphInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none, .loading: .clear
        case .following, .pending: PersonPillBadgeInks.accent
        case .follow, .friends: PersonPillBadgeInks.glyph
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
