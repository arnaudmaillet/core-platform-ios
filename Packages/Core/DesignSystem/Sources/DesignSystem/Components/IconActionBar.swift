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

    /// Who draws the capsule — see `SelectorHosting` for the one rule the three
    /// selectors share, and `IconSelectorBar.hosting` for what a doubled platter
    /// looks like.
    public var hosting: SelectorHosting = .standalone {
        didSet {
            guard hosting != oldValue else { return }
            if !hosting.drawsBackdrop {
                capsule.effect = nil
            } else if window != nil {
                materialiseCapsule()
            }
            applyHosting()
        }
    }

    /// The bar's own height, so a host can lay it out before it has items.
    public static var height: CGFloat { IconBarMetrics.capsuleHeight }

    /// How far the visible capsule reaches beyond this view, per axis — and so,
    /// how far inside the capsule the row of segments begins. The capsule is
    /// laid out at THAT size, so a platter's own ring is where the first
    /// segment's clearance comes from. Measured once the bar is in a platter
    /// and in a window; the hosting's stated number until then.
    private var platterOverhang: CGSize?
    private var overhangX: CGFloat { platterOverhang?.width ?? hosting.overhang }
    private var overhangY: CGFloat { platterOverhang?.height ?? hosting.overhang }
    /// The pill's clearance inside its segment: the visible clearance less what
    /// the ring above and below already supplies. NEGATIVE in a ring deeper
    /// than the clearance — the pill then reaches past the segment, so that it
    /// still stands the same 4pt off the glass the viewer sees.
    private var lensClearance: CGFloat { IconBarMetrics.clearance - overhangY }
    private var lensSide: CGFloat { IconBarMetrics.segmentSide - lensClearance * 2 }

    private var items: [Item]
    private let capsule = UIVisualEffectView(effect: nil)
    private let row = UIStackView()
    private let lens = UIView()
    private var buttons: [UIButton] = []
    private var rowLeading: NSLayoutConstraint?
    private var rowTrailing: NSLayoutConstraint?
    private var rowTop: NSLayoutConstraint?
    private var rowBottom: NSLayoutConstraint?
    /// The capsule's four edges, whose constants ARE the overhang.
    private var capsuleEdges: [NSLayoutConstraint] = []

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
            equalTo: capsule.contentView.leadingAnchor, constant: overhangX
        )
        let trailing = row.trailingAnchor.constraint(
            equalTo: capsule.contentView.trailingAnchor, constant: -overhangX
        )
        rowLeading = leading
        rowTrailing = trailing
        // ⚠️ THE CAPSULE IS THE VISIBLE ONE, NOT THIS VIEW. Inside a platter it
        // reaches `overhang` beyond every edge of the view, so that its clip —
        // and the row inside it — end where the viewer sees the glass end
        // rather than 4pt short of it. This view does not clip, so the reach is
        // real; the capsule does, at the visible capsule's own radius.
        capsuleEdges = [
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -overhangX),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: overhangX),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: -overhangY),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: overhangY)
        ]
        // The same on the vertical axis: the icons stay in this view's rect,
        // and a platter's capsule stands `overhangY` above and below them.
        let top = row.topAnchor.constraint(equalTo: capsule.contentView.topAnchor, constant: overhangY)
        let bottom = row.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor, constant: -overhangY)
        rowTop = top
        rowBottom = bottom
        NSLayoutConstraint.activate(capsuleEdges + [leading, trailing, top, bottom])
    }

    /// Re-states every constant that follows from the hosting: the capsule's
    /// reach beyond the view and the row's inset inside it. The lens is placed
    /// from the same numbers on the next layout pass.
    private func applyHosting() {
        for (edge, reach) in zip(capsuleEdges, [-overhangX, overhangX, -overhangY, overhangY]) {
            edge.constant = reach
        }
        rowLeading?.constant = overhangX
        rowTrailing?.constant = -overhangX
        rowTop?.constant = overhangY
        rowBottom?.constant = -overhangY
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Takes the platter's real reach once there is one to measure, and lays
    /// the capsule out against it. Guarded on change, or this would re-state
    /// its constraints every pass and never settle.
    private func measurePlatterIfHosted() {
        let measured = hosting == .platter ? SelectorHosting.measuredPlatterOverhang(around: self) : nil
        if hosting == .platter, window != nil {
            remeasure.arm { [weak self] in self?.measurePlatterIfHosted() }
        } else {
            remeasure.reset()
        }
        guard measured != platterOverhang else { return }
        platterOverhang = measured
        applyHosting()
    }

    /// The re-asks that land the platter's true reach — see
    /// `PlatterRemeasureSchedule` for why one measurement is not enough.
    private let remeasure = PlatterRemeasureSchedule()

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
            width: IconBarMetrics.intrinsicWidth(count: items.count),
            height: IconBarMetrics.capsuleHeight
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        measurePlatterIfHosted()
        // ⚠️ SHAPE BEFORE MATERIAL. `didMoveToWindow` can land before the first
        // layout pass has given the capsule real bounds, and a glass effect
        // switched on over a zero-radius layer draws one frame of hard corners.
        //
        // The CAPSULE's height, not this view's: inside a platter the two differ
        // by the overhang, and the radius has to be the visible capsule's.
        capsule.layer.cornerCurve = .continuous
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        lens.layer.cornerRadius = lensSide / 2
        guard let activeIndex, buttons.indices.contains(activeIndex) else {
            lens.isHidden = true
            return
        }
        lens.isHidden = false
        let stride = IconBarMetrics.segmentSide + IconBarMetrics.interSegmentSpacing
        let centring = (IconBarMetrics.segmentSide - lensSide) / 2
        // In the capsule's own space, where the lens lives: the pill stands
        // `SelectorCapsuleMetrics.clearance` off the visible edge on every host,
        // as the overhang and the clearance inside the segment between them.
        // Square, from the vertical ring; a ring half a point deeper at the ends
        // than above is a half point nobody sees.
        lens.frame = CGRect(
            x: overhangX + centring + CGFloat(activeIndex) * stride,
            y: (capsule.bounds.height - lensSide) / 2,
            width: lensSide, height: lensSide
        )
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // A bar that leaves its window starts its platter measurement over
        // when it comes back — the next host may be a different ring.
        if window == nil { remeasure.reset() }
        guard window != nil, capsule.effect == nil, hosting.drawsBackdrop else { return }
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

    /// Internal for tests: where the open-panel tint is, or nil when nothing is —
    /// in the CAPSULE's space, which inside a platter reaches beyond this view.
    public var debugLensFrame: CGRect? { lens.isHidden ? nil : lens.frame }

    public var debugHasCapsuleMaterial: Bool { capsule.effect != nil }

    public var debugSymbols: [String] { items.map(\.symbolName) }
}
#endif
