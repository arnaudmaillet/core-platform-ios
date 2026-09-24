import UIKit

/// The one way a skeleton leaves and its content arrives (charter P10): a
/// cross-fade, never a pop.
///
/// ⚠️ **FOUR SCREENS WROTE THIS ANIMATION BEFORE IT LIVED HERE** — the media
/// picker, Notifications, the Search people page, the conversation list —
/// each with its own duration and its own idea of whether the bones are
/// hidden or removed afterwards. One helper, one duration, and a screen
/// that reimplements it is a review comment.
///
/// Two shapes:
///
/// - `fadeOut(removing:)` when the skeleton is a view laid over the content
///   (the common case): it fades to clear and is then hidden, or removed
///   when it is never coming back (a grid of shimmering layers under the
///   content would keep animating for nothing).
/// - `crossfade(to:)` when the skeleton and the content are two views that
///   swap: both animate in the one block, so there is no frame with neither.
///
/// Both are safe to call when nothing is showing: a hidden skeleton is left
/// alone, and calling twice while the fade runs restarts it from where it is.
public extension UIView {
    /// The settled duration of a skeleton's exit.
    static let skeletonFadeDuration: TimeInterval = 0.25

    /// Fades this view (the skeleton) out; hides it afterwards, or removes
    /// it from its superview when `removing`.
    func fadeOutSkeleton(removing: Bool = false) {
        guard !isHidden, superview != nil else { return }
        UIView.animate(withDuration: Self.skeletonFadeDuration, delay: 0, options: [.beginFromCurrentState]) {
            self.alpha = 0
        } completion: { _ in
            // A reveal that started while the fade ran has already put the
            // alpha back; leave it.
            guard self.alpha == 0 else { return }
            if removing {
                self.removeFromSuperview()
            } else {
                self.isHidden = true
            }
        }
    }

    /// Shows this view (the skeleton) again, whole, for a fresh load.
    func showSkeleton() {
        isHidden = false
        alpha = 1
    }

    /// Fades this view (the skeleton) out while `content` fades in, in one
    /// block: the content is unhidden and brought from clear to opaque.
    func crossfadeSkeleton(to content: UIView) {
        content.isHidden = false
        if content.alpha == 1, isHidden { return }
        content.alpha = 0
        UIView.animate(withDuration: Self.skeletonFadeDuration, delay: 0, options: [.beginFromCurrentState]) {
            self.alpha = 0
            content.alpha = 1
        } completion: { _ in
            guard self.alpha == 0 else { return }
            self.isHidden = true
        }
    }
}
