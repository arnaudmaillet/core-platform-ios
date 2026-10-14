import UIKit

/// The app's one appear / disappear motion (#1151), shared by `AppButton`
/// and every view that comes and goes the same way (the paused clip's play
/// mark): a BOUNCE IN from smaller while it fades in; a SCALE OUT while it
/// fades out; a plain fade both ways under Reduce Motion.
///
/// ⚠️ THE FROM-VALUE (`uiview-animate-from-value-trap`). `.beginFromCurrentState`
/// takes it from the PRESENTATION layer, so a from-value staged in the same
/// turn — `alpha = 0`, then animate to 1 — has never rendered, and a plain
/// fade runs end to end, invisible. So:
/// - from rest, the from-values are staged and the animation starts from the
///   MODEL (no `.beginFromCurrentState`);
/// - mid-flight (a pause → play → pause inside the motion), nothing is staged
///   and the animation starts from where the view IS — it reverses, never
///   jumps or restarts from zero.
public enum AppearMotion {
    /// What a motion turned out to be — the decision a test reads.
    public enum Kind: Equatable, Sendable {
        case bounceIn, fadeIn, scaleOut, fadeOut
    }

    /// The bounce-in's starting scale, and the scale-out's end.
    public static let appearScale: CGFloat = 0.6
    public static let appearDuration: TimeInterval = 0.42
    public static let appearBounce: CGFloat = 0.32
    public static let disappearDuration: TimeInterval = 0.24
    /// The Reduce Motion fade, both ways.
    public static let fadeDuration: TimeInterval = 0.22

    /// Whether `view` is in the middle of a motion: a from-value must then
    /// come from the screen, not be staged.
    @MainActor static func isInFlight(_ view: UIView) -> Bool {
        let keys = view.layer.animationKeys() ?? []
        return keys.contains { $0.contains("opacity") || $0.contains("transform") }
    }

    /// Brings `view` in. `alongside` runs inside the animation (a stack
    /// making room); the caller has made the view visible, or does it there.
    @MainActor @discardableResult
    public static func appear(
        _ view: UIView, reducesMotion: Bool, alongside: @escaping () -> Void = {}
    ) -> Kind {
        let inFlight = isInFlight(view)
        if !inFlight {
            view.alpha = 0
            if !reducesMotion { view.transform = CGAffineTransform(scaleX: appearScale, y: appearScale) }
        }
        let options: UIView.AnimationOptions = inFlight
            ? [.allowUserInteraction, .beginFromCurrentState]
            : [.allowUserInteraction]
        if reducesMotion {
            UIView.animate(withDuration: fadeDuration, delay: 0, options: options) {
                view.alpha = 1
                view.transform = .identity
                alongside()
            }
            return .fadeIn
        }
        UIView.animate(springDuration: appearDuration, bounce: appearBounce, options: options) {
            view.alpha = 1
            view.transform = .identity
            alongside()
        }
        return .bounceIn
    }

    /// Takes `view` out: scaled down and faded (faded only under Reduce
    /// Motion), with an ease-in. `completion` gets whether the motion ran to
    /// its end — false when an appear took over mid-flight, in which case
    /// the view must stay.
    @MainActor @discardableResult
    public static func disappear(
        _ view: UIView, reducesMotion: Bool, alongside: @escaping () -> Void = {},
        completion: @escaping (Bool) -> Void = { _ in }
    ) -> Kind {
        let options: UIView.AnimationOptions = isInFlight(view)
            ? [.curveEaseIn, .beginFromCurrentState]
            : [.curveEaseIn]
        UIView.animate(
            withDuration: reducesMotion ? fadeDuration : disappearDuration, delay: 0, options: options
        ) {
            view.alpha = 0
            if !reducesMotion { view.transform = CGAffineTransform(scaleX: appearScale, y: appearScale) }
            alongside()
        } completion: { finished in
            completion(finished)
        }
        return reducesMotion ? .fadeOut : .scaleOut
    }
}
