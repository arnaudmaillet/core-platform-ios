import Testing
import UIKit
@testable import CoreNavigation

/// What outlives a hero flight, and what ends it (`dev/HERO_PUSH_AUDIT_PLAN.md`,
/// Phase 2): recognizers on a reused view, landing covers and holds, the
/// presenter's receded chrome, and the rotation lock.
@MainActor
@Suite(.serialized)
struct HeroLifetimeTests {

    // MARK: - 2.3 A reused view does not collect dead pans

    @Test func attachingSweepsThePansOfDriversThatAreGone() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let foreign = UIPanGestureRecognizer()
        view.addGestureRecognizer(foreign)
        let feed = StubFeed()
        let source = StubSource()

        for _ in 0..<5 {
            // A driver per opening, released with its flight.
            let driver = ZoomDismissInteractionController()
            driver.attach(to: view, source: source, destination: feed) {}
        }
        let live = ZoomDismissInteractionController()
        live.attach(to: view, source: source, destination: feed) {}

        let dismissalPans = view.gestureRecognizers?.compactMap { $0 as? ZoomDismissPan } ?? []
        #expect(dismissalPans.count == 1, "dead dismissal pans piled up on the reused view")
        #expect(dismissalPans.first?.driver === live)
        #expect(view.gestureRecognizers?.contains(foreign) == true, "a pan that is not ours was removed")
        withExtendedLifetime(live) {}
    }

    // MARK: - 2.1 / 2.2 Leftovers end when the screen is needed

    @Test func clearingTheScreenEndsTheLeftoverOverIt() {
        let host = UIView()
        let card = UIView()
        host.addSubview(card)
        let lease = ZoomLandingLeftovers.lease(card, over: host)

        let unrelated = UIView()
        ZoomLandingLeftovers.clear(over: unrelated)
        #expect(lease.isLive && card.superview === host, "clearing another screen took this cover")

        // The destination's collection view is inside the host: a drag there
        // reaches the cover parked over the whole page.
        let page = UIView()
        host.addSubview(page)
        ZoomLandingLeftovers.clear(over: page)
        #expect(!lease.isLive)
        #expect(card.superview == nil, "the ended leftover stayed on screen")
    }

    @Test func aNaturalEndingIsNotAClear() {
        let host = UIView()
        let card = UIView()
        host.addSubview(card)
        let lease = ZoomLandingLeftovers.lease(card, over: host)
        lease.end(removingCard: false)
        #expect(card.superview === host, "the owner removes its own card on a natural ending")
        ZoomLandingLeftovers.clear(over: host)
        #expect(card.superview === host, "an ended lease was cleared a second time")
    }

    // MARK: - 2.6 Rotation waits for every flight

    /// Counted relative to whatever else is in the air: other suites' flights
    /// (a landing hold lasts up to 0.75s) run beside this one.
    @Test func theLockHoldsUntilTheLastLeaseEnds() {
        let baseline = FlightOrientationLock.liveLeaseCount
        let flight = FlightOrientationLock.acquire()
        let hold = FlightOrientationLock.acquire()
        #expect(FlightOrientationLock.liveLeaseCount == baseline + 2)
        flight.release()
        #expect(FlightOrientationLock.isHeld, "the flight's end released the landing hold's lock")
        hold.release()
        hold.release()
        #expect(FlightOrientationLock.liveLeaseCount == baseline, "a double release counted twice")
        #expect(FlightOrientationLock.mask(holding: .landscapeLeft) == .landscapeLeft)
        #expect(FlightOrientationLock.mask(holding: .unknown) == nil)
    }

    // MARK: - 2.13 The presenter gets its own chrome back

    @Test func recededChromeIsRestoredNotZeroed() {
        let view = UIView()
        view.layer.cornerRadius = 12
        view.layer.masksToBounds = true

        ZoomFlight.applyRecededChrome(to: view, radius: 55)
        ZoomFlight.applyRecededChrome(to: view, radius: 55)   // a re-apply over live chrome
        #expect(view.layer.cornerRadius == 55)
        ZoomFlight.clearRecededChrome(from: view)

        #expect(view.layer.cornerRadius == 12, "the depth view lost its own rounding")
        #expect(view.layer.masksToBounds == true)

        let plain = UIView()
        ZoomFlight.applyRecededChrome(to: plain, radius: 55)
        ZoomFlight.clearRecededChrome(from: plain)
        #expect(plain.layer.cornerRadius == 0)
        #expect(plain.layer.masksToBounds == false)
    }
}

// MARK: - Doubles

@MainActor
private final class StubSource: NSObject, ZoomTransitionSource {
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { StubCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class StubCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}

private final class StubFeed: UIViewController, ZoomTransitionDestination {
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}
