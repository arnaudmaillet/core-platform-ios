import UIKit

@MainActor
public extension UINavigationController {
    /// Runs a stack change — a push, a pop — as a CROSS-DISSOLVE of the whole
    /// navigation view, bar included, instead of UIKit's slide.
    ///
    /// ## Why not `animated: true`
    ///
    /// The global search screen arrives and leaves as a dissolve: it is a
    /// field and a keyboard, not a place, and a slide reads as travel. UIKit's
    /// navigation controller offers exactly one built-in transition, the
    /// slide, and every other look goes through a `UINavigationControllerDelegate`
    /// animator — a slot this app's tab stacks leave EMPTY at rest and lend to
    /// flight and slide drivers while a hero is up, with forwarding rules
    /// (`InteractiveSlideDismissal.savedDelegate`) that a permanent occupant
    /// would have to honour. `UIView.transition(with:options:.transitionCrossDissolve)`
    /// is the native alternative that needs no delegate: it snapshots the
    /// view, applies the change, and dissolves between the two.
    ///
    /// ⚠️ THE CHANGE RUNS INSIDE `performWithoutAnimation`. On iOS 26 an
    /// `animated: false` push still animated the controller's wrapper frame
    /// from a smaller rect to the screen (~0.3s, filmed as the content
    /// growing out of the top-left corner). The dissolve is the container's
    /// transition and survives animations being disabled for the block; the
    /// implicit frame animation does not.
    func crossDissolve(duration: TimeInterval = 0.25, _ change: @escaping () -> Void) {
        guard let container = viewIfLoaded, container.window != nil else {
            change()
            return
        }
        UIView.transition(with: container, duration: duration, options: [.transitionCrossDissolve]) {
            UIView.performWithoutAnimation(change)
        }
    }

    /// Runs a stack change as a CUT: the new top is simply there.
    ///
    /// ⚠️ `animated: false` ALONE IS NOT A CUT ON iOS 26 — see `crossDissolve`:
    /// the unanimated push still animated the wrapper's frame from a smaller
    /// rect, filmed as the screen growing out of the top-left corner. This is
    /// the same guard, for the stack changes that want no dissolve either: the
    /// change runs with view animations off, and the navigation view is laid
    /// out in the same breath so the arriving screen's first pass cannot be
    /// picked up by whatever animates next (a keyboard rising, a bar hiding —
    /// both measured doing exactly that, see `-first-layout-trace`).
    func cut(_ change: () -> Void) {
        UIView.performWithoutAnimation {
            change()
            viewIfLoaded?.layoutIfNeeded()
        }
    }
}
