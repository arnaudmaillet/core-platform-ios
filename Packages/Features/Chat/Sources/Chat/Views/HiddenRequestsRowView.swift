import DesignSystem
import UIKit

/// The **Hidden requests** row closing the Requests list (#552): requests the
/// viewer's hidden words or offensive filter caught wait one tap further, on
/// their own list, rather than among the others.
///
/// Laid out like a request row — a disc where the avatar sits, two lines of
/// type — so it reads as the list's last entry, with a chevron where a
/// request carries its decision.
final class HiddenRequestsRowView: UIControl {
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let chevronView = UIImageView()

    init() {
        super.init(frame: .zero)

        let disc = UIView()
        disc.backgroundColor = .secondarySystemFill
        disc.layer.cornerRadius = MonogramAvatarView.rowDiameter / 2
        disc.layer.cornerCurve = .circular
        disc.isUserInteractionEnabled = false
        symbolView.image = UIImage(systemName: "eye.slash")
        symbolView.tintColor = .secondaryLabel
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        symbolView.constrain(in: disc) { parent in
            symbolView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            symbolView.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
            disc.heightAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
        ])

        titleLabel.text = "Hidden requests"
        titleLabel.font = .appFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        messageLabel.text = "Requests that match your hidden words"
        messageLabel.font = .appFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        for label in [titleLabel, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }

        chevronView.image = UIImage(systemName: "chevron.forward")
        chevronView.tintColor = .tertiaryLabel
        chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [disc, text, chevronView])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.isUserInteractionEnabled = false
        let inset = PersonRowMetrics.verticalInset(forContentHeight: max(
            MonogramAvatarView.rowDiameter,
            PersonRowMetrics.textHeight([.headline, .subheadline])
        ))
        row.pin(to: self, insets: NSDirectionalEdgeInsets(
            top: inset, leading: Spacing.lg, bottom: inset, trailing: Spacing.lg
        ))

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Hidden requests"
        accessibilityHint = "Requests that match your hidden words"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The press wash a table row gives, so the row answers a touch like the
    /// rows above it.
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .systemFill : .clear }
    }
}
