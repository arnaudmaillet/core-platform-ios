import DesignSystem
import UIKit

/// The card that ends each of a shelf's rows (#1296, the owner 2026-10-16):
/// narrow, on a quiet ground, a chevron and no words — the shelf's "View
/// all", running the title's action where a viewer who scrolled the row to
/// its end arrives.
///
/// The chevron points RIGHT because it pushes a screen, as the title's does.
/// And the row PULLED past its end opens it too (`setPull`, the owner
/// 2026-10-17): the card stretches with the finger, a ring draws itself
/// around the chevron as the pull grows and floods past the threshold — the
/// Messages pull-to-search's meter (`PullRingGlyphView`, the owner
/// 2026-10-18) — and a release there pushes "View all".
/// As tall as the row and rounded like its cards, so it reads as the row's
/// last card rather than as a control floating after it.
final class ShelfViewAllCell: UICollectionViewCell {
    static let reuseID = "ShelfViewAllCell"
    /// What VoiceOver calls it: the words the card does not draw.
    static let title = "View all"
    /// The card's width: a thumb's width, never a card's.
    static let width: CGFloat = 40

    private let ground = UIView()
    /// The chevron, and the ring the pull draws around it.
    private let chevron = PullRingGlyphView(
        image: UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        ),
        diameter: ShelfViewAllCell.ringDiameter
    )
    /// The ring's diameter: inside the resting card's 40 pt.
    static let ringDiameter: CGFloat = 34
    /// How far the row is pulled past its end, the card stretching with it.
    private var pull: CGFloat = 0
    private var isArmed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // ⚠️ THE CARD STRETCHES PAST ITS CELL while the row is pulled past its
        // end (`setPull`), so neither the cell nor its content clips; the row
        // itself still does.
        clipsToBounds = false
        contentView.clipsToBounds = false
        ground.backgroundColor = .tertiarySystemFill
        ground.layer.cornerRadius = PostShelfMediaCardCell.cornerRadius
        ground.layer.cornerCurve = .continuous
        contentView.addSubview(ground)

        ground.addSubview(chevron)
        isAccessibilityElement = true
        accessibilityLabel = Self.title
        accessibilityTraits = .button
    }

    /// The row pulled `distance` past its end: the card stretches to cover it
    /// with the finger, and the ring around the chevron fills with the pull —
    /// full at the threshold. `armed` — past it, where a release opens "View
    /// all" — floods the ring (`PullRingGlyphView`).
    func setPull(_ distance: CGFloat, armed: Bool) {
        let distance = max(0, distance)
        guard distance != pull || armed != isArmed else { return }
        pull = distance
        chevron.setProgress(distance / PostShelfSection.endPullThreshold)
        if armed != isArmed {
            isArmed = armed
            chevron.setArmed(armed, animated: window != nil)
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ground.frame = CGRect(x: 0, y: 0, width: bounds.width + pull, height: bounds.height)
        chevron.bounds = CGRect(x: 0, y: 0, width: Self.ringDiameter, height: Self.ringDiameter)
        chevron.center = CGPoint(x: ground.bounds.midX, y: ground.bounds.midY)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setPull(0, armed: false)
    }

    #if DEBUG
    /// What a test reads.
    var debugPull: (width: CGFloat, armed: Bool) { (ground.frame.width, isArmed) }
    var debugRing: PullRingGlyphView { chevron }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
