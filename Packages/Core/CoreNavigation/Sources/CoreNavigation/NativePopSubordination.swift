import ObjectiveC
import UIKit

/// A recognizer that closes a screen on its own — a screen's full-surface
/// slide (`InteractiveSlideDismissal`), a hero grab (`ZoomDismissInteractionController`).
/// UIKit's own pops wait for it to fail (`NativePopSubordination`).
@MainActor
public protocol CustomBackPopper: UIGestureRecognizer {}

/// ⚠️ ONE POPPER PER SWIPE (#1144, #1316): every custom back recognizer has
/// UIKit's two pops — the edge one and iOS 26's full-content one — required
/// to fail it. Whichever began first used to win, and when it was UIKit's,
/// its pop had no driver of ours behind it; two of them could pop two
/// screens on one swipe (#1143). Required to fail, a native pop only begins
/// where the custom one declined.
///
/// UIKit shows no failure requirement once set, so each one made here is
/// also recorded on the native recognizer: the test that walks a stack's
/// recognizers reads it (`nativePopsWait(for:in:)`).
@MainActor
public enum NativePopSubordination {
    /// UIKit's pops on `nav`: the edge one, and the full-content one.
    public static func nativePops(of nav: UINavigationController) -> [UIGestureRecognizer] {
        var pops = [nav.interactivePopGestureRecognizer]
        if #available(iOS 26.0, *) { pops.append(nav.interactiveContentPopGestureRecognizer) }
        return pops.compactMap { $0 }
    }

    /// Makes `nav`'s pops wait for `popper` to fail. Idempotent.
    public static func subordinate(nativePopsOf nav: UINavigationController, to popper: UIGestureRecognizer) {
        for native in nativePops(of: nav) where !waits(native, for: popper) {
            native.require(toFail: popper)
            requirements(of: native).add(popper)
        }
    }

    /// Whether both of `nav`'s pops wait for `popper` to fail.
    public static func nativePopsWait(for popper: UIGestureRecognizer, in nav: UINavigationController) -> Bool {
        let pops = nativePops(of: nav)
        return !pops.isEmpty && pops.allSatisfy { waits($0, for: popper) }
    }

    /// Every custom back recognizer in `nav`'s view tree: the screens
    /// on its stack, laid out or not, and the stack's own view.
    public static func customPoppers(in nav: UINavigationController) -> [UIGestureRecognizer] {
        var found: [UIGestureRecognizer] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] where recognizer is any CustomBackPopper {
                if seen.insert(ObjectIdentifier(recognizer)).inserted { found.append(recognizer) }
            }
            view.subviews.forEach(walk)
        }
        walk(nav.view)
        for screen in nav.viewControllers where screen.isViewLoaded { walk(screen.view) }
        return found
    }

    private static func waits(_ native: UIGestureRecognizer, for popper: UIGestureRecognizer) -> Bool {
        requirements(of: native).contains(popper)
    }

    private static var requirementsKey: UInt8 = 0

    /// The recognizers `native` was made to wait for, held weakly.
    private static func requirements(of native: UIGestureRecognizer) -> NSHashTable<UIGestureRecognizer> {
        if let table = objc_getAssociatedObject(native, &requirementsKey) as? NSHashTable<UIGestureRecognizer> {
            return table
        }
        let table = NSHashTable<UIGestureRecognizer>.weakObjects()
        objc_setAssociatedObject(native, &requirementsKey, table, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return table
    }
}
