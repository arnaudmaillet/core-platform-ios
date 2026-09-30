import UIKit

/// A collection view's pinning section header: `SectionHeaderPillButton` in
/// the shape a collection view can use.
///
/// The pill itself — its glass, its metrics, its tap behaviour — lives in that
/// type, because the inbox's tables need the identical object inside a
/// `UITableViewHeaderFooterView` instead. And what the pill SAYS is the app's
/// one section title (`SectionTitleView`). This is a host, not a design.
public final class SectionHeaderCapsuleView: UICollectionReusableView {
    /// Fires when the capsule is tapped. Re-assigned on every configure, since
    /// the view is reused across sections.
    public var onTap: (() -> Void)? {
        get { pill.onTap }
        set { pill.onTap = newValue }
    }

    private let pill = SectionHeaderPillButton()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        pill.pinAsHeader(in: self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    public override func layoutSubviews() {
        // Laid inside a section's content insets or edge to edge, the title
        // stands on the surface's title line.
        pill.alignToSurface()
        super.layoutSubviews()
    }

    /// `count` is the secondary number after the title, zero for none — see
    /// `SectionHeaderPillButton.setCount`.
    public func setTitle(_ title: String?, count: Int = 0) {
        pill.setPillTitle(title)
        pill.setCount(count)
    }

    #if DEBUG
    /// The pill this header hosts — what a test reads its shape and count off.
    public var debugPill: SectionHeaderPillButton { pill }
    #endif
}
