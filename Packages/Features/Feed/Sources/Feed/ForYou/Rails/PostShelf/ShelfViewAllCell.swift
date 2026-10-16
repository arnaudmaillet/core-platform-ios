import DesignSystem
import UIKit

/// "View all" at the end of a shelf's row (#1271): the shelf title's own way
/// in, offered where a viewer who scrolled the row to its end arrives.
///
/// A card of the row's size on a quiet fill, a chevron disc over the words —
/// the chevron pointing RIGHT because it pushes a screen, as the title's and
/// the mosaic's "View all" do (`DiscoverViewAllFooterView`).
final class ShelfViewAllCell: UICollectionViewCell {
    static let reuseID = "ShelfViewAllCell"
    static let title = "View all"

    private let chevron = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .tertiarySystemFill
        contentView.layer.cornerRadius = PostShelfMediaCardCell.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        chevron.image = UIImage(
            systemName: "chevron.right.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        )
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        label.text = Self.title
        label.font = UIFont.scaledFont(forTextStyle: .subheadline, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [chevron, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.sm
        stack.constrain(in: contentView) { parent in
            stack.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            stack.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        isAccessibilityElement = true
        accessibilityLabel = Self.title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
