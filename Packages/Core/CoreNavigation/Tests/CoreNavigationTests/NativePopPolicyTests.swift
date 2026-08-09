import Testing
@testable import CoreNavigation

/// The edge-swipe-to-pop decision.
///
/// Extracted from the gesture delegate so it can be tested at all: the real
/// gesture needs a finger, and the simulator does not accept injected touches.
struct NativePopPolicyTests {
    private func decide(
        isAtRoot: Bool = false,
        isTransitioning: Bool = false,
        hidesBackButton: Bool = false,
        owns: Bool? = nil,
        customLeading: Bool = false,
        supplements: Bool = false
    ) -> Bool {
        NativePopPolicy.shouldBegin(
            isAtRoot: isAtRoot,
            isTransitioning: isTransitioning,
            hidesBackButton: hidesBackButton,
            ownsInteractiveDismissal: owns,
            hasCustomLeadingItem: customLeading,
            leadingItemsSupplementBackButton: supplements
        )
    }

    /// The regression: a text post is a hero destination BY TYPE but arrived by
    /// an ordinary push, so nothing owns its dismissal and the edge swipe is
    /// the only way back. Inferring ownership from conformance refused it.
    @Test func aHeroDestinationThatDisclaimsOwnershipGetsTheNativePop() {
        #expect(decide(owns: false, customLeading: true) == true)
    }

    /// …and one that IS hosting a grab must never race it.
    @Test func aHeroDestinationHostingItsOwnGrabDoesNot() {
        #expect(decide(owns: true) == false)
        #expect(decide(owns: true, customLeading: false) == false)
    }

    /// UIKit's contract for everything that is not a hero destination: a custom
    /// leading item replaces the back affordance and takes the gesture with it,
    /// unless the screen says the item is supplemental.
    @Test func aCustomLeadingItemStillSuppressesTheGestureElsewhere() {
        #expect(decide(customLeading: true) == false)
        #expect(decide(customLeading: true, supplements: true) == true)
        #expect(decide() == true)
    }

    /// The three hard stops, which no screen may opt out of.
    @Test func rootTransitionAndSuppressedBackAlwaysRefuse() {
        #expect(decide(isAtRoot: true, owns: false) == false)
        #expect(decide(isTransitioning: true, owns: false) == false)
        #expect(decide(hidesBackButton: true, owns: false) == false)
    }
}
