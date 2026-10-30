import CoreNavigation
import Testing
import UIKit
@testable import Chat

/// **The inbox header's injected items — the shell's bell and balance.**
///
/// Items the shell injects are held by the screen and composed into its bar:
/// `[bell] … [coins]`, the search stacked under the bar. These inboxes have
/// no search composed, so no field (`InboxSystemSearchTests` pins the one
/// with search).
@MainActor
struct InboxHeaderAccessoryTests {
    /// The thinnest surface the container accepts: one page, no data.
    private final class BlankSurface: UIViewController, InboxSurface {
        let category: MessagesCategory = .all
        let chrome = InboxSurfaceChrome()
        var onChromeChange: ((InboxSurfaceChrome) -> Void)?
        func surfaceDidBecomeActive() {}
    }

    /// A page with something new on it.
    private final class CountingSurface: UIViewController, InboxSurface {
        let category: MessagesCategory = .all
        var chrome: InboxSurfaceChrome
        var onChromeChange: ((InboxSurfaceChrome) -> Void)?
        func surfaceDidBecomeActive() {}
        init(badge: Int) {
            var chrome = InboxSurfaceChrome()
            chrome.badgeCount = badge
            self.chrome = chrome
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        func publish(_ badge: Int) {
            chrome.badgeCount = badge
            onChromeChange?(chrome)
        }
    }

    /// ⚠️ LOADED, NEVER SHOWN, STILL COUNTED (#748): the shell loads the
    /// inbox at launch so the Messages tab item wears its badge before the tab
    /// is ever opened — which only works if a loaded inbox publishes its sum
    /// with no window and no appearance.
    @Test func aLoadedInboxPublishesItsTotalWithoutAppearing() {
        let surface = CountingSurface(badge: 3)
        let screen = MessagesInboxViewController(surfaces: [surface])
        var totals: [Int] = []
        screen.onTotalNewCountChange = { totals.append($0) }
        screen.loadViewIfNeeded()
        surface.publish(4)
        #expect(screen.view.window == nil)
        #expect(totals.last == 4, "a loaded, unshown inbox did not publish: \(totals)")
    }

    private func inbox() -> MessagesInboxViewController {
        MessagesInboxViewController(surfaces: [BlankSurface()])
    }

    private func item(_ label: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = label
        return item
    }

    /// With nothing injected and no search composed, the bar is empty: no
    /// search field that would open nothing.
    @Test func withoutSearchTheBarIsEmpty() {
        let screen = inbox()
        screen.loadViewIfNeeded()

        #expect(screen.navigationItem.rightBarButtonItems?.isEmpty ?? true)
        #expect(screen.navigationItem.searchController == nil)
        #expect(screen.navigationItem.leftBarButtonItems?.isEmpty ?? true)
    }

    /// ⚠️ THE BELL LEADS; the balance trails (inboard of search, when there
    /// is search — `InboxSystemSearchTests`).
    @Test func theShellsItemsFrameTheHeader() throws {
        let screen = inbox()
        let bell = item("Bell")
        let balance = item("Balance")
        // Injected BEFORE the view loads — the shell's order — so the load's
        // own write of the bar must pick them up rather than erase them.
        screen.setLeadingAccessoryItem(bell)
        screen.setTrailingAccessoryItem(balance)
        screen.loadViewIfNeeded()

        let leading = try #require(screen.navigationItem.leftBarButtonItems)
        let trailing = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(leading.count == 1 && leading.first === bell)
        #expect(trailing.count == 1)
        #expect(trailing.last === balance)
    }

    /// A fresh balance item (the badge re-mints one whenever its width moves)
    /// replaces the old one rather than joining it.
    @Test func replacingTheBalanceLeavesOneOfIt() throws {
        let screen = inbox()
        screen.loadViewIfNeeded()

        screen.setTrailingAccessoryItem(item("Balance"))
        let second = item("Balance")
        screen.setTrailingAccessoryItem(second)

        let trailing = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(trailing.count == 1)
        #expect(trailing.last === second)
    }
}
