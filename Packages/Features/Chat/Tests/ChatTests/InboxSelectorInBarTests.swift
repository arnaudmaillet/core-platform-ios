import CoreNavigation
import DesignSystem
import Testing
import UIKit
@testable import Chat

/// **The Chats / Requests / Suggestions selector is in the bar, right of the
/// bell, as on For You (#2337, the owner 2026-11-12).** No band at the foot
/// any more: the tab bar alone.
@MainActor
struct InboxSelectorInBarTests {
    /// A page with a count on its segment.
    private final class Surface: UIViewController, InboxSurface {
        let category: MessagesCategory
        var chrome = InboxSurfaceChrome()
        var onChromeChange: ((InboxSurfaceChrome) -> Void)?
        func surfaceDidBecomeActive() {}
        init(_ category: MessagesCategory) {
            self.category = category
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        func publish(_ badge: Int) {
            chrome.badgeCount = badge
            onChromeChange?(chrome)
        }
    }

    private func inbox() -> (MessagesInboxViewController, [Surface]) {
        let surfaces = [Surface(.all), Surface(.requests), Surface(.suggestions)]
        return (MessagesInboxViewController(surfaces: surfaces), surfaces)
    }

    /// Loaded and laid out at an iPhone 17 Pro's width, so the selector is
    /// fitted to a real bar width.
    private func layOut(_ screen: MessagesInboxViewController) {
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
    }

    private func bell() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = "Bell"
        return item
    }

    /// `[bell][selector]`: the bell, the separator that keeps them two
    /// platters, then the selector — For You's recipe: a `.navigationTitle`
    /// strip in the item's platter, under a stable identifier, the three
    /// pages' titles in order.
    @Test func theLeadingGroupIsTheBellThenTheSelector() throws {
        let (screen, _) = inbox()
        let bell = bell()
        screen.setLeadingAccessoryItem(bell)
        layOut(screen)

        let leading = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(leading.count == 3)
        #expect(leading[0] === bell)
        #expect(leading[1].customView == nil && leading[1].identifier == nil, "a separator between the two")
        let item = leading[2]
        #expect(item.identifier == "messages.inbox.selector")
        let strip = try #require(item.customView as? PagedTabBar)
        #expect(strip === screen.debugSelector)
        #expect(strip.style == .navigationTitle)
        #expect(strip.hosting == .platter, "a capsule drawn inside the item's own glass")
        #expect(strip.currentTitles == ["Chats", "Requests", "Suggestions"])
        #expect(screen.navigationItem.titleView == nil, "the selector is not in the title slot")
    }

    /// ⚠️ ONE ITEM, ONE IDENTIFIER, WHATEVER THE COUNTS. A count widens its
    /// segment; the selector re-fits in place — the same item, around the
    /// same strip, under the same identifier (a re-minted item lost its strip
    /// on the simulator, `BarSelectorItem`).
    @Test func theSelectorsIdentifierIsStableAcrossACount() throws {
        let (screen, surfaces) = inbox()
        screen.setLeadingAccessoryItem(bell())
        layOut(screen)
        let before = try #require(screen.navigationItem.leftBarButtonItems?.last)
        let strip = try #require(before.customView as? PagedTabBar)
        let width = strip.intrinsicContentSize.width

        surfaces[1].publish(6)

        let after = try #require(screen.navigationItem.leftBarButtonItems?.last)
        #expect(after === before, "the selector's item was re-minted")
        #expect(after.identifier == before.identifier)
        #expect(after.customView === strip, "a new strip where the same one belongs")
        #expect(strip.intrinsicContentSize.width > width, "the count did not widen the selector")
        #expect(screen.navigationItem.leftBarButtonItems?.count == 3)
    }

    /// ⚠️ NO BAND AT THE FOOT, EVER: not on appearing, not after a search
    /// opened and closed. The tab bar controller's `bottomAccessory` is
    /// shell-wide; Messages leaves it alone (the profile keeps its own).
    @Test func noBottomAccessoryIsInstalled() {
        let (screen, _) = inbox()
        let tabs = UITabBarController()
        tabs.viewControllers = [UINavigationController(rootViewController: screen)]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(tabs.bottomAccessory == nil, "Messages put a band up")
        #expect(screen.navigationItem.leftBarButtonItems?.last?.identifier
            == MessagesInboxViewController.selectorItemID)

        let search = UISearchController()
        screen.willPresentSearchController(search)
        screen.willDismissSearchController(search)
        #expect(tabs.bottomAccessory == nil, "a search close put a band up")
    }

    /// The pager drives the selector and the selector drives the pager: a
    /// swipe that settles moves the pill, a tap on a segment moves the page.
    @Test func thePagerAndTheSelectorStayInStep() {
        let (screen, _) = inbox()
        screen.loadViewIfNeeded()
        let strip = screen.debugSelector

        screen.debugSettle(on: 2)
        #expect(strip.selectedIndex == 2, "a settled swipe left the pill behind")

        strip.debugSimulateTap(at: 1)
        #expect(screen.debugActiveIndex == 1, "a tap on Requests did not page")
        #expect(strip.selectedIndex == 1)
    }

    /// The width rule (#2337): never more than the room the bell leaves —
    /// 15pt when the titles fit, 13pt otherwise, a scroll past that — and
    /// never less than one bubble.
    @Test func theSelectorTakesNoMoreThanTheBarLeaves() {
        let (screen, surfaces) = inbox()
        screen.setLeadingAccessoryItem(bell())
        layOut(screen)
        surfaces[0].publish(99)
        surfaces[1].publish(43)

        let strip = screen.debugSelector
        let room = BarSelectorBudget(barWidth: 402,
                                     leadingWidths: [BarSelectorBudget.platter]).room
        #expect(strip.intrinsicContentSize.width <= room - strip.hosting.overhang * 2 + 0.5)
        #expect(strip.intrinsicContentSize.width >= strip.intrinsicContentSize.height)
        let fitsAtRegular = strip.preferredWidth(at: .regular) <= room - strip.hosting.overhang * 2 + 0.5
        #expect(strip.titleSize == (fitsAtRegular ? .regular : .compact))
    }
}
