import UIKit

/// A list's stuck section, named in a navigation bar — the words a pinned
/// `SectionHeaderPillButton` capsule would wear ("New 8": the title, the count
/// in the secondary colour), as a bar item's custom view. The Messages inbox
/// puts it after the bell (#1301), and its section headers hide once pinned
/// (`hidesWhenPinned`) so the name is said once.
///
/// The bar draws the glass around it, as it does around every item: this is
/// only the run. ⚠️ A CUSTOM VIEW, BECAUSE IT GIVES WAY: a title item cannot
/// truncate — a run that does not fit sends the whole group behind a `•••` —
/// while this one takes what the bar leaves it and truncates its title in it
/// (the `SnapBarDayPill` precedent, #757).
///
/// ⚠️ A CONTROL BUILT FROM A SUBVIEW, NOT A `UIButton.Configuration`: a
/// configuration button answers a stale width while it re-renders on a
/// deferred pass, and the bar measured this item at a bare 44pt circle with
/// only the count in it (the `WalletBadgeButton` finding). And the bar freezes
/// an item's width when the item is made, so a host re-mints the item when
/// `intrinsicContentSize` changes width.
public final class SectionTitleBarButton: UIControl {
    /// Fires when the item is tapped — what the hidden header's pill took.
    public var onTap: (() -> Void)?

    private let titleView = SectionTitleView(embeddedStyle: .compact)

    public init() {
        super.init(frame: .zero)
        // The run is drawn, not touched: the whole item is the control.
        titleView.isUserInteractionEnabled = false
        titleView.isAccessibilityElement = false
        titleView.accessibilityElementsHidden = true
        addSubview(titleView)
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        // 999, never required: the bar's item wrapper pins its own height.
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The section's title and its count; zero draws no count.
    public func setSection(title: String, count: Int) {
        let content = SectionTitleView.Content(title: title, newCount: count)
        guard content != titleView.content else { return }
        titleView.content = content
        accessibilityLabel = title
        accessibilityValue = content.countAccessibilityValue
        accessibilityHint = "Scrolls to the \(title) section"
        invalidateIntrinsicContentSize()
        frame.size = intrinsicContentSize
        setNeedsLayout()
    }

    public override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    /// Dims while a finger is down, as a bar item does.
    public override var isHighlighted: Bool {
        didSet { titleView.alpha = isHighlighted ? 0.5 : 1 }
    }

    /// The title shown.
    public var title: String? { titleView.content.title }
    /// The count shown, nil while none shows.
    public var countText: String? { titleView.content.count }

    /// The bar's standard item height.
    private static let height: CGFloat = 36
    /// The pinned capsule's own padding, so the run sits in the bar's glass
    /// as it sat in the capsule.
    private static let insets = SectionHeaderPillButton.Metrics.textInsets

    public override var intrinsicContentSize: CGSize {
        CGSize(
            width: ceil(titleView.intrinsicContentSize.width + Self.insets.leading + Self.insets.trailing),
            height: Self.height
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        titleView.frame = CGRect(
            x: Self.insets.leading, y: 0,
            width: max(0, bounds.width - Self.insets.leading - Self.insets.trailing),
            height: bounds.height
        )
    }
}
