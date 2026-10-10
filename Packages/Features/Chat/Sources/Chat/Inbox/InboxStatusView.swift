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
    /// The way out of a failure (#797) — "Pull to retry" was a promise the
    /// inbox could not keep: its pull opens search.
    private let actionButton = UIButton(configuration: .borderless())
    private var action: (() -> Void)?

    init() {
        super.init(frame: .zero)

        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .tertiaryLabel
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 44, weight: .light
        )

        titleLabel.font = .appFont(forTextStyle: .headline)
        titleLabel.textColor = .label

        messageLabel.font = .appFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel

        for label in [titleLabel, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }

        actionButton.isHidden = true
        actionButton.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)

        let column = UIStackView(arrangedSubviews: [symbolView, titleLabel, messageLabel, actionButton])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Spacing.sm
        column.setCustomSpacing(Spacing.md, after: symbolView)
        column.setCustomSpacing(Spacing.lg, after: messageLabel)
        column.constrain(in: self) { parent in
            column.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            column.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            column.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(
        symbol: String, title: String, message: String,
        actionTitle: String? = nil, action: (() -> Void)? = nil
    ) {
        symbolView.image = UIImage(systemName: symbol)
        titleLabel.text = title
        messageLabel.text = message
        self.action = action
        let showsAction = actionTitle != nil && action != nil
        actionButton.isHidden = !showsAction
        actionButton.configuration?.title = actionTitle
        // One element to VoiceOver when there is nothing to do: the symbol is
        // decoration, and the two labels are one sentence. With an action the
        // button keeps its own element.
        isAccessibilityElement = !showsAction
        accessibilityLabel = "\(title). \(message)"
    }

    /// Only the action takes a touch: the page around it stays reachable.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit is UIStackView ? nil : hit
    }
}
