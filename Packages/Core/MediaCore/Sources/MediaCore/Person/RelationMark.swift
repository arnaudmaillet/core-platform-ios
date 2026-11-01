import DesignSystem
import UIKit

/// The relation mark's sizes for a face of a given diameter (#2014): the
/// ring's width and the badge's side, worn by the author pill's 36 pt face
/// and the profile header's 96 to 110 pt one alike.
///
/// ⚠️ NOT A RATIO. At the pill's 36 pt the mark is a 2 pt ring and a 20 pt
/// badge (#1298, #1277); kept in proportion, a 96 pt face would wear a 53 pt
/// badge. Between the pill's face and the header's, the sizes run from the
/// pill's to a 4 pt ring and a 28 pt badge, on to the header's Dynamic-Type
/// cap (110 pt), and no further — rounded to half points, so a ring never
/// lands between pixels.
public nonisolated struct RelationMarkMetrics: Equatable, Sendable {
    /// The pill's face, where the mark is today's.
    public static let pillFace: CGFloat = 36
    /// The profile header's face (`HeroHeaderView`'s avatar).
    public static let headerFace: CGFloat = 96
    /// The header's Dynamic-Type cap: no face's mark grows past it.
    public static let largestFace: CGFloat = 110
    /// The clear gap round the badge, cut out of the face and the ring.
    public static let cutoutGap: CGFloat = 1.5

    public let faceDiameter: CGFloat
    /// The ring's thickness.
    public let ringWidth: CGFloat
    /// The badge's side.
    public let badgeDiameter: CGFloat

    public init(faceDiameter: CGFloat) {
        self.faceDiameter = faceDiameter
        let face = min(max(faceDiameter, Self.pillFace), Self.largestFace)
        let progress = (face - Self.pillFace) / (Self.headerFace - Self.pillFace)
        ringWidth = Self.halfPoint(2 + 2 * progress)
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

    /// The ring's ink (#1298): grey (the badge's quiet disc) while the viewer
    /// follows, the accent once they are friends, clear otherwise.
    public static func ringInk(for relation: PersonPill.Badge) -> UIColor {
        switch relation {
        case .following: PersonPillBadgeInks.quietDisc
        case .friends: PersonPillBadgeInks.accent
        case .none, .follow, .pending: .clear
        }
    }

    /// Whether `relation` draws a ring at all.
    public static func hasRing(_ relation: PersonPill.Badge) -> Bool {
        relation == .following || relation == .friends
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
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    /// The badge on screen.
    public private(set) var drawn: PersonPill.Badge = .none
    /// Changes drawn through the replace transition.
    public private(set) var replaceCount = 0

    public init(metrics: RelationMarkMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
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

    /// Resizes the badge for a face whose side layout resolved (a Dynamic
    /// Type face): its side and its glyph, in place.
    public func setMetrics(_ metrics: RelationMarkMetrics) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
        widthConstraint?.constant = metrics.badgeDiameter
        heightConstraint?.constant = metrics.badgeDiameter
        glyph.image = Self.glyphImage(drawn, metrics: metrics)
    }

    public func show(_ badge: PersonPill.Badge, animated: Bool) {
        guard badge != drawn else { return }
        drawn = badge
        apply(interactionFor: badge)
        let image = Self.glyphImage(badge, metrics: metrics)
        guard animated else {
            glyph.image = image
            return
        }
        replaceCount += 1
        glyph.setSymbolImage(image, contentTransition: .replace)
    }

    /// Only the "+" takes touches — a state mark lets them through to its
    /// host's own tap. The host is the accessibility element (the pill says
    /// the relation, and offers the follow as a custom action).
    private func apply(interactionFor badge: PersonPill.Badge) {
        isUserInteractionEnabled = badge == .follow
        isAccessibilityElement = false
    }

    /// The disc's ink for a badge (#1197, the owner 2026-10-15): the "+"
    /// black; a FOLLOWED check and a pending request grey, their mark pink;
    /// FRIENDS pink, their mark white; clear for none.
    public static func discInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none: .clear
        case .follow: PersonPillBadgeInks.restingDisc
        case .following, .pending: PersonPillBadgeInks.quietDisc
        case .friends: PersonPillBadgeInks.accent
        }
    }

    /// The glyph's ink for a badge: pink on the grey discs, white elsewhere.
    public static func glyphInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none: .clear
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
