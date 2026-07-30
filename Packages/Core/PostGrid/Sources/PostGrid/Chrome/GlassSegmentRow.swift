import DesignSystem
import UIKit

/// A row of equal-weight selectable segments with **no track, no dividers,
/// no gray chrome, and no material of its own** — selection reads through
/// weight and tint alone (filled symbol variants for icon segments, bold
/// labels for text ones).
///
/// Designed to live inside the navigation controller's native toolbar as a bar
/// item's custom view (the profile's filter tray). The Liquid Glass capsule
/// around it belongs to the BAR: the iOS 26 toolbar composites every item
/// through its visual provider (`ToolbarVisualProvider.RootView`) with the
/// system's own neutral glass capsule — adding a `UIGlassEffect` here stacks a
/// second material inside that capsule and renders as a dark "double bubble"
/// ring (the same trap `ProfileViewController.updateActionBarItem` documents
/// for nav-bar items). Bar items size custom views by intrinsic content size,
/// so the row reports its fitted size and invalidates it when a selection
/// changes label weight.
///
/// Outside a bar there is no such capsule and the row renders bare — that host
/// must supply exactly one, via `GlassCapsule.wrap(_:)`.
public final class GlassSegmentRow: UIView {
    public enum Segment {
        case title(String)
        case symbol(name: String, accessibilityLabel: String)
    }

    public var onSelect: ((Int) -> Void)?
    public private(set) var selectedIndex = 0
    private let segments: [Segment]
    private var buttons: [UIButton] = []
    /// Per-title width constraints, kept so a text-size change updates them
    /// instead of adding a conflicting second set. Keyed by segment index.
    private var titleWidths: [Int: NSLayoutConstraint] = [:]
    private let row = UIStackView()
    /// The stack's 6pt insets inside the glass capsule, both sides.
    private static let contentPadding: CGFloat = 12

