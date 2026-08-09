import CoreGraphics
import Testing
@testable import Feed

/// The full-width swipe-back's two rules.
///
/// A text post arrives by an ordinary push and has no other horizontal action,
/// so the whole surface means "back" — the system's own gesture is an EDGE
/// recognizer and its edge cannot be widened. What has to be got right is
/// living alongside the comment list's vertical scroll.
struct SwipeBackPolicyTests {
    @Test func aClearRightwardDragBegins() {
        #expect(SwipeBackPolicy.shouldBegin(velocity: CGPoint(x: 800, y: 0)))
        #expect(SwipeBackPolicy.shouldBegin(velocity: CGPoint(x: 800, y: 200)))
    }

    /// The coordination rule: a vertical scroll carries sideways velocity with
    /// it, and must not be read as a dismissal.
    @Test func aVerticalScrollWithSidewaysTiltDoesNot() {
        #expect(SwipeBackPolicy.shouldBegin(velocity: CGPoint(x: 300, y: 900)) == false)
        // Even a horizontal component slightly ahead of the vertical is a tilt,
        // not an intent — dominance is required, not a majority.
        #expect(SwipeBackPolicy.shouldBegin(velocity: CGPoint(x: 260, y: 250)) == false)
    }

    @Test func leftwardMeansNothingHere() {
        #expect(SwipeBackPolicy.shouldBegin(velocity: CGPoint(x: -900, y: 0)) == false)
    }

    /// Distance OR speed: a long drag and a short flick both count.
    @Test func distanceOrSpeedCompletesThePop() {
        #expect(SwipeBackPolicy.shouldPop(translationX: 120, velocityX: 0))
        #expect(SwipeBackPolicy.shouldPop(translationX: 20, velocityX: 900))
        #expect(SwipeBackPolicy.shouldPop(translationX: 20, velocityX: 100) == false)
    }
}
