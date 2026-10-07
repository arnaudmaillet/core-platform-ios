import UIKit

/// A blur whose strength is a fraction (0…1) of its material — a paused
/// `UIViewPropertyAnimator` whose `fractionComplete` IS the strength.
///
/// - No material at init: an eager `UIBlurEffect` stalls a headless CI run;
///   it arrives with the first non-zero strength.
/// - Zero strength tears the animator down and hides the view: nothing to
///   render at rest.
/// - `pauseAnimation()` right after creation: an `.inactive` animator
///   silently ignores `fractionComplete`.
/// - ⚠️ Deallocating a paused or unfinished animator throws. Every engaged
///   animator is finished when the view goes, never left to die engaged.
/// - Never write this view's alpha (or animate an ancestor's): blur stops
///   rendering. Strength goes through `setStrength`, which does NOT animate
///   inside a `UIView.animate` block — a caller animating something else
///   drives the strength frame by frame.
public final class ProgressBlurView: UIVisualEffectView {
    private let style: UIBlurEffect.Style
    private var animator: UIViewPropertyAnimator?
    private let bag = AnimatorBag()

    /// The strength shown now (0…1).
    public private(set) var strength: CGFloat = 0

    public init(style: UIBlurEffect.Style) {
        self.style = style
        super.init(effect: nil)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setStrength(_ value: CGFloat) {
        let clamped = min(1, max(0, value))
        guard clamped != strength || (clamped > 0 && animator == nil) else { return }
        strength = clamped
        guard clamped > 0 else {
            if let animator {
                animator.stopAnimation(true) // → .inactive: safe to release
                bag.release(animator)
                self.animator = nil
            }
            effect = nil
            isHidden = true
            return
        }
        if animator == nil {
            isHidden = false
            let style = style
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                self?.effect = UIBlurEffect(style: style)
            }
            animator.pauseAnimation()
            bag.adopt(animator)
            self.animator = animator
        }
        animator?.fractionComplete = clamped
    }
}

/// Finishes every animator still engaged when its owner goes.
private final class AnimatorBag: @unchecked Sendable {
    private struct Orphans: @unchecked Sendable {
        let animators: [UIViewPropertyAnimator]
    }

    private var animators: [UIViewPropertyAnimator] = []

    func adopt(_ animator: UIViewPropertyAnimator) {
        animators.append(animator)
    }

    func release(_ animator: UIViewPropertyAnimator) {
        animators.removeAll { $0 === animator }
    }

    deinit {
        guard !animators.isEmpty else { return }
        let orphans = Orphans(animators: animators)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for animator in orphans.animators {
                    switch animator.state {
                    case .active:
                        animator.stopAnimation(false)
                        animator.finishAnimation(at: .current)
                    case .stopped:
                        animator.finishAnimation(at: .current)
                    default:
                        break
                    }
                }
            }
        }
    }
}
