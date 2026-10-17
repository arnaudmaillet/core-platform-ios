import UIKit

/// A screen that limits where UIKit's full-surface back swipe may begin —
/// a tab strip that pages, a carousel that scrolls (#1324).
@MainActor
public protocol ContentPopGating: AnyObject {
    /// Whether the back swipe may begin from `point`, in `view`'s space.
    func allowsContentPop(beginningAt point: CGPoint, in view: UIView) -> Bool
}

/// Stands in front of UIKit's own delegate for the iOS 26 full-surface back
/// swipe (`interactiveContentPopGestureRecognizer`) — forwarding EVERYTHING to
/// it but one private veto (#1324).
///
/// ⚠️ WHY A PROXY, NOT A REPLACEMENT. UIKit's delegate refuses the swipe in a
/// PRIVATE check (`_gestureRecognizer:shouldReceiveEvent:`) as soon as the
/// stack has a delegate of its own — a hero owner, the slide hub — on a
/// screen whose pop brings the tab bar back (measured, #672). That veto is why
/// plain pushes carried a custom slide of their own, which then raced the
/// native swipe where UIKit did NOT veto it (#1316, #1143). Replacing the
/// delegate outright would lift the veto but also everything else UIKit
/// decides there — the content that scrolls under the finger, the touches it
/// must not take. So every message reaches UIKit's delegate except the veto,
/// which this object simply does not answer to; and the begin decision adds
/// the app's own policy (`shouldBegin`) on top of UIKit's.
@MainActor
public final class ContentPopDelegateProxy: NSObject, UIGestureRecognizerDelegate {
    /// UIKit's own delegate — the navigation controller keeps it alive.
    public private(set) weak var system: (any UIGestureRecognizerDelegate)?
    private let policy: (UIGestureRecognizer) -> Bool

    /// The private veto this proxy declines to relay.
    static let vetoSelector = NSSelectorFromString("_gestureRecognizer:shouldReceiveEvent:")

    public init(system: (any UIGestureRecognizerDelegate)?, policy: @escaping (UIGestureRecognizer) -> Bool) {
        self.system = system
        self.policy = policy
        super.init()
    }

    override public func responds(to aSelector: Selector!) -> Bool {
        if aSelector == Self.vetoSelector { return false }
        if super.responds(to: aSelector) { return true }
        return (system as? NSObject)?.responds(to: aSelector) ?? false
    }

    override public func forwardingTarget(for aSelector: Selector!) -> Any? {
        aSelector == Self.vetoSelector ? nil : system
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard policy(gestureRecognizer) else { return false }
        return system?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }
}
