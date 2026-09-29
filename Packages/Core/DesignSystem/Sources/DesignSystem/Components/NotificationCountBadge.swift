import UIKit

/// A count of what is new, drawn the way the app's notification badges are:
/// white digits on a notification-red capsule, a circle at one digit and a
/// longer pill at two.
///
/// ```
///   Friends                     (3) ›      ← SectionLinkHeaderView
///   New (23)                               ← SectionHeaderPillButton
/// ```
///
/// Extracted (2026-09-29) so the count on a section LINK (For You's Friends
/// and Following headers) and the count on the section it opens (the pushed
/// list's "New" header) are one object: the same number arriving at two
/// places should not look like two different numbers.
///
/// Zero hides the badge — "nothing new" is said by the absence of a count,
/// never by a "0".
///
/// ⚠️ **The capsule is a SHAPE LAYER, not `backgroundColor` + a corner
/// radius.** The badge rides inside a glass button (the pinned section
/// header), and glass has been measured repainting a subview's
/// `backgroundColor` with its own corner (`glass-paints-background-color`,
/// the author pill's square plate). A path the view owns cannot be re-shaped
/// from outside. The red is resolved per appearance by hand for the same
/// reason a semantic colour is never trusted inside glass.
@MainActor
public final class NotificationCountBadge: UIView {
    /// The capsule's height — also its minimum width, so one digit draws a
    /// circle.
    public static let height: CGFloat = 22
    /// Digits to capsule edge.
    private static let horizontalPadding: CGFloat = 7

    private let label = UILabel()
    private let fill = CAShapeLayer()

    /// The number shown. Zero hides the badge.
    public private(set) var count = 0

    /// What the badge reads — "99+" past 99 — or nil while hidden.
    public var text: String? { isHidden ? nil : label.text }

    public init() {
        super.init(frame: .zero)
        layer.addSublayer(fill)
        label.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold
        )
        // White in both appearances, on notification red — the tab badges'
        // own pairing (a semantic colour here has vanished before, see
        // `PagedTabBar`'s badge).
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        isHidden = true
        isUserInteractionEnabled = false
        // The count is read as part of whatever it is attached to — the host
        // says "23 new", the badge alone says nothing to VoiceOver.
        isAccessibilityElement = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (badge: NotificationCountBadge, _: UITraitCollection) in
            badge.paintFill()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Past 99 it reads "99+": a count is read at a glance, and a fourth digit
    /// is a number nobody acts on differently.
    public func setCount(_ count: Int) {
        self.count = max(0, count)
        label.text = self.count > 99 ? "99+" : String(self.count)
        isHidden = self.count == 0
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The size the badge draws at for its current count.
    public override var intrinsicContentSize: CGSize {
        let digits = label.intrinsicContentSize.width
        return CGSize(
            width: max(Self.height, ceil(digits) + Self.horizontalPadding * 2),
            height: Self.height
        )
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    public override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        // A standalone layer animates its path and colour implicitly; the
        // badge takes its size in the same frame its count changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        paintFill()
        CATransaction.commit()
    }

    private func paintFill() {
        fill.fillColor = UIColor.systemRed.resolvedColor(with: traitCollection).cgColor
    }
}
