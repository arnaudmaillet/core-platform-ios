import Foundation

/// WHEN THE MAP'S PREVIEWS COME BACK AS A SCREEN OVER IT LEAVES (#1594).
///
/// UIKit runs the map's `viewWillAppear` the moment a pop BEGINS — for an
/// interactive one, the first millimetre of a grab. Resuming the previews
/// there woke the video surface behind the place page under the finger: the
/// surface the post's flight had grown to full screen, faded in by the dim
/// lifting with the grab, and visible even when the grab was let go short
/// (the owner's video, 2026-10-22). The map is what the close REVEALS, so it
/// comes back with the release that commits it — never while the finger is
/// down, never for a grab that springs back.
@MainActor
enum MapPreviewResume {
    /// Calls `resume` now for an ordinary appearance; for an interactive one,
    /// once the interaction ends committed — and never if it is cancelled.
    ///
    /// - Parameters:
    ///   - isInteractive: the appearance is a transition still under a finger.
    ///   - notifyWhenInteractionEnds: hands over a handler told whether the
    ///     interaction ended CANCELLED (`transitionCoordinator`'s
    ///     `notifyWhenInteractionChanges`).
    static func whenSettled(
        isInteractive: Bool,
        notifyWhenInteractionEnds: (@escaping (_ cancelled: Bool) -> Void) -> Void,
        resume: @escaping () -> Void
    ) {
        guard isInteractive else {
            resume()
            return
        }
        notifyWhenInteractionEnds { cancelled in
            guard !cancelled else { return }
            resume()
        }
    }
}
