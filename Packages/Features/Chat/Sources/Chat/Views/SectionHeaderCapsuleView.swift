import DesignSystem
import UIKit

/// The compose picker's section header: `SectionHeaderPillButton` in the shape
/// a collection view can use.
///
/// The pill itself — its glass, its metrics, its tap behaviour — lives in that
/// type, because the inbox's tables need the identical object inside a
/// `UITableViewHeaderFooterView` instead. This is a host, not a design.
final class SectionHeaderCapsuleView: UICollectionReusableView {
    /// Fires when the capsule is tapped. Re-assigned on every configure, since
    /// the view is reused across sections.
    var onTap: (() -> Void)? {
        get { pill.onTap }
        set { pill.onTap = newValue }
    }

    private let pill = SectionHeaderPillButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.pinAsHeader(in: self)
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
