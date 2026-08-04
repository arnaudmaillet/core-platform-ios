import DesignSystem
import UIKit

/// The Following list's section header: the same `SectionHeaderPillButton` the
/// inbox and the compose picker wear, in the shape a collection view can use.
///
/// A reusable view with no background of its own — the pill IS the header, and
/// the rows scroll underneath it. The layout pins it to the visible bounds, so
/// it behaves like a plain table's pinned header without a band to pin.
final class ForYouSectionHeaderView: UICollectionReusableView {
    static let reuseID = "ForYouSectionHeaderView"

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

    func setTitle(_ title: String?) {
        pill.setPillTitle(title)
    }
}
