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
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: false, isTransitioning: false,
                                          isInteractive: false) == .immediately)
    }

    /// The regression. A scrub is a question, not an answer — the reveal
    /// belongs to whatever the finger turns out to have meant.
    @Test func aScrubDefersTheReveal() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: false, isTransitioning: true,
                                          isInteractive: true) == .whenTransitionCommits)
    }

    /// …but ONLY a scrub. A back-button pop is already committed, and holding
    /// its reveal back put the bar on a screen that had finished moving —
    /// measured at ~400ms after landing, which reads as a snap. Deferring is
    /// for uncertainty, not for transitions in general.
    @Test func aButtonPopDoesNotDeferBecauseItCannotBeTakenBack() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: false, isTransitioning: true,
                                          isInteractive: false) == .immediately)
    }

    /// …and the deferred answer, both ways round. The cancel branch is the bug.
    @Test func onlyACommittedTransitionReveals() {
        #expect(TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: false))
        #expect(TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: true) == false,
                "a cancelled drag leaves the pushed screen on display — the bar stays under it")
    }

    /// THE PRODUCT RULE (2026-09-28): a close of the snap feed owes the dock
    /// at its LANDING, whatever drives it — a grab, a flight's tap-back, a
    /// window, the chevron. It used to be faded in with the return (1:1 with a
    /// grab, on the flight's spring, alongside a back-button pop); none of
    /// those may win over the landing any more.
    @Test func aReturnFromTheFeedRevealsAtTheLanding() {
        for interactive in [true, false] {
            #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: true, isTransitioning: true,
                                              isInteractive: interactive) == .atLanding)
        }
    }

    /// …and with nothing moving there is no landing to wait for: waiting for
    /// a transition that does not exist would leave the dock down for good.
    @Test func aReturnWithNoTransitionRevealsOutright() {
        #expect(TabBarRevealPolicy.timing(returnsFromFullBleed: true, isTransitioning: false,
                                          isInteractive: false) == .immediately)
    }
}
