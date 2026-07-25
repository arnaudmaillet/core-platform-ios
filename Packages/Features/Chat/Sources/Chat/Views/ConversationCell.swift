import DesignSystem
import UIKit

/// A conversation-list row: monogram avatar, title, last-message preview, time.
final class ConversationCell: UITableViewCell {
    static let reuseIdentifier = "ConversationCell"

    private let avatarView = MonogramAvatarView()
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let timeLabel = UILabel()
    private let mutedIcon = UIImageView(image: UIImage(systemName: "bell.slash.fill"))
    private let pinnedIcon = UIImageView(image: UIImage(systemName: "pin.fill"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with model: ConversationDisplayModel) {
        avatarView.setMonogram(model.monogram)
        titleLabel.text = model.title
        previewLabel.text = model.preview.isEmpty ? "No messages yet" : model.preview
        timeLabel.text = model.timeText
        mutedIcon.isHidden = !model.isMuted
        // Pinned reads twice, at two distances: a translucent band that
        // separates the pinned block at a glance (Telegram idiom; system fill
        // colors are translucent and adapt to dark mode), and a pin glyph
        // under the timestamp that names the state up close.
        pinnedIcon.isHidden = !model.isPinned
        backgroundColor = model.isPinned ? .quaternarySystemFill : nil
        let states: [String?] = [
            model.title,
            model.isPinned ? "Pinned" : nil,
            model.isMuted ? "Muted" : nil,
            model.timeText,
            model.preview
        ]
        accessibilityLabel = states.compactMap(\.self).joined(separator: ", ")
    }

    private func configure() {
        accessoryType = .disclosureIndicator

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label

        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 1

        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Status glyphs (both hidden by default): muted sits inline after the
        // title, pinned sits under the timestamp in the trailing column.
        for icon in [mutedIcon, pinnedIcon] {
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.isHidden = true
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, mutedIcon])
        titleRow.axis = .horizontal
        // Center, not firstBaseline: the glyph image views have no baseline.
        titleRow.alignment = .center
        titleRow.spacing = Spacing.sm

        let textColumn = UIStackView(arrangedSubviews: [titleRow, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2

        // Time over pin, both pushed to the row's trailing edge. The stack
        // keeps its width when the pin hides, so a pin toggling can never
        // reflow the title/preview column beside it.
        let statusColumn = UIStackView(arrangedSubviews: [timeLabel, pinnedIcon])
        statusColumn.axis = .vertical
        statusColumn.alignment = .trailing
        statusColumn.spacing = Spacing.xs
        statusColumn.setContentHuggingPriority(.required, for: .horizontal)
        statusColumn.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [avatarView, textColumn, statusColumn])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        ))
    }
}