    public init(segments: [Segment]) {
        self.segments = segments
        super.init(frame: .zero)

        row.axis = .horizontal
        row.distribution = .fill
        buttons = segments.enumerated().map { index, segment in
            let button = UIButton(type: .system)
            button.configuration = .plain()
            // Same rule as GlassMenuButton: `.plain()` still carries a
            // background the highlight pass fills gray over our glass —
            // strip it and re-strip on every state update.
            button.configuration?.background = .clear()
            button.configurationUpdateHandler = { button in
                var configuration = button.configuration
                configuration?.background = .clear()
                button.configuration = configuration
                button.alpha = button.isHighlighted ? 0.65 : 1
            }
            // Tighter than a free-floating tray would be: both capsules plus
            // the toolbar's own margins must fit one compact-width bar.
            var insets = NSDirectionalEdgeInsets(top: 12, leading: 9, bottom: 12, trailing: 9)
            if case .symbol(_, let label) = segment {
                button.accessibilityLabel = label
                insets.leading = 7
                insets.trailing = 7
            }
            button.configuration?.contentInsets = insets
            // A title must never be the thing that yields when the row is
            // short of space: better the capsule grows than a label truncates.
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.addAction(UIAction { [weak self] _ in self?.select(index, notify: true) }, for: .primaryActionTriggered)
            row.addArrangedSubview(button)
            return button
        }
        row.constrain(in: self) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 6)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -6)
        }
        resizeTitles()
        applySelection()

        // A title's width is a MEASUREMENT of a font, and its `attributedTitle`
        // bakes a resolved font — neither of which follows a text-size change on
        // its own (`adjustsFontForContentSizeCategory` does not reach into a
        // button configuration's attributed title). Left alone, bumping Dynamic
        // Type rescales nothing here, and once the widths and the fonts disagree
        // a segment clips its own label. Re-measure and re-title together.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.resizeTitles()
            self.applySelection()
        }
    }

    /// Gives each title button a width FLOOR equal to its semibold measurement,
    /// and lets intrinsic content size take over from there.
    ///
    /// Two requirements pull in opposite directions here, and `>=` is what
    /// satisfies both.
    ///
    /// *Stability.* Selection toggles the weight regular↔semibold, and semibold
    /// is wider. Sizing purely on intrinsic content would therefore re-measure
    /// the whole capsule on every tap — visible jitter, and inside the profile's
    /// toolbar (which measures custom views by intrinsic size alone) enough to
    /// wrap the bar. Pinning the floor to the SEMIBOLD width means the selected
    /// and unselected states resolve to the same width, because the floor is the
    /// larger of the two either way.
    ///
    /// *No clipping, ever.* An exact `==` width is a promise that the
    /// measurement can never be short of what the label needs — and a bare
    /// `size(withAttributes:)` against the label's real layout leaves at most a
    /// point of slack once `ceil` has rounded, before any kerning or font
    /// fallback is accounted for. With `>=` a label that needs more simply gets
    /// more; the floor stops mattering and nothing truncates. Combined with
    /// required horizontal compression resistance, no amount of pressure from
    /// the enclosing stack can squeeze a title either.
    ///
    /// Constraints are retained and updated in place rather than re-created: two
    /// width constraints on one button is an unsatisfiable layout, and which one
    /// UIKit breaks is not yours to choose.
    private func resizeTitles() {
        let bold = UIFont.preferredFont(forTextStyle: .subheadline, weight: .semibold)
        for (index, segment) in segments.enumerated() {
            guard case .title(let title) = segment else { continue }
            let floorWidth = ceil((title as NSString).size(withAttributes: [.font: bold]).width) + 18
            if let existing = titleWidths[index] {
                existing.constant = floorWidth
            } else {
                let constraint = buttons[index].widthAnchor
                    .constraint(greaterThanOrEqualToConstant: floorWidth)
                constraint.isActive = true
                titleWidths[index] = constraint
            }
        }
        invalidateIntrinsicContentSize()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var intrinsicContentSize: CGSize {
        // Measured off the inner stack — fitting `self` would consult this
        // very property and recurse.
        let fitted = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: fitted.width + Self.contentPadding, height: fitted.height)
    }

    /// `notify: false` mirrors external state (a settled swipe) without
    /// echoing the change back.
    public func select(_ index: Int, notify: Bool) {
        guard buttons.indices.contains(index) else { return }
        let changed = index != selectedIndex
        selectedIndex = index
        applySelection()
        if notify, changed { onSelect?(index) }
    }

    private func applySelection() {
        for (index, button) in buttons.enumerated() {
            let isSelected = index == selectedIndex
            let color: UIColor = isSelected ? .label : .secondaryLabel
            switch segments[index] {
            case .title(let title):
                button.configuration?.attributedTitle = AttributedString(
                    title,
                    attributes: AttributeContainer([
                        .font: UIFont.preferredFont(
                            forTextStyle: .subheadline,
                            weight: isSelected ? .semibold : .regular
                        ),
                        .foregroundColor: color
                    ])
                )
            case .symbol(let name, _):
                // Selection = the filled variant, when the symbol has one.
                let symbol = isSelected ? (UIImage(systemName: name + ".fill") ?? UIImage(systemName: name)) : UIImage(systemName: name)
                button.configuration?.image = symbol
                button.tintColor = color
            }
            button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
            // Asserted, not assumed. Selection is the one place that touches
            // every segment, so it is the natural place to guarantee that no
            // segment is left invisible by anything else — a stuck highlight, an
            // interrupted touch, a transition that fiddled with the subtree.
            // Cheap, idempotent, and it makes "all three are visible" a property
            // of this method rather than a hope.
            button.isHidden = false
            if !button.isHighlighted { button.alpha = 1 }
        }
        // Weight changes nudge the fitted width; the bar re-measures custom
        // views through intrinsic size only.
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Drop-down variant

/// A circular drop-down bubble reduced to its icon: the `UIMenu` is the whole
/// selector (single-selection, system checkmark on the active option —
/// `.singleSelection` manages that state, no button mirroring involved), and
/// the bubble shows only the active option's glyph. The owner swaps that glyph
/// in the action handler.
///
/// Like `GlassSegmentRow`, this view carries NO material of its own: the
/// toolbar's visual provider wraps the item in the system's Liquid Glass
/// capsule, and a square item's capsule IS a circle. A `UIGlassEffect` here
/// renders a second lens inside that capsule — the dark "double bubble" ring.
public final class GlassMenuButton: UIView {
    public let button = UIButton(type: .system)
    /// The bubble's diameter: fixed at init from the LARGEST glyph plus the
    /// tray's 12pt breathing room per side — the same vertical rhythm as
    /// `GlassSegmentRow`'s rows, so the bubble matches the capsule's height.
    /// One diameter for every option: swapping icons never reflows the bar,
    /// and width == height keeps the system capsule a true circle.
    private let diameter: CGFloat

    /// `menu` should carry `.singleSelection` and one `.on` action — the
    /// button seeds its glyph from it.
    public init(menu: UIMenu, accessibilityLabel: String) {
        // The glyph is the button's whole content (no insets), so the fitted
        // size is the raw symbol; measure every option before super.init.
        let probe = UIButton(type: .system)
        probe.configuration = .plain()
        probe.configuration?.contentInsets = .zero
        let actions = menu.children.compactMap { $0 as? UIAction }
        var largestGlyph: CGFloat = 0
        for action in actions {
            probe.configuration?.image = action.image
            let fitted = probe.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            largestGlyph = max(largestGlyph, max(fitted.width, fitted.height))
        }
        diameter = ceil(largestGlyph) + 24
        super.init(frame: .zero)

        button.configuration = .plain()
        button.configuration?.contentInsets = .zero
        // `.plain()` is NOT background-free: it keeps a background
        // configuration that the menu-primary-action styling and the
        // highlight pass fill with a gray disc — visibly layered over the
        // glass. Strip it, and keep it stripped across every state update
        // (the handler runs on highlight/menu-open, which would otherwise
        // re-inject the fill); the pressed cue becomes a plain alpha dip so
        // the bar's system capsule stays the only material in the bubble.
        button.configuration?.background = .clear()
        button.configurationUpdateHandler = { button in
            var configuration = button.configuration
            configuration?.background = .clear()
            button.configuration = configuration
            button.alpha = button.isHighlighted ? 0.65 : 1
        }
        button.tintColor = .label
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = accessibilityLabel
        if let selected = actions.first(where: { $0.state == .on }) ?? actions.first {
            button.configuration?.image = selected.image
            button.accessibilityValue = selected.title
        }
        // The button fills the bubble (the whole circle is the hit target);
        // its configuration centers the lone glyph.
        button.pin(to: self)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var intrinsicContentSize: CGSize {
        CGSize(width: diameter, height: diameter)
    }
}

private extension UIFont {
    /// The largest this row's titles may scale to.
    ///
    /// A capsule of three fixed titles sitting beside a circular menu bubble has
    /// a hard width ceiling — the tray spans the screen's margins and no more. At
    /// the accessibility text sizes the untruncated titles need ~170pt EACH,
    /// roughly double what the row can offer, so something has to give and the
    /// only thing that can is the glyph size. Capping is what iOS itself does for
    /// bar chrome (tab bar labels and navigation titles both stop growing), and
    /// it is strictly better than the alternative: a clipped label is unreadable,
    /// while a capped one is merely smaller than the user asked for. Measured to
    /// fit all three titles at every category up to and including the
    /// accessibility sizes.
    static let segmentTitleMaximumPointSize: CGFloat = 20

    /// A weighted, Dynamic-Type-scaled font for `style`, scaled exactly ONCE and
    /// capped.
    ///
    /// The `compatibleWith:` lookup is load-bearing: `preferredFont(forTextStyle:)`
    /// on its own returns a size that is ALREADY scaled for the current category,
    /// and handing that to `scaledFont(for:)` scales it a second time. That double
    /// scaling is what drove the titles to ~170pt at accessibility sizes and made
    /// them clip. Asking for the size at the `.large` (default) category gives the
    /// unscaled baseline these metrics expect.
    static func preferredFont(forTextStyle style: TextStyle, weight: Weight) -> UIFont {
        let unscaled = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let base = UIFont.systemFont(ofSize: unscaled, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(
            for: base, maximumPointSize: segmentTitleMaximumPointSize
        )
    }
}
