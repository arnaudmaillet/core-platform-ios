import DesignSystem
import UIKit

/// The card that ends each of a shelf's rows (#1296, the owner 2026-10-16):
/// narrow, on a quiet ground, a chevron and no words — the shelf's "View
/// all", running the title's action where a viewer who scrolled the row to
/// its end arrives.
///
/// The chevron points RIGHT because it pushes a screen, as the title's does.
/// And the row PULLED past its end opens it too (`setPull`, the owner
/// 2026-10-17): the card stretches with the finger, its chevron turns into
/// `chevron.right.circle` past the threshold (SF Symbols' replace), and a
/// release there pushes "View all".
/// As tall as the row and rounded like its cards, so it reads as the row's
/// last card rather than as a control floating after it.
final class ShelfViewAllCell: UICollectionViewCell {
    static let reuseID = "ShelfViewAllCell"
    /// What VoiceOver calls it: the words the card does not draw.
    static let title = "View all"
    /// The card's width: a thumb's width, never a card's.
    static let width: CGFloat = 40

    private let ground = UIView()
    private let chevron = UIImageView()
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

        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        ground.addSubview(chevron)
        applySymbol()
        isAccessibilityElement = true
        accessibilityLabel = Self.title
        accessibilityTraits = .button
    }

    /// The row pulled `distance` past its end: the card stretches to cover it
    /// with the finger; `armed` — past the threshold, where a release opens
    /// "View all" — turns the chevron into `chevron.right.circle` through
    /// SF Symbols' replace transition (the owner, 2026-10-17).
    func setPull(_ distance: CGFloat, armed: Bool) {
        let distance = max(0, distance)
        guard distance != pull || armed != isArmed else { return }
        pull = distance
        if armed != isArmed {
            isArmed = armed
            applySymbol(animated: window != nil)
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The armed symbol: the chevron, ringed.
    static let armedSymbol = "chevron.right.circle"

    /// The symbol drawn now.
    private(set) var symbolName = "chevron.right"

    private func applySymbol(animated: Bool = false) {
        symbolName = isArmed ? Self.armedSymbol : "chevron.right"
        guard let image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        ) else { return }
        // The symbol's own replace, as the app's other glyph swaps do
        // (`PersonPill`, `PointsHeartView`); a plain swap off screen.
        if animated {
            chevron.setSymbolImage(image, contentTransition: .replace)
        } else {
            chevron.image = image
        }
        chevron.tintColor = isArmed ? .label : .secondaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ground.frame = CGRect(x: 0, y: 0, width: bounds.width + pull, height: bounds.height)
        chevron.sizeToFit()
        chevron.center = CGPoint(x: ground.bounds.midX, y: ground.bounds.midY)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setPull(0, armed: false)
    }

    #if DEBUG
    /// What a test reads.
    var debugPull: (width: CGFloat, armed: Bool) { (ground.frame.width, isArmed) }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
