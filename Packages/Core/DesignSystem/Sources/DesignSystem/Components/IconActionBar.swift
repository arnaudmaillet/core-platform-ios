import UIKit

/// A row of icons that **do something when tapped**, and stay nothing
/// afterwards.
///
/// **Why this is not `IconSelectorBar` with a different name.** That bar's whole
/// contract is *one of N is chosen*, and it announces on CHANGE:
/// `select(_:notify:)` compares against `selectedIndex` and stays silent when
/// they match. "Cut here" cannot be expressed that way — a second cut is a second
/// request at the same index, and the selector would swallow it. So the author
/// would be able to split a clip exactly once, and the failure would look like a
/// dead button rather than like a missing concept. An action has no state to
/// return to, which is why it needs its own control rather than a flag on that
/// one.
///
/// **What it borrows, deliberately.** The capsule, the 36pt segments, the 2pt
/// spacing and the tint behind an open item all come from `IconBarMetrics`,
/// because the two bars sit at opposite ends of the SAME toolbar and any
/// disagreement between them is visible at a glance.
///
/// ⚠️ **IT DOES NOT SCROLL, AND THAT IS A LIMIT RATHER THAN AN OMISSION.** The
/// selector scrolls because six editing modes do not fit a phone. A handful of
/// actions do; two do comfortably. A bar that outgrew its host would clip its
/// last icon in silence, so if one ever carries enough items to overflow it needs
/// the selector's scroller lifting into it — not a wider window.
///
/// ⚠️ **THE EFFECT IS SET IN `didMoveToWindow`, NOT IN `init`.** Materialising
/// glass in a property initialiser contacts the render server, which on a
/// headless CI simulator has stalled the main actor for tens of seconds. Six
/// components in this app state it the same way.
@MainActor
public final class IconActionBar: UIView {
    /// One tappable icon.
    ///
    /// The label is required rather than derived: "arrow.trianglehead.branch" is
    /// not a word a screen reader can say.
    public struct Item: Sendable, Equatable {
        public let symbolName: String
        public let accessibilityLabel: String

        public init(symbolName: String, accessibilityLabel: String) {
            self.symbolName = symbolName
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// An item was tapped. Fires EVERY time, including twice on the same index —
    /// which is the difference from a selector and the reason this type exists.
    public var onTap: ((Int) -> Void)?

    /// The host draws the capsule; this one draws none. See
    /// `IconSelectorBar.suppressesBackdrop` for what the doubled platter looks
    /// like.
    public var suppressesBackdrop: Bool = false {
        didSet {
            guard suppressesBackdrop != oldValue else { return }
            if suppressesBackdrop {
                capsule.effect = nil
            } else if window != nil {
                materialiseCapsule()
            }
            rowLeading?.constant = outerInset
            rowTrailing?.constant = -outerInset
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// The bar's own height, so a host can lay it out before it has items.
    public static var height: CGFloat { IconBarMetrics.capsuleHeight }

    private var outerInset: CGFloat { suppressesBackdrop ? 0 : IconBarMetrics.clearance }
    private var lensClearance: CGFloat { suppressesBackdrop ? 0 : IconBarMetrics.clearance }
    private var lensSide: CGFloat { IconBarMetrics.segmentSide - lensClearance * 2 }

    private var items: [Item]
    private let capsule = UIVisualEffectView(effect: nil)
    private let row = UIStackView()
    private let lens = UIView()
    private var buttons: [UIButton] = []
    private var rowLeading: NSLayoutConstraint?
    private var rowTrailing: NSLayoutConstraint?

    /// The item whose panel is standing open, if any — drawn with the selector's
    /// own tint so "this one is showing something" reads the same in both bars.
    private var activeIndex: Int?

    public init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        build()
        rebuildSegments()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Building

    private func build() {
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.clipsToBounds = true
        addSubview(capsule)

        lens.backgroundColor = IconBarMetrics.lensTint
        lens.isUserInteractionEnabled = false
        lens.isHidden = true
        lens.layer.cornerCurve = .continuous
        capsule.contentView.addSubview(lens)

        row.axis = .horizontal
        row.spacing = IconBarMetrics.interSegmentSpacing
        row.alignment = .fill
        // ⚠️ `.fill` WITH FIXED SEGMENTS, NEVER `.fillEqually` — the selector
        // records what equal distribution costs: the segments stretch to whatever
        // width the bar is given while the lens is placed on a fixed stride, and
        // the two drift apart by more at every index.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(row)

        let leading = row.leadingAnchor.constraint(
            equalTo: capsule.contentView.leadingAnchor, constant: outerInset
        )
        let trailing = row.trailingAnchor.constraint(
            equalTo: capsule.contentView.trailingAnchor, constant: -outerInset
        )
        rowLeading = leading
        rowTrailing = trailing
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading,
            trailing,
            row.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor)
        ])
    }

