import DesignSystem
import UIKit

/// A pending message request, laid out as a standard two-line messaging row
/// with its decision attached:
///
///     [avatar] [name · time ················] ⟷ [Accept] [✕]
///              [message preview ············]
///
/// The avatar and the action pair are both centred across the full two-line
/// height; the text column takes whatever width is left, which is what makes
/// the gap before the buttons elastic. The timestamp sits directly beside the
/// name as part of the same phrase rather than anchored to the far edge —
/// with a short name, a lone right-aligned time reads as unrelated to it.
/// Name and preview truncate; the timestamp and the buttons never shrink, so
/// a long name eats into its own line rather than pushing the decision off
/// screen or displacing the time.
///
/// Accept and dismiss are in-cell buttons rather than swipe actions because
/// the horizontal axis belongs to paging between inbox categories — and
/// because a request is a decision, which reads better as a visible pair of
/// choices than as a hidden gesture. Accept leads as the primary call to
/// action; dismissal is deliberately quieter than the thing it undoes.
final class MessageRequestCell: UITableViewCell {
    static let reuseIdentifier = "MessageRequestCell"

    private enum Metrics {
        /// Diameter of the dismiss button — a comfortable target that still
        /// reads as secondary beside the filled Accept pill.
        static let dismissDiameter: CGFloat = 36
    }

    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let avatarView = BadgedAvatarView()
    private let nameLabel = UILabel()
    private let previewLabel = UILabel()
    private let timeLabel = UILabel()
    private let acceptButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAccept = nil
        onDismiss = nil
    }

    func configure(with model: ConversationDisplayModel) {
        avatarView.setMonogram(model.monogram)
        // The same count, on the same corner, as an All row — and it clears the
        // same way, when the viewer opens the thread and the read cursor moves.
        avatarView.setBadge(model.isUnread ? .count(model.unreadCount) : .none)
        applyUnreadStyle(model.isUnread)
        nameLabel.text = model.title
        previewLabel.text = Self.previewText(for: model)
        // The separator belongs to the timestamp, so a conversation with no
        // activity collapses the whole thing rather than leaving a stray dot.
        timeLabel.text = Self.timestampText(for: model)
        timeLabel.isHidden = timeLabel.text == nil
        acceptButton.accessibilityLabel = "Accept request from \(model.title)"
        dismissButton.accessibilityLabel = "Decline request from \(model.title)"
        // The row itself reads as one sentence; the two buttons stay separate
        // elements so VoiceOver can reach each decision.
        accessibilityElements = [contentView, acceptButton, dismissButton]
        contentView.isAccessibilityElement = true
        contentView.accessibilityLabel = [
            model.title, model.timeText, Self.previewText(for: model)
        ].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A request usually *is* its first message, so the preview carries the
    /// decision. When there is nothing to show, say what the row is rather
    /// than leaving a blank line.
    static func previewText(for model: ConversationDisplayModel) -> String {
        model.preview.isEmpty ? "Wants to send you a message" : model.preview
    }

    /// The timestamp as it reads beside the name — "· 12m". `nil` when the
    /// conversation has no activity to date, so nothing is rendered at all.
    static func timestampText(for model: ConversationDisplayModel) -> String? {
        model.timeText.isEmpty ? nil : "· \(model.timeText)"
    }

    /// An unread request carries its preview in full strength and weight — the
    /// same treatment an unread conversation gets in the All list, because it is
    /// the same statement. Only the font and colour change, so a row settling
    /// from unread to read cannot move the rows around it.
    private func applyUnreadStyle(_ isUnread: Bool) {
        let plain = UIFont.preferredFont(forTextStyle: .subheadline)
        previewLabel.font = isUnread
            ? UIFont.systemFont(ofSize: plain.pointSize, weight: .semibold)
            : plain
        previewLabel.textColor = isUnread ? .label : .secondaryLabel
    }

    private func configure() {
        // No disclosure chevron: the row's affordances are the two buttons,
        // and a third trailing glyph would crowd them.
        selectionStyle = .default

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.textColor = .label

        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.textColor = .secondaryLabel

        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.textColor = .secondaryLabel

        for label in [nameLabel, previewLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
            // One line each: the row is a fixed two-line silhouette, so every
            // request has the same height however long its message is.
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        // The text is what gives way. Both labels yield before the timestamp
        // or the buttons do, so long names truncate instead of shoving the
        // decision out of reach.
        for label in [nameLabel, previewLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureAcceptButton()
        configureDismissButton()

        // Name and timestamp read as one phrase, so they sit together at a
        // small fixed gap. Baseline-aligned, so the smaller timestamp sits on
        // the name's line rather than against its cap height.
        let namePair = UIStackView(arrangedSubviews: [nameLabel, timeLabel])
        namePair.axis = .horizontal
        namePair.alignment = .firstBaseline
        namePair.spacing = Spacing.xs
        namePair.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The spacer — not the name — absorbs the leftover width, which is
        // what keeps the pair adjacent instead of stretched to the column's
        // edges. It is a sibling of the baseline-aligned pair rather than a
        // member of it: a plain view has no baseline to align to.
        let titleSpacer = UIView()
        titleSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        titleSpacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [namePair, titleSpacer])
        titleRow.axis = .horizontal
        titleRow.alignment = .fill

        let textColumn = UIStackView(arrangedSubviews: [titleRow, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2
        // Low hugging: the text column absorbs all leftover width, which IS
        // the elastic gap between the preview and the buttons.
        textColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = UIStackView(arrangedSubviews: [acceptButton, dismissButton])
        actions.axis = .horizontal
        actions.spacing = Spacing.sm
        actions.alignment = .center
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [avatarView, textColumn, actions])
        row.axis = .horizontal
        // Centred: the avatar and the buttons sit on the row's midline,
        // across the whole two-line height.
        row.alignment = .center
        row.spacing = Spacing.md
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg
        ))
    }

    /// Primary call to action: a filled accent pill. It carries a word rather
    /// than a glyph because accepting a stranger's message is a decision worth
    /// naming.
    private func configureAcceptButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.attributedTitle = AttributedString(
            "Accept",
            attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .subheadline)
            ])
        )
        acceptButton.configuration = configuration
        acceptButton.addAction(UIAction { [weak self] _ in self?.onAccept?() }, for: .primaryActionTriggered)
        acceptButton.setContentHuggingPriority(.required, for: .horizontal)
        acceptButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// Secondary: a tinted circle carrying only a glyph. Quiet enough that the
    /// eye lands on Accept first, present enough to be an obvious target.
    private func configureDismissButton() {
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: "xmark")
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.baseForegroundColor = .secondaryLabel
        dismissButton.configuration = configuration
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .primaryActionTriggered)
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dismissButton.widthAnchor.constraint(equalToConstant: Metrics.dismissDiameter),
            dismissButton.heightAnchor.constraint(equalToConstant: Metrics.dismissDiameter)
        ])
    }
}
