import DesignSystem
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
/// The rows scroll UNDER it: a plain table pins its section headers. ⚠️ But
/// the pinned CAPSULE is not drawn here any more — `hidesWhenPinned`. The
/// inbox shows the stuck section's name as a leading item in the navigation
/// bar instead (the bar's top-left was empty, and a capsule hanging just
/// under it was a second header row), so this header fades out as it reaches
/// the line and the bar's item takes over. In the flow it is still the large
/// title it always was.
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
        pill.hidesWhenPinned = true
        pill.pinAsHeader(in: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    /// `leadsList` decides the header's top margin — see
    /// `SectionHeaderPillButton.setLeadsList`.
    func setTitle(_ title: String?, leadsList: Bool = true) {
        pill.setPillTitle(title)
        pill.setLeadsList(leadsList)
    }
}
