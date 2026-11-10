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
    ///
    /// ⚠️ THE OUTGOING SCREEN FADES AS A PICTURE, NOT AS LIVE VIEWS (#2246).
    /// `UIView.transition(…, .transitionCrossDissolve)` dissolved the live
    /// navigation view, and Liquid Glass bar elements are drawn live: filmed
    /// at 60 fps on the search screen's Cancel, the field's glass refracted
    /// the map (the screen the pop had already put underneath) before the
    /// dissolve showed, its caret came back for the whole fade, and on a
    /// device the Cancel capsule morphed with its title clipped inside. So
    /// the outgoing navigation view is snapshotted as it last rendered and
    /// laid over it, the change runs as a `cut` underneath — the incoming
    /// screen, its bar included, is simply there as itself — and the
    /// picture fades out over the same duration. Nothing under the picture
    /// can glitch: nobody sees it until the picture is gone.
    func crossDissolve(duration: TimeInterval = 0.25, _ change: @escaping () -> Void) {
        guard let container = viewIfLoaded, container.window != nil else {
            change()
            return
        }
        guard let host = container.superview,
              let picture = CrossDissolvePicture.make(container) else {
            // No picture to fade (no host, or nothing rendered yet): UIKit's
            // own dissolve, as before.
            UIView.transition(with: container, duration: duration, options: [.transitionCrossDissolve]) {
                UIView.performWithoutAnimation(change)
            }
            return
        }
        picture.frame = container.frame
        picture.isUserInteractionEnabled = false
        host.insertSubview(picture, aboveSubview: container)
        cut(change)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            picture.alpha = 0
        } completion: { _ in
            picture.removeFromSuperview()
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

/// How `crossDissolve` takes its picture of the outgoing screen (#2246): the
/// navigation view as it last rendered. A seam for tests, where nothing has
/// rendered and a snapshot comes back empty.
@MainActor
enum CrossDissolvePicture {
    static var make: (UIView) -> UIView? = { $0.snapshotView(afterScreenUpdates: false) }
}
