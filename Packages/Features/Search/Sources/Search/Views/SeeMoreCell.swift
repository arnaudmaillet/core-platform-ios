import UIKit

/// The row that ends a truncated Recent section: "See more", and how many
/// more there are.
///
/// The count is in the row rather than left implicit. "See more" alone asks
/// the viewer to tap to find out whether it is worth tapping; "See 7 more"
/// is a row they can decide about without spending a tap on it.
///
/// The only row on this screen that is NOT a `PersonListCell`: it is a control
/// rather than a thing, so it takes no disc and leaves the leading column to
/// the rows it belongs to.
final class SeeMoreCell: UICollectionViewListCell {
    // Stated even though the body is empty: declaring ANY initializer
    // suppresses inheritance of the superclass's designated ones, so without
    // this the `init?(coder:)` below leaves `init(frame:)` an unimplemented
    // stub — which compiles cleanly and traps the first time the list dequeues
    // a cell.
    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(hiddenCount: Int) {
        var content = UIListContentConfiguration.cell()
        content.text = "See \(hiddenCount) more"
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        // Tinted, not label-coloured: this row is a control, and the rows
        // above it are content. Same weight of type, different job.
        content.textProperties.color = .tintColor
        content.image = UIImage(systemName: "chevron.down")
        content.imageProperties.tintColor = .tintColor
        content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
        contentConfiguration = content

        accessibilityTraits = .button
    }
}
