import DesignSystem
import UIKit

/// The hero page's tab selector (#1651, slice #1653): ONE `PagedTabBar` — the
/// strip For You and Messages wear — kept in step with the page's pager both
/// ways, and hosted at the foot of the screen for the screen's whole life.
///
/// **Optional.** A page with one tab shows none: a strip with one segment is a
/// label pretending to be a control (the profile's rule, #631). The page kind
/// places it when it has more than one tab and removes it when one is left.
///
/// **Two homes**, by where the screen is — and only its host can answer that
/// (a navigation root inside a tab bar and a pushed screen look the same from
/// inside, the profile's `ProfileTrayPlacement`):
/// - `.accessory`: the tab bar's `UITabAccessory` (`SelectorAccessory`), which
///   minimizes with the scroll — a tab root;
/// - `.toolbar`: the stack's toolbar, at the bottom leading corner
///   (`SelectorToolbarItem`) — a pushed screen.
///
/// ⚠️ THE ACCESSORY IS SHELL-WIDE: installed on appear, removed on disappear
/// (`install(on:)`, `hide(leaving:)`), or it floats over whatever is pushed on
/// top and over the next tab.
@MainActor
public final class HeroPageSelector {
    public enum Placement: Equatable, Sendable {
        case accessory
        case toolbar
    }

    public let bar: PagedTabBar
    public let placement: Placement
    /// The band, once placed as an accessory.
    public private(set) var accessory: SelectorAccessory?
    /// The toolbar's item, once placed in the toolbar.
    public private(set) var toolbar: SelectorToolbarItem?
    public var item: UIBarButtonItem? { toolbar?.item }
    /// Whether the strip has a home.
    public var isPlaced: Bool { accessory != nil || toolbar != nil }
    private let touchProbe: SelectorTouchProbe?

    /// - Parameter touchProbe: told when a finger is on the strip — the
    ///   profile holds its header's fade while one is.
    public init(bar: PagedTabBar, placement: Placement, touchProbe: SelectorTouchProbe? = nil) {
        self.bar = bar
        self.placement = placement
        self.touchProbe = touchProbe
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

    /// Gives the strip its home on `screen`, once.
    public func place(on screen: UIViewController) {
        guard !isPlaced else { return }
        touchProbe?.attach(to: bar)
        switch placement {
        case .accessory:
            accessory = SelectorAccessory(strip: bar)
        case .toolbar:
            let item = SelectorToolbarItem(strip: bar)
            toolbar = item
            screen.toolbarItems = item.toolbarItems
        }
    }

    /// Takes the strip away — one tab left.
    public func remove(from screen: UIViewController) {
        if let accessory {
            accessory.remove(from: screen.tabBarController, alongside: nil)
            self.accessory = nil
        }
        if toolbar != nil {
            toolbar = nil
            screen.toolbarItems = []
            if screen.navigationController?.topViewController === screen {
                screen.navigationController?.setToolbarHidden(true, animated: true)
            }
        }
    }

    /// Puts the band up as `screen` comes on — riding `coordinator` when a
    /// transition is running. It minimizes with the scroll as an accessory
    /// only: a pushed screen has no tab bar under it to collapse, and the
    /// behaviour is shell-wide.
    public func install(on screen: UIViewController, alongside coordinator: UIViewControllerTransitionCoordinator?) {
        accessory?.install(
            into: screen.tabBarController, owner: screen,
            minimizesOnScroll: placement == .accessory, alongside: coordinator
        )
    }

    /// Shows the stack's toolbar for `screen` — a pushed screen's strip rides
    /// the push or pop that brings it in.
    public func showToolbar(for screen: UIViewController, animated: Bool) {
        toolbar?.show(for: screen, animated: animated)
    }

    /// Takes the band down and puts the toolbar away as `screen` leaves.
    public func hide(leaving screen: UIViewController, animated: Bool,
                     alongside coordinator: UIViewControllerTransitionCoordinator?) {
        accessory?.remove(from: screen.tabBarController, alongside: coordinator)
        toolbar?.hide(leaving: screen, animated: animated)
    }
}
