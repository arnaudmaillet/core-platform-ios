import DesignSystem
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
    /// `MonogramAccessoryHost` documents why the disc needs a host at all.
    private let avatarHost = MonogramAccessoryHost()

    // Stated even though the body is empty: declaring ANY initializer suppresses
    // inheritance of the superclass's designated ones, so without this the
    // `init?(coder:)` below leaves `init(frame:)` an unimplemented stub — which
    // compiles cleanly and traps the first time the list dequeues a cell.
    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with model: PersonDisplayModel) {
        avatarHost.setMonogram(model.monogram)

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
        accessories = [avatarHost.leadingAccessory]

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
