import Testing
@testable import CoreNavigation

/// A CANCELLED DRAG IS NOT A RETURN.
///
/// The grid hides the system tab bar by hand for a post's visit, and used to
/// put it back in `viewWillAppear`. That reads as "I am back", but UIKit runs
/// it when an interactive pop BEGINS — before the finger has said whether it
/// means it. Release below the completion threshold and the feed sprang back
/// with the bar left standing over it, permanently: the cleanup in
/// `viewWillDisappear` is guarded on being the top view controller and the
/// stack is already restored by then, and the completed-pop callback never
/// fires for a cancel. Nothing owned taking it away again.
///
/// The fix is a timing distinction with no syntax at the call site, which is
/// why it is a value with tests rather than an `if` — three appearance paths
/// reach one line and only one may act on it now.
struct TabBarRevealPolicyTests {
    /// A tab switch back, or any non-animated return: nothing is moving, so
    /// there is nothing to be out of step with.
    @Test func aStillScreenRevealsOutright() {
        #expect(TabBarRevealPolicy.timing(hasActiveFlight: false, isTransitioning: false,
                                          isInteractive: false) == .immediately)
    }

    /// The regression. A scrub is a question, not an answer — the reveal
    /// belongs to whatever the finger turns out to have meant.
    @Test func aScrubDefersTheReveal() {
        #expect(TabBarRevealPolicy.timing(hasActiveFlight: false, isTransitioning: true,
                                          isInteractive: true) == .whenTransitionCommits)
    }

    /// …but ONLY a scrub. A back-button pop is already committed, and holding
    /// its reveal back put the bar on a screen that had finished moving —
    /// measured at ~400ms after landing, which reads as a snap. Deferring is
    /// for uncertainty, not for transitions in general.
    @Test func aButtonPopDoesNotDeferBecauseItCannotBeTakenBack() {
        #expect(TabBarRevealPolicy.timing(hasActiveFlight: false, isTransitioning: true,
                                          isInteractive: false) == .immediately)
    }

    /// …and the deferred answer, both ways round. The cancel branch is the bug.
    @Test func onlyACommittedTransitionReveals() {
        #expect(TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: false))
        #expect(TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: true) == false,
                "a cancelled drag leaves the pushed screen on display — the bar stays under it")
    }

    /// A hero return keeps its own arrangement: the bar is made geometrically
    /// present and visually absent at pop-begin so the flight has something to
    /// fade in. Deferring THAT to a completion handler is what once made the
    /// bar snap in after the card had already landed, so the flight must keep
    /// winning over the transition test below it.
    @Test func aFlightKeepsDrivingItsOwnReveal() {
        for interactive in [true, false] {
            #expect(TabBarRevealPolicy.timing(hasActiveFlight: true, isTransitioning: true,
                                              isInteractive: interactive) == .drivenByFlight)
        }
        #expect(TabBarRevealPolicy.timing(hasActiveFlight: true, isTransitioning: false,
                                          isInteractive: false) == .drivenByFlight)
    }
}
