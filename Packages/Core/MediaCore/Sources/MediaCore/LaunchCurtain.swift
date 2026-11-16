import UIKit

/// The launch screen faded out over the shell (#1812, the owner 2026-10-28).
///
/// A hard cut from the launch screen to the shell showed the shell's first
/// layout in one frame. The shell is installed UNDER the launch view instead,
/// laid out, and the launch view fades out over it.
///
/// It once waited for Shots' first post to have its picture, with a 2 s cap.
/// The app opens on the map since #2453, so it lifts as soon as the shell is
/// in: the map draws its own tiles and loaders.
///
/// ⚠️ THE SHELL IS NEVER HIDDEN UNDER IT. The curtain is a view over the
/// shell, never an `isHidden` or `alpha = 0` on it.
@MainActor
public enum LaunchCurtain {
    /// The fade: ease-out, no zoom.
    public static let fadeDuration: TimeInterval = 0.3

    /// Puts `curtain` over `window`'s new root and fades it out at once; it
    /// leaves the window once faded. `owner` (what drives the curtain's own
    /// loader, `LaunchViewController`) lives until then.
    public static func lift(_ curtain: UIView, over window: UIWindow, owner: AnyObject) {
        curtain.frame = window.bounds
        curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(curtain)
        LaunchTimeline.mark("launch.revealed")
        UIView.animate(withDuration: fadeDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            curtain.alpha = 0
        } completion: { _ in
            curtain.removeFromSuperview()
            withExtendedLifetime(owner) {}
        }
    }
}
