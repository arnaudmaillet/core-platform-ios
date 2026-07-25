import DesignSystem
import UIKit

/// A conversation-list row: monogram avatar, title, last-message preview, and
/// a trailing status column carrying the time over any state glyphs.
///
/// Unread is marked here rather than filtered into a tab of its own: the row
/// says so three ways at three distances — a tinted dot you catch scanning,
/// weight you read at a glance, and full-strength preview text once you look.
final class ConversationCell: UITableViewCell {
    static let reuseIdentifier = "ConversationCell"

    private enum Metrics {
        static let unreadDotDiameter: CGFloat = 10
    }

    private let avatarView = MonogramAvatarView()
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let timeLabel = UILabel()
    private let mutedIcon = UIImageView(image: UIImage(systemName: "bell.slash.fill"))
    private let pinnedIcon = UIImageView(image: UIImage(systemName: "pin.fill"))
    private let unreadDot = UIView()

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
        applyUnreadStyle(model.isUnread)
        // Pinned reads twice, at two distances: a translucent band that
        // separates the pinned block at a glance (Telegram idiom; system fill
        // colors are translucent and adapt to dark mode), and a pin glyph
        // under the timestamp that names the state up close.
        pinnedIcon.isHidden = !model.isPinned
        backgroundColor = model.isPinned ? .quaternarySystemFill : nil
        let states: [String?] = [
            model.title,
            model.isUnread ? "Unread" : nil,
            model.isPinned ? "Pinned" : nil,
            model.isMuted ? "Muted" : nil,
            model.timeText,
            model.preview
        ]
        accessibilityLabel = states.compactMap(\.self).joined(separator: ", ")
    }

    /// Unread rows carry weight and full-strength colour; read rows recede.
    /// Only the fonts and colours change — nothing moves — so a row switching
    /// state can't shift the rows around it.
    private func applyUnreadStyle(_ isUnread: Bool) {
        titleLabel.font = isUnread
            ? .preferredFont(forTextStyle: .headline, weight: .bold)
            : .preferredFont(forTextStyle: .headline)
        previewLabel.font = isUnread
            ? .preferredFont(forTextStyle: .subheadline, weight: .semibold)
            : .preferredFont(forTextStyle: .subheadline)
        previewLabel.textColor = isUnread ? .label : .secondaryLabel
        timeLabel.textColor = isUnread ? .label : .secondaryLabel
        unreadDot.isHidden = !isUnread
    }

    private func configure() {
        accessoryType = .disclosureIndicator

        titleLabel.textColor = .label
        previewLabel.numberOfLines = 1
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        for label in [titleLabel, previewLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        applyUnreadStyle(false)

        // Status glyphs (all hidden by default): muted sits inline after the
        // title; the unread dot and the pin share the line under the time.
        for icon in [mutedIcon, pinnedIcon] {
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.isHidden = true
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // The dot is the accent-tinted mark the eye catches while scanning.
        unreadDot.backgroundColor = .tintColor
        unreadDot.layer.cornerRadius = Metrics.unreadDotDiameter / 2
        unreadDot.isHidden = true
        NSLayoutConstraint.activate([
            unreadDot.widthAnchor.constraint(equalToConstant: Metrics.unreadDotDiameter),
            unreadDot.heightAnchor.constraint(equalToConstant: Metrics.unreadDotDiameter)
        ])

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, mutedIcon])
        titleRow.axis = .horizontal
        // Center, not firstBaseline: the glyph image views have no baseline.
        titleRow.alignment = .center
        titleRow.spacing = Spacing.sm

        let textColumn = UIStackView(arrangedSubviews: [titleRow, previewLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2

        // Time over the state glyphs, all pushed to the row's trailing edge.
        // The stack keeps its width when a glyph hides, so toggling pin or
        // unread can never reflow the title/preview column beside it.
        let glyphRow = UIStackView(arrangedSubviews: [pinnedIcon, unreadDot])
        glyphRow.axis = .horizontal
        glyphRow.alignment = .center
        glyphRow.spacing = Spacing.xs

        let statusColumn = UIStackView(arrangedSubviews: [timeLabel, glyphRow])
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

private extension UIFont {
    static func preferredFont(forTextStyle style: TextStyle, weight: Weight) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        let base = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
        return metrics.scaledFont(for: base)
    }
}
