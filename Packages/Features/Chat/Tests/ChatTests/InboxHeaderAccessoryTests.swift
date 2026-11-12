import CoreNavigation
import Testing
import UIKit
@testable import Chat

/// **The inbox header's injected items — the shell's bell, and no balance.**
///
/// Items the shell injects are held by the screen and composed into its bar:
/// `[bell][selector] …`, the search stacked under the bar. The balance left
/// Messages (#2336, the owner 2026-11-12): no heart, no spend, no claim here.
/// These inboxes have no search composed, so no field
/// (`InboxSystemSearchTests` pins the one with search); the selector in the
/// bar is `InboxSelectorInBarTests`' subject (#2337).
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

    /// With nothing injected and no search composed, the bar holds the
    /// selector alone (#2337): no search field that would open nothing, no
    /// separator before a bell that is not there.
    @Test func withoutSearchTheBarHoldsTheSelectorAlone() throws {
        let screen = inbox()
        screen.loadViewIfNeeded()

        #expect(screen.navigationItem.rightBarButtonItems?.isEmpty ?? true)
        #expect(screen.navigationItem.searchController == nil)
        let leading = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(leading.count == 1)
        #expect(leading.first?.identifier == MessagesInboxViewController.selectorItemID)
    }

    /// ⚠️ THE BELL LEADS, THE SELECTOR FOLLOWS, AND NOTHING TRAILS (#2336,
    /// #2337): the shell hands the inbox its bell alone —
    /// `MessagesTabCoordinator` builds no balance — the selector comes right
    /// after it, and the bar reserves no trailing slot: that group is empty.
    @Test func theShellsBellLeadsAndNothingTrails() throws {
        let screen = inbox()
        let bell = item("Bell")
        // Injected BEFORE the view loads — the shell's order — so the load's
        // own write of the bar must pick it up rather than erase it.
        screen.setLeadingAccessoryItem(bell)
        screen.loadViewIfNeeded()

        let leading = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(leading.count == 3 && leading.first === bell)
        #expect(leading.last?.identifier == MessagesInboxViewController.selectorItemID)
        #expect(screen.navigationItem.rightBarButtonItems?.isEmpty ?? true,
                "the inbox's trailing group holds an item the shell no longer hands it")
    }

    /// The protocol's trailing slot still works if anything ever fills it: a
    /// fresh item replaces the old one rather than joining it, and `nil`
    /// clears it back to an empty trailing group.
    @Test func aTrailingItemReplacesAndClears() throws {
        let screen = inbox()
        screen.loadViewIfNeeded()

        screen.setTrailingAccessoryItem(item("Accessory"))
        let second = item("Accessory")
        screen.setTrailingAccessoryItem(second)

        let trailing = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(trailing.count == 1)
        #expect(trailing.last === second)

        screen.setTrailingAccessoryItem(nil)
        #expect(screen.navigationItem.rightBarButtonItems?.isEmpty ?? true)
    }
}
