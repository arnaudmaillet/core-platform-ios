import DesignSystem
import UIKit

/// The hero page's tab selector (#1651, slice #1653): ONE `PagedTabBar` — the
/// strip Messages wears (and For You did, until #2453) — kept in step with
/// the page's pager both ways, for the screen's whole life.
///
/// **Optional.** A page with one tab shows none: a strip with one segment is a
/// label pretending to be a control (the profile's rule, #631). The page kind
/// places it when it has more than one tab and removes it when one is left.
///
/// **Its home** (`Placement`):
/// - `.header` (#2475, the owner 2026-11-28): in the header at rest, where a
///   profile's action row stood (`headerSlot`), and in the navigation bar's
///   leading group once that slot has gone under the bar — right after the
///   back chevron or the bell, as the Messages inbox's (#2337). ONE strip
///   that moves (`moveIntoBar()`, `moveIntoHeader()`): the same page
///   selected, its own scroll kept, its scrub and its menus with it;
/// - `.toolbar`: the stack's toolbar, at the bottom leading corner
///   (`SelectorToolbarItem`) — a pushed screen's.
///
/// ⚠️ **THE BAR'S GROUPS ARE THE PAGE KIND'S TO WRITE**: this object moves
/// the strip and hands out its bar item (`barItem`); the page kind's bar
/// composer writes the leading group — after `moveIntoBar()`, before
/// `moveIntoHeader()`, so the strip is never in two places at once.
@MainActor
public final class HeroPageSelector {
    public enum Placement: Equatable, Sendable {
        /// The header at rest, the navigation bar's leading group past the
        /// threshold (#2475): one strip that moves.
        case header
        /// The stack's toolbar, at the bottom leading corner.
        case toolbar
    }

    public let bar: PagedTabBar
    public let placement: Placement
    /// The header's home for the strip (`.header`): the page kind's header
    /// holds it where its action row stood (`HeroPageViewController`).
    public let headerSlot = HeroSelectorSlot()
    /// The strip's bar item while it is in the navigation bar (`.header`,
    /// past the threshold) — a fresh item each time the strip comes into the
    /// bar (`BarSelectorItem.enterBar`), nil before the first time.
    public private(set) var barItem: BarSelectorItem?
    /// Whether the strip is in the navigation bar now (`.header`).
    public private(set) var isInBar = false
    /// The toolbar's item, once placed in the toolbar.
    public private(set) var toolbar: SelectorToolbarItem?
    public var item: UIBarButtonItem? { toolbar?.item }
    /// Whether the strip has a home.
    public private(set) var isPlaced = false
    /// Told when the strip gains or loses its home — the header shows its
    /// slot only while there is a strip to hold (`.header`).
    public var onPlacedChange: ((Bool) -> Void)?
    private let barItemID: String
    private let touchProbe: SelectorTouchProbe?

    /// - Parameters:
    ///   - barItemID: the strip's bar item's identifier, in the navigation
    ///     bar (`.header`).
    ///   - touchProbe: told when a finger is on the strip — the hero page
    ///     holds the stack's pans while one is.
    public init(
        bar: PagedTabBar, placement: Placement, barItemID: String = "heroPage.selector",
        touchProbe: SelectorTouchProbe? = nil
    ) {
        self.bar = bar
        self.placement = placement
        self.barItemID = barItemID
        self.touchProbe = touchProbe
        // Seven pages in a bar (the own profile's) are cut off: the cut side
        // fades (#2475), in the header as in the bar.
        if placement == .header { bar.fadesCutEdges = true }
    }

    /// Keeps the strip and `pager` in step, both ways: the lens tracks the
    /// finger on the pages (a fractional position every frame), the pill can
    /// be picked up to scrub the pages, and a tap on the tab already showing
    /// goes back to the top of it. `onSelect` is a tap's segment.
    public func bind<Tab: Equatable>(to pager: HeroPagePager<Tab>, onSelect: @escaping (Int) -> Void) {
        bar.addAction(
            UIAction { [weak bar] _ in
                guard let bar else { return }
                onSelect(bar.selectedIndex)
            },
            for: .valueChanged
        )
        bar.onReselect = { [weak pager] _ in pager?.scrollActivePageToTop() }
        pager.onProgress = { [weak bar] progress in bar?.setProgress(progress) }
        // The release hands over a velocity and the pager commits — including
        // the `onPageSettled` the page kind adopts its tab from, so a drag ends
        // exactly where a swipe does.
        bar.onScrub = { [weak pager] progress in pager?.scrub(to: progress) }
        bar.onScrubEnd = { [weak pager] velocity in pager?.settleAfterScrub(velocityInPages: velocity) }
    }

