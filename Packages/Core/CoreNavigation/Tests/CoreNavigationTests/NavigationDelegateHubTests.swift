import Testing
import UIKit
@testable import CoreNavigation

/// `NavigationDelegateHub`: one occupant of the delegate slot, leases on top of
/// it, UIKit's questions to the top lease, `didShow` to every lease once.
@MainActor
struct NavigationDelegateHubTests {
    @Test func questionsGoToTheTopLeaseAndReleaseUncoversTheOneBelow() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let hub = NavigationDelegateHub.of(nav)
        let below = AnsweringDelegate(), above = AnsweringDelegate()
        hub.lease(below)
        hub.lease(above)
        #expect(nav.delegate === hub)
        #expect(nav.leasedDelegate === above)

        _ = hub.navigationController(
            nav, animationControllerFor: .push, from: UIViewController(), to: UIViewController()
        )
        #expect(above.asked == 1 && below.asked == 0, "a covered lease answered UIKit")

        hub.release(above)
        #expect(nav.leasedDelegate === below)
        withExtendedLifetime((below, above)) {}
    }

    @Test func everyLeaseHearsDidShowOnceBottomFirst() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let hub = NavigationDelegateHub.of(nav)
        var order: [String] = []
        let first = AnsweringDelegate { order.append("first") }
        let second = AnsweringDelegate { order.append("second") }
        hub.lease(first)
        hub.lease(second)

        hub.navigationController(nav, didShow: nav.topViewController!, animated: true)

        #expect(order == ["first", "second"])
        withExtendedLifetime((first, second)) {}
    }

    @Test func aDelegateWrittenDirectlyIsAdoptedNotDropped() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let before = AnsweringDelegate()
        nav.delegate = before
        let hub = NavigationDelegateHub.of(nav)
        let lease = AnsweringDelegate()
        hub.lease(lease)
        #expect(hub.contains(before), "a delegate that was there first was dropped")
        #expect(nav.leasedDelegate === lease)

        let after = AnsweringDelegate()
        nav.delegate = after          // someone took the slot behind the hub's back
        _ = NavigationDelegateHub.of(nav)
        #expect(nav.leasedDelegate === after, "the slot's newest owner was not put on top")
        withExtendedLifetime((before, lease, after)) {}
    }

    /// ⚠️ AN IDLE HUB LEAVES THE SLOT (#670): any delegate there cost the
    /// stack its full-surface back swipe on a screen whose pop brings the tab
    /// bar back, even with every answer nil. The next lease takes it back.
    @Test func theLastReleaseEmptiesTheSlotAndTheNextLeaseRetakesIt() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let hub = NavigationDelegateHub.of(nav)
        let flight = AnsweringDelegate()
        hub.lease(flight)
        #expect(nav.delegate === hub)

        hub.release(flight)
        #expect(nav.delegate == nil, "an idle hub kept the slot, and with it the back swipe")

        let next = AnsweringDelegate()
        NavigationDelegateHub.of(nav).lease(next)
        #expect(nav.delegate === hub, "a lease found the hub out of its slot")
        #expect(nav.leasedDelegate === next)
        withExtendedLifetime((flight, next)) {}
    }

    /// Leases are weak and can die without a release — For You's flight does,
    /// with its owner. The next `didShow` notices the hub is idle.
    @Test func aDidShowThatFindsNoLiveLeaseEmptiesTheSlot() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let hub = NavigationDelegateHub.of(nav)
        var flight: AnsweringDelegate? = AnsweringDelegate()
        hub.lease(flight!)
        flight = nil

        hub.navigationController(nav, didShow: nav.topViewController!, animated: true)

        #expect(nav.delegate == nil, "a hub whose every lease was gone kept the slot")
    }

    /// Stepping out is from the hub's OWN slot only: a delegate written there
    /// directly in the meantime is someone else's.
    @Test func anIdleHubNeverClearsSomeoneElsesDelegate() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let hub = NavigationDelegateHub.of(nav)
        let flight = AnsweringDelegate()
        hub.lease(flight)
        let direct = AnsweringDelegate()
        nav.delegate = direct

        hub.release(flight)

        #expect(nav.delegate === direct)
        withExtendedLifetime((flight, direct)) {}
    }

    @Test func aReleasedLeaseIsNotToldAnything() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let hub = NavigationDelegateHub.of(nav)
        var heard = 0
        let gone = AnsweringDelegate { heard += 1 }
        hub.lease(gone)
        hub.release(gone)
        hub.navigationController(nav, didShow: nav.topViewController!, animated: true)
        #expect(heard == 0)
        withExtendedLifetime(gone) {}
    }
}

private final class AnsweringDelegate: NSObject, UINavigationControllerDelegate {
    private(set) var asked = 0
    private let onDidShow: () -> Void
    init(onDidShow: @escaping () -> Void = {}) { self.onDidShow = onDidShow }

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController, to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        asked += 1
        return nil
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController, animated: Bool
    ) {
        onDidShow()
    }
}
