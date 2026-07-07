import DesignSystem
import UIKit

/// One activity row: monogram avatar, the sentence + relative time, and an
/// unread dot. No avatar image — notifications carry only ids.
final class NotificationCell: UITableViewCell {
    static let reuseIdentifier = "NotificationCell"

    private enum Metrics {
        static let avatarSize: CGFloat = 40
        static let unreadDotSize: CGFloat = 10
    }

    private let avatarView = UIView()
    private let monogramLabel = UILabel()
    private let textLabel_ = UILabel()
    private let timeLabel = UILabel()
    private let unreadDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with model: NotificationDisplayModel) {
        monogramLabel.text = model.monogram
        textLabel_.text = model.text
        timeLabel.text = model.timeText
        unreadDot.isHidden = model.isRead
        contentView.backgroundColor = model.isRead ? .systemBackground : .secondarySystemBackground
    }

    private func configure() {
        selectionStyle = .default

        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.layer.cornerRadius = Metrics.avatarSize / 2
        avatarView.clipsToBounds = true
        monogramLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)

        textLabel_.font = .preferredFont(forTextStyle: .subheadline)
        textLabel_.adjustsFontForContentSizeCategory = true
        textLabel_.textColor = .label
        textLabel_.numberOfLines = 2

        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = .secondaryLabel

        unreadDot.backgroundColor = .systemBlue
        unreadDot.layer.cornerRadius = Metrics.unreadDotSize / 2
        unreadDot.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [textLabel_, timeLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [avatarView, textStack, unreadDot])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        ))

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize),
            unreadDot.widthAnchor.constraint(equalToConstant: Metrics.unreadDotSize),
            unreadDot.heightAnchor.constraint(equalToConstant: Metrics.unreadDotSize)
        ])
    }
}
