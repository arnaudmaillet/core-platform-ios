import DesignSystem
import UIKit

/// The row under the sixth new notification: "Show 4 more", a quiet capsule
/// aligned with the avatars. Selecting the row reveals the rest in place.
final class NotificationShowMoreCell: UICollectionViewListCell {
    private let capsule = CapsuleView()
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.backgroundColor = .tertiarySystemFill
        capsule.layer.cornerCurve = .continuous

        label.font = UIFont(
            descriptor: UIFont.preferredFont(forTextStyle: .subheadline).fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
            ]),
            size: 0
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .medium)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.tintColor = .secondaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let content = UIStackView(arrangedSubviews: [label, chevron])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Spacing.xs + 2
        content.pin(to: capsule, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md + 2, bottom: Spacing.sm, trailing: Spacing.md
        ))

        capsule.constrain(in: contentView) { parent in
            capsule.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.lg)
            capsule.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.xs)
            parent.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: Spacing.sm)
            capsule.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -Spacing.lg)
        }

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(hiddenCount: Int) {
        label.text = "Show \(hiddenCount) more"
        accessibilityLabel = "Show \(hiddenCount) more notifications"
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        // The capsule is the button; the press darkens it, not the row.
        backgroundConfiguration = .clear()
        capsule.backgroundColor = state.isHighlighted ? .systemFill : .tertiarySystemFill
    }
}

/// A view that is always a capsule: its radius follows its own height, set in
/// ITS layout pass — the cell's pass runs before the capsule has a height.
private final class CapsuleView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
