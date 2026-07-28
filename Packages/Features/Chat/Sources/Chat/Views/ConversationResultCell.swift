import DesignSystem
import UIKit

/// A conversation row in the inbox's search results.
///
/// Deliberately *not* `ConversationCell`. That row is built for the inbox
/// proper, where management state is actionable — pin bands, mute glyphs, the
/// unread dot — and it is a `UITableViewCell` besides, where these results are a
/// collection-view list so they can carry the same glass section headers and
/// two-line person rows the compose picker established.
///
/// What survives the move is what a *result* has to say: who it is with, what
/// was last said, when, and whether it is waiting to be read. Pin and mute are
/// dropped on purpose — they order and quieten an inbox, and a list the viewer
/// filtered themselves is already ordered by their query.
final class ConversationResultCell: UICollectionViewListCell {
    private let avatarHost = MonogramAccessoryHost()
    /// Frame-based on purpose: UIKit asserts that custom accessory views keep
    /// `translatesAutoresizingMaskIntoConstraints` enabled, and a bare label
    /// sizes itself intrinsically, so it can be the accessory directly.
    private let timeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with model: ConversationDisplayModel) {
        avatarHost.setMonogram(model.monogram)

        var content = UIListContentConfiguration.subtitleCell()
        // Weight is the unread signal here, as it is in the inbox: nothing moves
        // between states, so a row that arrives read and a row that arrives
        // unread occupy exactly the same space.
        content.text = model.title
        let headline = UIFont.preferredFont(forTextStyle: .headline)
        content.textProperties.font = model.isUnread ? headline.withWeight(.bold) : headline
        content.secondaryText = model.preview.isEmpty ? "No messages yet" : model.preview
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = model.isUnread ? .label : .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 1
        contentConfiguration = content

        timeLabel.text = model.timeText
        timeLabel.textColor = model.isUnread ? .label : .secondaryLabel
        timeLabel.sizeToFit()

        accessories = [avatarHost.leadingAccessory] + timeAccessory(for: model)

        let states: [String?] = [
            model.title,
            model.isUnread ? "Unread" : nil,
            model.timeText,
            model.preview
        ]
        accessibilityLabel = states.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The timestamp, trailing. Omitted entirely rather than shown empty when a
    /// conversation has no activity date — an empty accessory still reserves its
    /// width, and the preview would stop short of the edge for no visible reason.
    private func timeAccessory(for model: ConversationDisplayModel) -> [UICellAccessory] {
        guard !model.timeText.isEmpty else { return [] }
        return [.customView(configuration: .init(
            customView: timeLabel,
            placement: .trailing(displayed: .always),
            reservedLayoutWidth: .actual
        ))]
    }
}
