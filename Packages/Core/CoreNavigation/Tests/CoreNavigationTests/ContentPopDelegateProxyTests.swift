import Testing
import UIKit
@testable import CoreNavigation

/// The full-surface back swipe's delegate: UIKit's own, minus one private
/// veto, plus the app's policy (#1324).
@MainActor
struct ContentPopDelegateProxyTests {
    /// Stands in for UIKit's delegate: answers the veto (refusing) and one
    /// public question, and says how it was asked.
    private final class System: NSObject, UIGestureRecognizerDelegate {
        var begins = true
        var simultaneousAsks = 0
        @objc(_gestureRecognizer:shouldReceiveEvent:)
        func veto(_ recognizer: UIGestureRecognizer, shouldReceiveEvent event: UIEvent) -> Bool { false }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { begins }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            simultaneousAsks += 1
            return false
        }
    }

    /// ⚠️ THE VETO IS NOT RELAYED: UIKit asks whether the delegate answers it,
    /// and the proxy says it does not — so the stack's own delegate no longer
    /// silences the swipe on a plain push.
    @Test func thePrivateVetoIsNeverRelayed() {
        let system = System()
        let proxy = ContentPopDelegateProxy(system: system) { _ in true }
        #expect(system.responds(to: ContentPopDelegateProxy.vetoSelector))
        #expect(!proxy.responds(to: ContentPopDelegateProxy.vetoSelector))
        #expect(proxy.forwardingTarget(for: ContentPopDelegateProxy.vetoSelector) == nil)
    }

    /// Everything else reaches UIKit's delegate: the content under the finger
    /// is still UIKit's call.
    @Test func everythingElseReachesUIKitsDelegate() {
        let system = System()
        let proxy = ContentPopDelegateProxy(system: system) { _ in true }
        let selector = #selector(UIGestureRecognizerDelegate.gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:))
        #expect(proxy.responds(to: selector))
        #expect(proxy.forwardingTarget(for: selector) as AnyObject? === system)
    }

    /// The begin decision is the app's policy AND UIKit's.
    @Test func theBeginIsThePolicyAndUIKits() {
        let system = System()
        let recognizer = UIPanGestureRecognizer()
        var allowed = false
        let proxy = ContentPopDelegateProxy(system: system) { _ in allowed }
        #expect(!proxy.gestureRecognizerShouldBegin(recognizer), "the app's policy was overruled")
        allowed = true
        #expect(proxy.gestureRecognizerShouldBegin(recognizer))
        system.begins = false
        #expect(!proxy.gestureRecognizerShouldBegin(recognizer), "UIKit's own begin was overruled")
    }
}
