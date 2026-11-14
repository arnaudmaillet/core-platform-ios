import UIKit

/// A blur whose strength is a fraction (0…1) of its material — a paused
/// `UIViewPropertyAnimator` whose `fractionComplete` IS the strength. The
/// drawer's veil and the media page's subtitle pills (`-comment-blur`) wear
/// it; Feed carried a copy with a tween until #2390.
///
/// - No material at init: an eager `UIBlurEffect` stalls a headless CI run;
///   it arrives with the first non-zero strength.
/// - Zero strength tears the animator down and hides the view: nothing to
///   render at rest.
/// - `pauseAnimation()` right after creation: an `.inactive` animator
///   silently ignores `fractionComplete`.
/// - ⚠️ Deallocating a paused or unfinished animator throws, and a cell can
///   be reused mid-drag: every engaged animator is finished when the view
///   goes, never left to die engaged.
/// - Never write this view's alpha (or animate an ancestor's): blur stops
///   rendering. Strength goes through `setStrength` or `tween`;
///   `setStrength` does NOT animate inside a `UIView.animate` block — a
///   caller animating something else drives the strength frame by frame, or
///   tweens it.
public final class ProgressBlurView: UIVisualEffectView {
    private let style: UIBlurEffect.Style
    private var animator: UIViewPropertyAnimator?
    private let bag = AnimatorBag()
    private var tween: Tween?
    private var link: CADisplayLink?

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

    /// Sets the strength at once, cancelling any tween.
    public func setStrength(_ value: CGFloat) {
        stopTween()
        apply(value)
    }

    /// Moves to `target` over `duration` after `delay`, ease-out (cubic).
    public func tween(
        to target: CGFloat, duration: TimeInterval, delay: TimeInterval = 0, completion: (() -> Void)? = nil
    ) {
        stopTween()
        guard duration > 0 || delay > 0 else {
            apply(target)
            completion?()
            return
        }
        tween = Tween(
            from: strength, to: target, start: CACurrentMediaTime() + delay, duration: duration,
            completion: completion
        )
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopTween() }
    }

    fileprivate func step(at time: CFTimeInterval) {
        guard let tween, time >= tween.start else { return }
        let progress = tween.duration > 0 ? min(1, (time - tween.start) / tween.duration) : 1
        let eased = 1 - pow(1 - progress, 3)
        apply(tween.from + (tween.to - tween.from) * CGFloat(eased))
        if progress >= 1 {
            let completion = tween.completion
            stopTween()
            completion?()
        }
    }

    private func stopTween() {
        link?.invalidate()
        link = nil
        tween = nil
    }

    private func apply(_ value: CGFloat) {
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

    private struct Tween {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: TimeInterval
        let completion: (() -> Void)?
    }

    /// Breaks the display link → target retain cycle. Main-actor: the link
    /// is scheduled on the main run loop, so its ticks arrive there.
    @MainActor
    private final class WeakTarget: NSObject {
        weak var view: ProgressBlurView?

        init(_ view: ProgressBlurView) { self.view = view }

        @objc func tick(_ link: CADisplayLink) {
            guard let view else {
                link.invalidate()
                return
            }
            view.step(at: link.targetTimestamp)
        }
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