    private func rebuildSegments() {
        for button in buttons {
            row.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = items.enumerated().map { index, item in
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            configuration.image = UIImage(systemName: item.symbolName)
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = item.accessibilityLabel
            button.addAction(
                UIAction { [weak self] _ in self?.onTap?(index) }, for: .primaryActionTriggered
            )
            row.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: IconBarMetrics.segmentSide).isActive = true
            return button
        }
        if let activeIndex, !items.indices.contains(activeIndex) { self.activeIndex = nil }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    public func setItems(_ newItems: [Item]) {
        guard newItems != items else { return }
        items = newItems
        rebuildSegments()
    }

    // MARK: - What an item can do right now

    /// Greys an item out, and stops it answering.
    ///
    /// ⚠️ **AN ACTION THAT CANNOT ACT SAYS SO — IT DOES NOT SIT THERE LOOKING
    /// LIVE.** A split at a moment where either half would fall under the floor
    /// is refused by the arithmetic and returns the timeline unchanged; a button
    /// that stays lit for that tap is the "control that reaches nothing" this
    /// editor has already removed twice, wearing a third sleeve.
    public func setEnabled(_ enabled: Bool, at index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons[index].isEnabled = enabled
        // ⚠️ THE ALPHA IS NOT DECORATION. `UIButton.Configuration.plain()` on a
        // disabled button dims its own tint, but this bar's icons are drawn in
        // the host's tint over glass, and the dimming is not enough to read as
        // "off" against it — measured against the toolbar's own platter.
        buttons[index].alpha = enabled ? 1 : 0.35
    }

    public func isEnabled(at index: Int) -> Bool {
        buttons.indices.contains(index) ? buttons[index].isEnabled : false
    }

    /// Marks the one item whose panel is open, or `nil` for none.
    public func setActive(_ index: Int?) {
        activeIndex = index.flatMap { items.indices.contains($0) ? $0 : nil }
        for (at, button) in buttons.enumerated() {
            button.accessibilityTraits = at == activeIndex ? [.button, .selected] : [.button]
        }
        setNeedsLayout()
    }

    public var activeItem: Int? { activeIndex }

    // MARK: - Layout

    public override var intrinsicContentSize: CGSize {
        CGSize(
            width: IconBarMetrics.intrinsicWidth(count: items.count, outerInset: outerInset),
            height: IconBarMetrics.capsuleHeight
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // ⚠️ SHAPE BEFORE MATERIAL. `didMoveToWindow` can land before the first
        // layout pass has given the capsule real bounds, and a glass effect
        // switched on over a zero-radius layer draws one frame of hard corners.
        capsule.layer.cornerCurve = .continuous
        capsule.layer.cornerRadius = bounds.height / 2
        lens.layer.cornerRadius = lensSide / 2
        guard let activeIndex, buttons.indices.contains(activeIndex) else {
            lens.isHidden = true
            return
        }
        lens.isHidden = false
        let stride = IconBarMetrics.segmentSide + IconBarMetrics.interSegmentSpacing
        let centring = (IconBarMetrics.segmentSide - lensSide) / 2
        lens.frame = CGRect(
            x: outerInset + centring + CGFloat(activeIndex) * stride,
            y: (bounds.height - lensSide) / 2,
            width: lensSide, height: lensSide
        )
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, capsule.effect == nil, !suppressesBackdrop else { return }
        materialiseCapsule()
    }

    private func materialiseCapsule() {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        capsule.effect = glass
    }
}

#if DEBUG
extension IconActionBar {
    /// ⚠️ **`public`, LIKE `PagedTabBar`'S — BECAUSE THE TESTS THAT MATTER MOST
    /// ARE THE HOST'S.** Whether a tap on the scissors reaches the stored
    /// timeline is an Upload question, and Upload imports this module ordinarily
    /// rather than `@testable`. DEBUG-only, so nothing ships with it.
    public func debugTap(_ index: Int) {
        guard buttons.indices.contains(index), buttons[index].isEnabled else { return }
        buttons[index].sendActions(for: .primaryActionTriggered)
    }

    /// Internal for tests: where the open-panel tint is, or nil when nothing is.
    public var debugLensFrame: CGRect? { lens.isHidden ? nil : lens.frame }

    public var debugSymbols: [String] { items.map(\.symbolName) }
}
#endif
