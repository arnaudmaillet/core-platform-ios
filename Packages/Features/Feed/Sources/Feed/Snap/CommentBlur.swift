import UIKit

/// ⚠️ EXPERIMENTAL (#560): the media page's comment surfaces — the reaction
/// band's kinetic backdrop and the subtitle pills — on a blur material
/// instead of a black wash, behind a launch argument. Off — the default, and
/// always in Release — everything is today's wash, unchanged. Behaviour,
/// timing and curves are the same either way; only the material changes.
enum CommentBlur {
    static let launchArgument = "-comment-blur"

    /// Whether `arguments` ask for the blur. Release builds never do.
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for it — the default the surfaces take;
    /// tests set theirs per view instead (a process-wide switch would leak
    /// across parallel suites).
    static let isEnabled = isEnabled(arguments: ProcessInfo.processInfo.arguments)

    /// The band's blur strength (0…1) for the wash's opacity: the larger of
    /// the interaction's fraction and the resting level, over the wash's
    /// ceiling — so the blur grows, holds and relaxes on the wash's own curve.
    static func bandStrength(fraction: CGFloat, resting: CGFloat, ceiling: CGFloat) -> CGFloat {
        guard ceiling > 0 else { return 0 }
        return min(1, max(0, max(fraction, resting)) / ceiling)
    }

    /// The fill setting's top (Settings: 0…0.9).
    static let pillFillCeiling: CGFloat = 0.9

    /// A pill's blur strength (0…1) for the viewer's fill setting.
    static func pillStrength(fill: CGFloat) -> CGFloat {
        min(1, max(0, fill) / pillFillCeiling)
    }
}

/// A blur whose strength is a fraction of its material: a paused
/// `UIViewPropertyAnimator` whose `fractionComplete` IS the strength (the
/// standard variable-blur technique, and the band's own before #488).
///
/// - Zero strength tears the animator down and hides the view: no render
///   cost at rest.
/// - `pauseAnimation()` right after creation: an `.inactive` animator
///   silently ignores `fractionComplete`.
/// - ⚠️ Deallocating a paused or unfinished animator throws, and a cell can
///   be reused mid-drag: every live animator is finished when the view goes
///   (`deinit` → `AnimatorBag`), never left to die engaged.
/// - Never fade this view's alpha (or an ancestor's): blur stops rendering.
///   Strength changes go through `setStrength` / `tween`.
final class CommentBlurView: UIVisualEffectView {
    private let style: UIBlurEffect.Style
    private var animator: UIViewPropertyAnimator?
    private let bag = AnimatorBag()
    private var tween: Tween?
    private var link: CADisplayLink?

    /// The strength shown now (0…1).
    private(set) var strength: CGFloat = 0

    init(style: UIBlurEffect.Style) {
        self.style = style
        // No effect at init: an eager `UIBlurEffect` stalls a headless CI
        // run for tens of seconds. The material arrives with the first
        // non-zero strength.
        super.init(effect: nil)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the strength at once, cancelling any tween.
    func setStrength(_ value: CGFloat) {
        stopTween()
        apply(value)
    }

    /// Moves to `target` over `duration` after `delay`, ease-out — the curve
    /// the wash's alpha animations use.
    func tween(to target: CGFloat, duration: TimeInterval, delay: TimeInterval = 0, completion: (() -> Void)? = nil) {
        stopTween()
        guard duration > 0 || delay > 0 else {
            apply(target)
            completion?()
            return
        }
        tween = Tween(from: strength, to: target, start: CACurrentMediaTime() + delay, duration: duration, completion: completion)
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func step(at time: CFTimeInterval) {
        guard let tween else { return }
        guard time >= tween.start else { return }
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

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopTween() }
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
        weak var view: CommentBlurView?
        init(_ view: CommentBlurView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view else {
                link.invalidate()
                return
            }
            view.step(at: link.targetTimestamp)
        }
    }
}

/// Finishes every animator still engaged when its owner goes — a paused or
/// unfinished `UIViewPropertyAnimator` throws when deallocated.
private final class AnimatorBag: @unchecked Sendable {
    private struct Orphans: @unchecked Sendable {
        let animators: [UIViewPropertyAnimator]
    }

    private var animators: [UIViewPropertyAnimator] = []

    func adopt(_ animator: UIViewPropertyAnimator) {
        animators.append(animator)
    }

    /// Once an animator is safe to let go (stopped → `.inactive`).
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
