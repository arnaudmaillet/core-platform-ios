import Testing
import UIKit
@testable import CoreNavigation

/// `HeroPushSession`: the orchestration three presenters used to write for
/// themselves, and the rules their copies drifted on.
@MainActor
struct HeroPushSessionTests {
    private func stage(
        retainsItself: Bool = false
    ) -> (HeroPushSession, UINavigationController, PreviousOwner) {
        let nav = UINavigationController(rootViewController: UIViewController())
        let owner = PreviousOwner()
        nav.delegate = owner
        let session = HeroPushSession(
            source: SessionSource(), destination: SessionFeed(), on: nav,
            retainsItself: retainsItself
        )
        return (session, nav, owner)
    }

    @Test func everyEndingRunsOneCloseOutAndHandsTheSlotBack() {
        let (session, nav, owner) = stage()
        var endings: [HeroPushSession.Ending] = []
        session.onClose = { endings.append($0) }
        session.takeDelegateSlot()
        #expect(nav.leasedDelegate === session.controller)

        session.controller.onPresentationCancelled?()   // a reversed push
        session.controller.onSourceReturned?()          // a later, stale ending

        #expect(endings == [.reversed], "a second ending ran the close-out again")
        #expect(nav.leasedDelegate === owner, "the slot did not go back to its owner")
        withExtendedLifetime(owner) {}
    }

    @Test func aSlotSomeoneElseTookIsLeftWithThem() {
        let (session, nav, owner) = stage()
        session.takeDelegateSlot()
        let newOwner = PreviousOwner()
        NavigationDelegateHub.of(nav).lease(newOwner)

        session.close(.returned)

        #expect(nav.leasedDelegate === newOwner, "the close took the slot from a screen that owns it now")
        withExtendedLifetime((owner, newOwner)) {}
    }

    @Test func aForwarderHoldsTheSlotOnTheSessionsBehalf() {
        let (session, nav, owner) = stage()
        session.takeDelegateSlot()
        let cardClose = PreviousOwner()
        session.registerForwarder(cardClose)
        NavigationDelegateHub.of(nav).lease(cardClose)
        #expect(session.holdsDelegateSlot)

        session.close(.returned)
        #expect(nav.leasedDelegate === cardClose,
                "a forwarder was released before it could hear its own pop")
        NavigationDelegateHub.of(nav).release(cardClose)
        #expect(nav.leasedDelegate === owner)

        // A REVERSED push takes its forwarders along: no pop will ever come.
        let (reversed, reversedNav, reversedOwner) = stage()
        reversed.takeDelegateSlot()
        let orphan = PreviousOwner()
        reversed.registerForwarder(orphan)
        NavigationDelegateHub.of(reversedNav).lease(orphan)
        reversed.close(.reversed)
        #expect(reversedNav.leasedDelegate === reversedOwner)
        withExtendedLifetime((owner, cardClose, reversedOwner, orphan)) {}
    }

    @Test func aStackOwnedByNoOneIsLeftWithNoLease() {
        let nav = UINavigationController(rootViewController: UIViewController())
        let session = HeroPushSession(source: SessionSource(), destination: SessionFeed(), on: nav)
        session.takeDelegateSlot()
        #expect(nav.leasedDelegate === session.controller)
        session.close(.abandoned)
        #expect(nav.leasedDelegate == nil)
    }

    @Test func aSelfRetainedSessionLivesUntilATurnAfterItsClose() async {
        weak var observed: HeroPushSession?
        let nav: UINavigationController
        do {
            let (session, stageNav, _) = stage(retainsItself: true)
            nav = stageNav
            observed = session
        }
        #expect(observed != nil, "a builder's session died before its flight")
        observed?.close(.returned)
        #expect(observed != nil, "released inside the close-out, which runs in its own callbacks")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(observed == nil, "the session outlived its close")
        withExtendedLifetime(nav) {}
    }

    @Test func aDismissalOntoAnIntermediateEndsTheSession() {
        let (session, _, owner) = stage()
        var endings: [HeroPushSession.Ending] = []
        session.onClose = { endings.append($0) }
        session.controller.onDismissedToIntermediate?(UIViewController())
        #expect(endings == [.toIntermediate])
        withExtendedLifetime(owner) {}
    }
}

private final class PreviousOwner: NSObject, UINavigationControllerDelegate {}

@MainActor
private final class SessionSource: NSObject, ZoomTransitionSource {
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { SessionCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class SessionCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}

private final class SessionFeed: UIViewController, ZoomTransitionDestination {
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}
