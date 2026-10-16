import DesignSystem
import UIKit

/// The card that ends each of a shelf's rows (#1296, the owner 2026-10-16):
/// narrow, on a quiet ground, a chevron and no words — the shelf's "View
/// all", running the title's action where a viewer who scrolled the row to
/// its end arrives.
///
/// The chevron points RIGHT because it pushes a screen, as the title's does.
/// As tall as the row and rounded like its cards, so it reads as the row's
/// last card rather than as a control floating after it.
final class ShelfViewAllCell: UICollectionViewCell {
    static let reuseID = "ShelfViewAllCell"
    /// What VoiceOver calls it: the words the card does not draw.
    static let title = "View all"
    /// The card's width: a thumb's width, never a card's.
    static let width: CGFloat = 56

    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .tertiarySystemFill
        contentView.layer.cornerRadius = PostShelfMediaCardCell.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        )
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        chevron.constrain(in: contentView) { parent in
            chevron.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            chevron.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        isAccessibilityElement = true
        accessibilityLabel = Self.title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
