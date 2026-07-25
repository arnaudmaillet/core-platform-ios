import DesignSystem
import UIKit

/// A pending message request: the same identity/preview column as a
/// conversation row, with the decision attached to the row itself.
///
/// Accept and decline are in-cell buttons rather than swipe actions because
/// the horizontal axis belongs to paging between inbox categories — and
/// because a request is a decision, which reads better as a visible pair of
/// choices than as a hidden gesture.
final class MessageRequestCell: UITableViewCell {
    static let reuseIdentifier = "MessageRequestCell"

    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    private let avatarView = MonogramAvatarView()
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let timeLabel = UILabel()
    private let acceptButton = UIButton(type: .system)
    private let declineButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAccept = nil
        onDecline = nil
    }

    func configure(with model: ConversationDisplayModel) {
        avatarView.setMonogram(model.monogram)
        titleLabel.text = model.title
        previewLabel.text = model.preview.isEmpty ? "Wants to send you a message" : model.preview
        timeLabel.text = model.timeText
        acceptButton.accessibilityLabel = "Accept request from \(model.title)"
        declineButton.accessibilityLabel = "Delete request from \(model.title)"
    }

    private func configure() {
        // No disclosure chevron: the row's affordances are the two buttons,
        // and a third trailing glyph would crowd them.
        selectionStyle = .default

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label

        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = .secondaryLabel
        // Two lines: a request is usually the only message in the thread, so
        // the preview is what the decision is made on.
        previewLabel.numberOfLines = 2

        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureAction(acceptButton, symbol: "checkmark", tint: .tintColor)
        acceptButton.addAction(UIAction { [weak self] _ in self?.onAccept?() }, for: .primaryActionTriggered)
        configureAction(declineButton, symbol: "xmark", tint: .secondaryLabel)
        declineButton.addAction(UIAction { [weak self] _ in self?.onDecline?() }, for: .primaryActionTriggered)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, timeLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Spacing.sm

        let textColumn = UIStackView(arrangedSubviews: [titleRow, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2

        let actions = UIStackView(arrangedSubviews: [declineButton, acceptButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.xs
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [avatarView, textColumn, actions])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg
        ))
    }

    /// A circular tinted-fill button, sized off the system's own bordered
    /// metrics so both buttons match whatever Dynamic Type is set to.
    private func configureAction(_ button: UIButton, symbol: String, tint: UIColor) {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: symbol)
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.baseForegroundColor = tint
        configuration.baseBackgroundColor = tint
        button.configuration = configuration
        button.setContentHuggingPriority(.required, for: .horizontal)
    }
}