    /// Puts the strip on `index`, unless it is already there.
    ///
    /// ⚠️ `PagedTabBar` has no silent `select`: choosing a segment announces
    /// itself, so a scripted selection drives the same path a finger does. The
    /// guard is what keeps the echo from looping.
    public func select(_ index: Int) {
        guard bar.selectedIndex != index else { return }
        bar.select(index)
    }

    /// Gives the strip its home on `screen`, once: the header's slot
    /// (`.header`), or the stack's toolbar.
    public func place(on screen: UIViewController) {
        guard !isPlaced else { return }
        isPlaced = true
        touchProbe?.attach(to: bar)
        switch placement {
        case .header:
            headerSlot.host(bar)
        case .toolbar:
            let item = SelectorToolbarItem(strip: bar)
            toolbar = item
            screen.toolbarItems = item.toolbarItems
        }
        onPlacedChange?(true)
    }

    /// Takes the strip away — one tab left. A strip in the navigation bar
    /// leaves it with the page kind's next composition (`isInBar` is false
    /// from here).
    public func remove(from screen: UIViewController) {
        guard isPlaced else { return }
        isPlaced = false
        if placement == .header {
            isInBar = false
            barItem = nil
            bar.removeFromSuperview()
        }
        if toolbar != nil {
            toolbar = nil
            screen.toolbarItems = []
            if screen.navigationController?.topViewController === screen {
                screen.navigationController?.setToolbarHidden(true, animated: true)
            }
        }
        onPlacedChange?(false)
    }

    /// Takes the strip out of the header for the navigation bar (`.header`,
    /// past the threshold): its bar item, fresh, for the page kind to put in
    /// its leading group — which it writes NEXT. Nil without a strip placed.
    @discardableResult
    public func moveIntoBar() -> BarSelectorItem? {
        guard placement == .header, isPlaced else { return nil }
        if isInBar, let barItem { return barItem }
        isInBar = true
        let item: BarSelectorItem
        if let barItem {
            barItem.enterBar()
            item = barItem
        } else {
            bar.removeFromSuperview()
            item = BarSelectorItem(strip: bar, id: barItemID)
            barItem = item
        }
        return item
    }

    /// Puts the strip back in the header (`.header`, back above the
    /// threshold) — once the page kind has taken its item out of the bar.
    public func moveIntoHeader() {
        guard placement == .header, isInBar else { return }
        isInBar = false
        guard isPlaced else { return }
        headerSlot.host(bar)
    }

    /// Shows the stack's toolbar for `screen` — a pushed screen's strip rides
    /// the push or pop that brings it in.
    public func showToolbar(for screen: UIViewController, animated: Bool) {
        toolbar?.show(for: screen, animated: animated)
    }

    /// Puts the toolbar away as `screen` leaves.
    public func hide(leaving screen: UIViewController, animated: Bool) {
        toolbar?.hide(leaving: screen, animated: animated)
    }
}

/// The header's home for a hero page's selector (#2475): where a profile's
/// action row stood, the strip on the header's own flat grey capsule — the
/// quiet tray buttons' ground (`HeroTray.fill`), never glass: the header sits
/// on the page with nothing passing beneath it (`HeroTray`'s rule).
///
/// The strip spans it and scrolls inside when its titles need more room
/// (the cut side fading, `PagedTabBar.fadesCutEdges`). It keeps its height
/// when the strip leaves for the bar, so the header never moves under the
/// hand-off.
public final class HeroSelectorSlot: UIView {
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HeroTray.fill
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "heroPage.selectorSlot"
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    /// Whether the strip is in the header now.
    public var hostsStrip: Bool { subviews.contains { $0 is PagedTabBar } }

    /// Takes `strip` in: drawn on this capsule (`.container`: no glass of its
    /// own), spanning it, at its full width — no ceiling.
    func host(_ strip: PagedTabBar) {
        strip.removeFromSuperview()
        strip.hosting = .container
        strip.fillsCeiling = false
        strip.widthCeiling = nil
        strip.fillsWidth = true
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
