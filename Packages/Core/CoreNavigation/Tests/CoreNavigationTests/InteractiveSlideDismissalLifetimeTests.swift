import Testing
import UIKit
@testable import CoreNavigation

/// One dismissal driver per opened post, and every one of them released.
///
/// ⚠️ THE CYCLE IS THE OBVIOUS WAY TO WRITE THE CLOSURE. `prepareForDismissal`
/// exists so an owner can swap `revealGeometry` before the driver reads it —
/// so the natural body writes back through the driver, and the natural capture
/// is strong. The driver owns the closure; the closure then owns the driver.
///
/// It leaks one `InteractiveSlideDismissal` per opened post for the life of the
/// process, and nothing observes it: the hero census counts animators,
/// interruptors, retries and cards, and a dismissal DRIVER is none of those.
/// Two of the four call sites had it — the map's card close and the cluster
/// gallery's — which is why this pins the rule rather than trusting it.
@MainActor
struct InteractiveSlideDismissalLifetimeTests {

    /// The shape the call sites use: write back, but weakly.
    @Test func aDriverWhoseClosureCapturesItWeaklyIsReleased() {
        weak var observed: InteractiveSlideDismissal?
        autoreleasepool {
            let driver = InteractiveSlideDismissal()
            driver.prepareForDismissal = { [weak driver] _ in
                driver?.revealGeometry = nil
            }
            observed = driver
            #expect(observed != nil)
        }
        #expect(observed == nil, "a dismissal driver outlived the screen that made it")
    }

    /// ⚠️ AND THE TEST CAN TELL THE DIFFERENCE. Without this, the one above
    /// passes on a type that could not leak, and proves nothing about the type
    /// that can. This is the defect, written on purpose, and it must survive.
    @Test func aStrongCaptureIsTheLeakThisGuards() {
        weak var observed: InteractiveSlideDismissal?
        autoreleasepool {
            let driver = InteractiveSlideDismissal()
            driver.prepareForDismissal = { _ in
                driver.revealGeometry = nil
            }
            observed = driver
        }
        #expect(observed != nil, """
            a strong self-capture through this property no longer leaks — either \
            the property changed shape, or this test stopped exercising it, and \
            the weak-capture test above is now unfalsifiable
            """)
        // Break it so the deliberate leak does not outlive the test.
        observed?.prepareForDismissal = nil
    }
}
