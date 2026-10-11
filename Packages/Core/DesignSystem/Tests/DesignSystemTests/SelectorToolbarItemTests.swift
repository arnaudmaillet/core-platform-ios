import Testing
import UIKit
@testable import DesignSystem

/// The selector as a pushed screen's leading toolbar item — the pushed
/// profile's arrangement (#728), shared with the search results (#881).
@MainActor
struct SelectorToolbarItemTests {
    /// A window holding a stack, so `setToolbarHidden` has a bar to move.
    @MainActor
    private final class Stack {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let navigation = UINavigationController(rootViewController: UIViewController())

        init() {
            window.rootViewController = navigation
            window.makeKeyAndVisible()
        }
    }

    @Test("The strip is dressed for a bar item's platter, at its own width")
    func theStripIsDressedForAPlatter() {
        let strip = PagedTabBar(titles: ["Posts", "Users"], style: .navigationTitle)
        strip.fillsWidth = true
        let toolbar = SelectorToolbarItem(strip: strip)
        #expect(toolbar.item.customView === strip)
        #expect(strip.hosting == .platter, "glass inside the item's glass")
        #expect(strip.fillsWidth == false)
    }

    @Test("The strip leads the toolbar, with nothing after it")
    func theStripLeads() {
        let toolbar = SelectorToolbarItem(strip: PagedTabBar(titles: ["A", "B"], style: .navigationTitle))
        let items = toolbar.toolbarItems
        #expect(items.count == 2)
        #expect(items.first === toolbar.item)
        #expect(items.last?.customView == nil, "only space after the strip")
    }

    @Test("Shown for the screen coming in; put away when the next screen has no items")
    func hiddenWhenTheNextScreenHasNone() {
        let stack = Stack()
        let screen = UIViewController()
        let toolbar = SelectorToolbarItem(strip: PagedTabBar(titles: ["A", "B"], style: .navigationTitle))
        screen.toolbarItems = toolbar.toolbarItems
        stack.navigation.pushViewController(screen, animated: false)
        toolbar.show(for: screen, animated: false)
        #expect(stack.navigation.isToolbarHidden == false)

        stack.navigation.pushViewController(UIViewController(), animated: false)
        toolbar.hide(leaving: screen, animated: false)
        #expect(stack.navigation.isToolbarHidden, "an empty toolbar left over the next screen")
    }

    @Test("Left up for a next screen that brings items of its own")
    func keptForANextScreenWithItems() {
        let stack = Stack()
        let screen = UIViewController()
        let toolbar = SelectorToolbarItem(strip: PagedTabBar(titles: ["A", "B"], style: .navigationTitle))
        screen.toolbarItems = toolbar.toolbarItems
        stack.navigation.pushViewController(screen, animated: false)
        toolbar.show(for: screen, animated: false)

        let next = UIViewController()
        next.toolbarItems = [UIBarButtonItem(systemItem: .action)]
        stack.navigation.pushViewController(next, animated: false)
        toolbar.hide(leaving: screen, animated: false)
        #expect(stack.navigation.isToolbarHidden == false, "hid a bar the next screen owns")
    }
}
