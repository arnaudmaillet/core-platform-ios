import Testing
@testable import Maps

/// The truth table for "the map is inert while a transition owns the screen".
///
/// Every one of these was a hole in the two booleans this replaces, and three
/// of them were filmed or traced rather than imagined:
/// - a reversed present locked the map for the life of the screen;
/// - the tap lock was released at interactive-pop BEGIN, so a grab re-opened
///   the map to taps while the return was still animating;
/// - the defensive modal branch set no lock at all, so two taps presented twice.
struct MapOpenGateTests {

    @Test func anIdleMapOpensAndIsTouchable() {
        let gate = MapOpenGate()
        #expect(gate.canOpen)
        #expect(!gate.mapIsInert)
        #expect(gate.route == nil)
    }

    @Test func aPresentationLocksBothAnswers() {
        var gate = MapOpenGate()
        let opened = gate.openBegan(.hero)
        #expect(opened)
        #expect(!gate.canOpen)
        #expect(gate.mapIsInert)
        #expect(gate.route == .hero)
    }

    /// The second tap, on the same marker or another one.
    @Test func aSecondOpenIsRefusedByTheGateItself() {
        var gate = MapOpenGate()
        let first = gate.openBegan(.hero)
        #expect(first)
        let second = gate.openBegan(.reveal)
        #expect(second == false, "a second post opened over the first")
        #expect(gate.route == .hero, "the refused open must not overwrite the route")
    }

    /// ⚠️ The whole round trip, dismissal included. A tap during the RETURN is
    /// the same defect as a tap during the present.
    @Test func theGateStaysShutThroughTheDismissal() {
        var gate = MapOpenGate()
        _ = gate.openBegan(.hero)
        gate.destinationShown()
        #expect(!gate.canOpen)
        gate.dismissalBegan()
        #expect(!gate.canOpen, "the map re-opened while the return was still animating")
        #expect(gate.mapIsInert)
        gate.dismissalEnded(committed: true)
        #expect(gate.canOpen)
        #expect(!gate.mapIsInert)
    }

    /// A grab released below the threshold: the feed stays, so the map stays shut.
    @Test func aCancelledDismissalLeavesTheFeedOpen() {
        var gate = MapOpenGate()
        _ = gate.openBegan(.hero)
        gate.destinationShown()
        gate.dismissalBegan()
        gate.dismissalEnded(committed: false)
        #expect(!gate.canOpen, "the feed is still on screen")
        #expect(gate.route == .hero)
        // …and the next dismissal still works from there.
        gate.dismissalBegan()
        gate.dismissalEnded(committed: true)
        #expect(gate.canOpen)
    }

    /// ⚠️ THE ENDING THAT HAD NO HANDLER: the flight caught mid-air and thrown
    /// back. Without this the map is dead to taps for the life of the screen.
    @Test func aReversedPresentReleasesTheMap() {
        var gate = MapOpenGate()
        _ = gate.openBegan(.hero)
        gate.presentationCancelled()
        #expect(gate.canOpen, "the map was bricked by a reversed present")
        #expect(!gate.mapIsInert)
        let reopened = gate.openBegan(.hero)
        #expect(reopened, "and the next tap must open")
    }

    /// A cancellation that arrives after the destination is up is not a
    /// reversal — it must not unlock a map with a feed on top of it.
    @Test func aLateCancellationCannotUnlockAnOpenFeed() {
        var gate = MapOpenGate()
        _ = gate.openBegan(.hero)
        gate.destinationShown()
        gate.presentationCancelled()
        #expect(!gate.canOpen)
        #expect(gate.route == .hero)
    }

    @Test func landingOnThePlacePageIsNotBeingHome() {
        var gate = MapOpenGate()
        _ = gate.openBegan(.hero)
        gate.destinationShown()
        gate.dismissalBegan()
        gate.dismissedToIntermediate()
        #expect(!gate.canOpen, "the place page is on top of the map")
        #expect(gate.mapIsInert)
        gate.appearedAtRoot()
        #expect(gate.canOpen, "the page popped home and the map is frontmost")
    }

    /// The backstop, for endings nobody wired. `viewDidAppear` and never
    /// `viewWillAppear`, which UIKit runs at interactive-pop begin.
    @Test func appearingAtRootReleasesWhateverWasHeld() {
        for route in [MapOpenGate.Route.hero, .reveal, .plainPush, .modalFallback] {
            var gate = MapOpenGate()
            _ = gate.openBegan(route)
            gate.appearedAtRoot()
            #expect(gate.canOpen, "an abandoned \(route) held the map shut")
            #expect(!gate.mapIsInert)
        }
    }

    /// Every route locks, and every route is released by its own ending — the
    /// modal fallback included, which used to set no lock at all.
    @Test func everyRouteLocksAndReleases() {
        for route in [MapOpenGate.Route.hero, .reveal, .plainPush, .modalFallback] {
            var gate = MapOpenGate()
            let locked = gate.openBegan(route)
            #expect(locked)
            #expect(gate.mapIsInert, "\(route) left the map touchable")
            gate.destinationShown()
            gate.dismissalBegan()
            gate.dismissalEnded(committed: true)
            #expect(gate.canOpen, "\(route) never released")
        }
    }

    /// Events arriving out of order — a late `destinationShown` after a
    /// reversal, a `dismissalEnded` with nothing dismissing — must not resurrect
    /// a state. UIKit delivers these; the guard has to be total, not polite.
    @Test func strayEventsAreInert() {
        var gate = MapOpenGate()
        gate.destinationShown()
        #expect(gate.canOpen)
        gate.dismissalBegan()
        #expect(gate.canOpen)
        gate.dismissalEnded(committed: true)
        #expect(gate.canOpen)
        gate.presentationCancelled()
        #expect(gate.canOpen)

        _ = gate.openBegan(.reveal)
        gate.presentationCancelled()
        gate.destinationShown()
        #expect(gate.canOpen, "a late destinationShown re-locked a released map")
    }
}
