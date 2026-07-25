import DesignSystem
import UIKit

/// The empty/failed state every inbox surface falls back to: a large hairline
/// symbol over a title and an explanatory line, centred in the page.
///
/// Shared so the three tabs cannot drift into three different ideas of what
/// "nothing here" looks like — the fastest way for a paged experience to feel
/// assembled from parts.
final class InboxStatusView: UIView {
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    init() {
        super.init(frame: .zero)

        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .tertiaryLabel
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 44, weight: .light
        )

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel

        for label in [titleLabel, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }

        let column = UIStackView(arrangedSubviews: [symbolView, titleLabel, messageLabel])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Spacing.sm
        column.setCustomSpacing(Spacing.md, after: symbolView)
        column.constrain(in: self) { parent in
            column.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            column.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            column.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(symbol: String, title: String, message: String) {
        symbolView.image = UIImage(systemName: symbol)
        titleLabel.text = title
        messageLabel.text = message
        // One element to VoiceOver: the symbol is decoration, and the two
        // labels are one sentence.
        isAccessibilityElement = true
        accessibilityLabel = "\(title). \(message)"
    }
}
