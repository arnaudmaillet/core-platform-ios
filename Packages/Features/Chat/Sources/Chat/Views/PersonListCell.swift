import UIKit

/// A person row in the compose picker.
///
/// A plain `UICollectionViewListCell` carrying a system content configuration,
/// with the identity disc hung off it as a *leading accessory* rather than
/// laid out by hand. That is what keeps the row vanilla: the list cell keeps
/// ownership of its separators (inset past the accessory automatically), its
/// selection and highlight states, and its Dynamic Type metrics — none of
/// which a custom content view gets for free.
final class PersonListCell: UICollectionViewListCell {
    /// Created once per cell and handed back to the accessory on every
    /// configure — accessories replace their custom view wholesale, and
    /// allocating a fresh disc per reuse would churn a view per scrolled row.
    /// A fixed-size host for the identity disc.
    ///
    /// UIKit *asserts* that a custom accessory view keeps
    /// `translatesAutoresizingMaskIntoConstraints` enabled, and
    /// `MonogramAvatarView` sizes itself with constraints on itself — the two
    /// cannot be the same view. So the disc travels inside a container that
    /// reports its size the frame-based way, and uses Auto Layout internally,
    /// which is exactly the arrangement the assertion allows.
    private final class AvatarAccessoryView: UIView {
        override var intrinsicContentSize: CGSize {
            CGSize(width: MonogramAvatarView.rowDiameter, height: MonogramAvatarView.rowDiameter)
        }
    }

    private let avatarHost = AvatarAccessoryView(
        frame: CGRect(x: 0, y: 0, width: MonogramAvatarView.rowDiameter, height: MonogramAvatarView.rowDiameter)
    )
    private let monogramView = MonogramAvatarView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        monogramView.pin(to: avatarHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with model: PersonDisplayModel) {
        monogramView.setMonogram(model.monogram)

        var content = UIListContentConfiguration.subtitleCell()
        content.attributedText = Self.nameText(for: model)
        // Every section's rows are the same two-line shape — name over handle,
        // disc centred across both. `nil` (not "") on the rare handle-less row
        // so it collapses to one line rather than leaving a gap under the name.
        content.secondaryText = model.handle.isEmpty ? nil : model.handle
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        contentConfiguration = content

        // No progress accessory: picking a row resolves synchronously and the
        // push begins in the same runloop turn, so there is never a moment
        // where a row is "working" and would have one to show.
        accessories = [
            .customView(configuration: .init(
                customView: avatarHost,
                placement: .leading(displayed: .always),
                reservedLayoutWidth: .actual,
                maintainsFixedSize: true
            ))
        ]

        accessibilityLabel = [model.displayName, model.handle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The name, with the verification seal inline after it.
    ///
    /// An attachment rather than a second accessory: the badge belongs to the
    /// name — it should sit against the last letter and move with it when the
    /// text wraps or scales — where a trailing accessory would pin it to the
    /// far edge of the row, next to the progress spinner.
    private static func nameText(for model: PersonDisplayModel) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .headline)
        let name = NSMutableAttributedString(
            string: model.displayName,
            attributes: [.font: font, .foregroundColor: UIColor.label]
        )
        guard model.isVerified else { return name }

        let seal = NSTextAttachment()
        seal.image = UIImage(
            systemName: "checkmark.seal.fill",
            withConfiguration: UIImage.SymbolConfiguration(font: font)
        )?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        name.append(NSAttributedString(string: "\u{00A0}"))
        name.append(NSAttributedString(attachment: seal))
        return name
    }
}
