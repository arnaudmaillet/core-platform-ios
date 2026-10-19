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

    /// ⚠️ THE TRIPWIRE FOR AN iOS UPDATE (#1328): UIKit's own delegate for
    /// the full-surface swipe still answers the veto the proxy declines. A
    /// release that renames it, or hands the recognizer another delegate, fails
    /// here in CI, not silently in use.
    @Test func uikitsOwnDelegateStillAnswersTheVeto() throws {
        guard #available(iOS 26.0, *) else { return }
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.loadViewIfNeeded()
        let content = try #require(navigation.interactiveContentPopGestureRecognizer,
                                   "iOS 26 has a full-surface back swipe")
        let system = try #require(content.delegate, "UIKit gave the swipe no delegate")
        #expect(ContentPopDelegateProxy.canInterpose(on: system),
                "\(type(of: system)) no longer answers the veto: the proxy would not lift it")
    }

    /// The selector is the veto's, whole, though no literal spells it.
    @Test func theVetoSelectorIsTheVetosName() {
        #expect(NSStringFromSelector(ContentPopDelegateProxy.vetoSelector) == "_gestureRecognizer" + ":shouldReceiveEvent:")
    }

    /// The fallback: no delegate, or one without the veto, is never
    /// interposed. UIKit's own stays.
    @Test func aDelegateWithoutTheVetoIsNotInterposed() {
        final class Plain: NSObject, UIGestureRecognizerDelegate {}
        #expect(!ContentPopDelegateProxy.canInterpose(on: nil))
        #expect(!ContentPopDelegateProxy.canInterpose(on: Plain()))
        #expect(ContentPopDelegateProxy.canInterpose(on: System()))
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
