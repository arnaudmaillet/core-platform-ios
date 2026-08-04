import UIKit

/// The inbox lists' section header: the same `SectionHeaderPillButton` the
/// compose picker wears, in the shape a table view can use.
///
/// ⚠️ **Its background is cleared explicitly.** A `UITableViewHeaderFooterView`
/// ships with a material behind it, and in a plain-style table that material is
/// a full-width band — precisely the structural slab the capsule exists instead
/// of. Left alone it would put a frosted bar behind a floating pill, which is
/// two headers stacked and the pill reduced to a label on one of them.
///
/// The rows scroll UNDER it: a plain table pins its section headers, so the
/// pill hangs over the list exactly as the compose picker's does.
final class InboxSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "InboxSectionHeaderView"

    var onTap: (() -> Void)? {
        get { pill.onTap }
        set { pill.onTap = newValue }
    }

    private let pill = SectionHeaderPillButton()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        pill.pinAsHeader(in: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    func setTitle(_ title: String?) {
        pill.setPillTitle(title)
    }
}
