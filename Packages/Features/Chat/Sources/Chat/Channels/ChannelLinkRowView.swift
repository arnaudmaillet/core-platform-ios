import DesignSystem
import UIKit

/// A row that leads somewhere rather than being a conversation (#2215): a
/// disc with a symbol where a face sits, a title and a line under it, and a
/// chevron. Laid out like a conversation row, so it reads as one of the
/// list's entries. Requests' Join requests rows (#2230) are drawn with it.
final class ChannelLinkRowView: UIView {
    private let disc = UIView()
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        disc.layer.cornerRadius = MonogramAvatarView.rowDiameter / 2
        disc.layer.cornerCurve = .circular
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        symbolView.constrain(in: disc) { parent in
            symbolView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            symbolView.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
            disc.heightAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
        ])
        titleLabel.font = .appFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        messageLabel.font = .appFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        for label in [titleLabel, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        let chevron = UIImageView(image: UIImage(systemName: "chevron.forward"))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [disc, text, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.isUserInteractionEnabled = false
        let inset = PersonRowMetrics.verticalInset(forContentHeight: MonogramAvatarView.rowDiameter)
        row.pin(to: self, insets: NSDirectionalEdgeInsets(top: inset, leading: Spacing.lg, bottom: inset, trailing: Spacing.lg))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `emphasised`: something waits — the disc in the tint, as a count would be.
    func configure(symbol: String, title: String, message: String, emphasised: Bool = false) {
        symbolView.image = UIImage(systemName: symbol)
        disc.backgroundColor = emphasised ? .tintColor : .secondarySystemFill
        symbolView.tintColor = emphasised ? .white : .label
        titleLabel.text = title
        messageLabel.text = message
        accessibilityLabel = "\(title). \(message)"
    }

    /// The title on show. Tests.
    var debugTitle: String? { titleLabel.text }
}

/// One row of Requests' Join requests section (#2230): a channel the viewer
/// runs, and how many wait — "Night walks · 3 requests" — leading to the
/// list where they are answered.
final class JoinRequestsCell: UITableViewCell {
    static let reuseIdentifier = "JoinRequestsCell"

    private let row = ChannelLinkRowView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        row.pin(to: contentView)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with entry: ChannelJoinRequestsDigest.Entry) {
        row.configure(
            symbol: "person.crop.circle.badge.questionmark",
            title: ChannelCopy.joinRequestsRow(channel: entry.channel.name, count: entry.count),
            message: ChannelCopy.joinRequestsRowMessage, emphasised: true
        )
        accessibilityLabel = row.accessibilityLabel
    }

    /// The row's title. Tests.
    var debugTitle: String? { row.debugTitle }
}
