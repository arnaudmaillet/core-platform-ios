import CoreNavigation
import UIKit

/// Drives one leg of the hero/zoom transition with a single *flying card*: one
/// view holding both the media thumbnail and a live replica of the
/// destination's UI chrome, animated by one transform from the pin's rect to
/// full screen (present) or back (dismiss). Because media and chrome share
/// that one matrix, they are geometrically incapable of drifting — "lockstep"
/// is a property of the hierarchy, not of synchronized clocks.
///
/// The destination's *content* hides during the flight and is revealed only
/// at landing, when the card covers the screen exactly (same chrome scaffold,
/// same layout), so the swap is invisible — while the presented container
/// stays visible and clear so the real navigation bar keeps its native
/// screen-space layout above the flight from frame 0 (bar chrome is rigid; it
/// never scales, morphs, or pops). Nothing mutates the live feed mid-flight.
/// The same animator serves both directions via `isPresenting`, and
/// percent-driven interactive dismissal scrubs its single animation block;
/// the completion honours `transitionWasCancelled`.
@MainActor
final class MapsZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let source: any ZoomTransitionSource
    private weak var destination: (any ZoomTransitionDestination)?
    private let duration: TimeInterval = 0.42
    /// How far the presenting map recedes during the flight (depth cue).
    private static let mapDepthScale: CGFloat = 0.95
    /// The corner radius the card *renders* at the pin end of a flight
    /// (matches `MapAnnotationView`/`MapPinZoomSource`). The value actually set
    /// on the layer is scale-compensated, because the flight transform scales
    /// the rendered radius along with the card.
    private static let pinCornerRadius: CGFloat = 12

    init(isPresenting: Bool, source: any ZoomTransitionSource, destination: any ZoomTransitionDestination) {
        self.isPresenting = isPresenting
        self.source = source
        self.destination = destination
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        duration
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        if isPresenting { present(context) } else { dismiss(context) }
    }

    // MARK: - Present

    private func present(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
        }
        // Dims the map around the flying card; tail-weighted so the map reads
        // through for most of the flight and recedes to black as the card lands.
        let dim = Self.makeDimView(frame: container.bounds)
        container.addSubview(dim)

        toView.frame = container.bounds
        container.addSubview(toView)
        // Lay the feed out now: it kicks content hydration and settles the safe
        // areas the card's chrome replica bakes in below.
        container.layoutIfNeeded()

        let startFrame = source.zoomHeroFrame(in: container)
        let targetFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds

        // The feed's *content* hides for the flight — the card is its
        // stand-in — but the presented container stays visible and clear, so
        // the real navigation bar keeps its native screen-space layout from
        // frame 0 and never pops or morphs. The card flies beneath it.
        destination?.setZoomContentHidden(true)
        toView.backgroundColor = .clear

        let card = Self.makeFlightCard(
            frame: targetFrame,
            media: source.zoomHeroSnapshot(),
            chrome: destination?.zoomFlightChrome()
        )
        container.insertSubview(card.view, belowSubview: toView)
        // Resolve the replica's full-screen layout (safe areas, text wrapping)
        // while the card is still untransformed, then freeze it: from here the
        // flight is transform-only, so nothing can relayout mid-flight.
        container.layoutIfNeeded()
        card.view.transform = ZoomTransitionGeometry.collapseTransform(of: targetFrame, onto: startFrame)
        card.view.layer.cornerRadius = ZoomTransitionGeometry.compensatedCornerRadius(
            rendering: Self.pinCornerRadius, of: targetFrame, onto: startFrame
        )
        card.chrome?.alpha = 0
        let screenRadius = Self.screenCornerRadius(behind: container)

        // Depth cue: the presenting map recedes to 0.95 with a gentle spring, so
        // the feed reads as lifting off a 3D canvas. (`view(forKey:)` is nil under
        // an over-full-screen present, so reach the root via the view controller.)
        let presentingView = context.viewController(forKey: .from)?.view
        Self.applyRecededChrome(to: presentingView, radius: screenRadius)
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0, options: [.curveEaseInOut]) {
            presentingView?.transform = CGAffineTransform(scaleX: Self.mapDepthScale, y: Self.mapDepthScale)
        }

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            card.view.transform = .identity
            // Lands flush with the device's own display corners, so the reveal
            // of the (screen-clipped) feed underneath is seamless.
            card.view.layer.cornerRadius = screenRadius
            card.chrome?.alpha = 1
        } completion: { _ in
            self.destination?.setZoomContentHidden(false)
            card.view.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            Self.clearRecededChrome(from: presentingView) // covered by the opaque feed
            self.destination?.zoomTransitionDidEnd()
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    // MARK: - Dismiss

    private func dismiss(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return
        }
        // The map (`.to`) stays visible under an over-full-screen present, but
        // make sure it sits behind the departing card.
        if let toView = context.view(forKey: .to) {
            container.insertSubview(toView, at: 0)
        }

        let startFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds
        let endFrame = source.zoomHeroFrame(in: container)

        // Dim starts opaque (fully presented) and lifts to reveal the map as
        // the card shrinks.
        let dim = Self.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let card = Self.makeFlightCard(
            frame: startFrame,
            media: source.zoomHeroSnapshot(),
            chrome: destination?.zoomFlightChrome()
        )
        // Starts flush with the device's own display corners (visually identical
        // to the screen-clipped feed it replaces); rounds back to the pin.
        let screenRadius = Self.screenCornerRadius(behind: container)
        card.view.layer.cornerRadius = screenRadius
        container.insertSubview(card.view, belowSubview: fromView)
        container.layoutIfNeeded()
        // The card (same chrome scaffold, same layout) replaces the feed's
        // *content* — pixel-invisible swap — while the presented container
        // stays visible and clear, so the real navigation bar keeps rendering
        // natively above the shrinking card. Restored on a cancelled grab.
        destination?.setZoomContentHidden(true)
        fromView.backgroundColor = .clear

        // Reverse depth cue: the map starts receded (0.95, covered) and scales
        // back to full as the card shrinks — scrubs with the grab.
        let presentingView = context.viewController(forKey: .to)?.view
        Self.applyRecededChrome(to: presentingView, radius: screenRadius)
        presentingView?.transform = CGAffineTransform(scaleX: Self.mapDepthScale, y: Self.mapDepthScale)

        // Everything inside one block so the interactive grab scrubs it as a
        // unit: card shrinks + rounds, its chrome fades, dim lifts, map returns.
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            card.view.transform = ZoomTransitionGeometry.collapseTransform(of: startFrame, onto: endFrame)
            card.view.layer.cornerRadius = ZoomTransitionGeometry.compensatedCornerRadius(
                rendering: Self.pinCornerRadius, of: startFrame, onto: endFrame
            )
            card.chrome?.alpha = 0
            dim.alpha = 0
            presentingView?.transform = .identity
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            card.view.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            Self.clearRecededChrome(from: presentingView) // bezel-aligned again at scale 1
            // Restore the feed content for the cancel path; moot when finished.
            self.destination?.setZoomContentHidden(false)
            self.destination?.zoomTransitionDidEnd()
            if !cancelled {
                self.source.zoomSourceDidReturn()
            }
            context.completeTransition(!cancelled)
        }
    }

    // MARK: - Flight card

    /// The single flying unit: `view` clips and rounds like a physical card;
    /// `chrome` is retained separately only so the animator can fade it.
    private struct FlightCard {
        let view: UIView
        let chrome: UIView?
    }

    /// Builds the card: black backing (letterboxing), the media thumbnail
    /// full-bleed, and the destination's chrome replica full-bleed above it —
    /// the same z-order as the landed page.
    private static func makeFlightCard(frame: CGRect, media: UIView?, chrome: UIView?) -> FlightCard {
        let card = UIView(frame: frame)
        card.backgroundColor = .black
        card.clipsToBounds = true
        // Each leg sets its own starting radius; continuous matches both the
        // pin thumbnail and the display's corner curve.
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        if let media {
            media.frame = card.bounds
            media.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            media.layer.cornerRadius = 0 // the card owns the rounding
            card.addSubview(media)
        }
        if let chrome {
            chrome.frame = card.bounds
            chrome.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            card.addSubview(chrome)
        }
        return FlightCard(view: card, chrome: chrome)
    }

    // MARK: - Receded map chrome

    /// Rounds the receding map like a system card. The radius is *constant* —
    /// set while the view is still bezel-aligned (invisible at scale 1, since
    /// the display already clips this exact curve) — and the depth transform
    /// then renders it as `scale × radius` on every frame, spring overshoot
    /// and interactive scrubs included. Proportional corner curvature with
    /// nothing to synchronize; same principle as the flight card's
    /// compensated radius, in reverse.
    private static func applyRecededChrome(to view: UIView?, radius: CGFloat) {
        guard let view else { return }
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
    }

    /// Cleared only while the reset is undetectable: under the opaque feed
    /// (present) or back at scale 1, where the bezel clips the same curve
    /// (dismiss).
    private static func clearRecededChrome(from view: UIView?) {
        guard let view else { return }
        view.layer.cornerRadius = 0
        view.layer.masksToBounds = false
    }

    // MARK: - Screen corner radius

    /// The physical display's corner radius, so the card's corners land flush
    /// on the device's own — dynamic because it differs per model (0 on
    /// square-cornered devices, ~39–62 across the notch/Dynamic Island fleet).
    ///
    /// Read via KVC from UIKit's undocumented `_displayCornerRadius` (the key
    /// is assembled, and guarded by `responds(to:)` so a future rename
    /// degrades to the fallback instead of throwing). Fallback: any device
    /// with a home indicator has rounded corners (44 is mid-fleet and close
    /// enough for a 0.42s flight); everything else is square.
    private static func screenCornerRadius(behind view: UIView) -> CGFloat {
        guard let window = view.window else { return 0 }
        let key = ["_display", "Corner", "Radius"].joined()
        if window.screen.responds(to: NSSelectorFromString(key)),
           let radius = window.screen.value(forKey: key) as? CGFloat, radius > 0 {
            return radius
        }
        return window.safeAreaInsets.bottom > 0 ? 44 : 0
    }

    // MARK: - Dim

    /// A black view, initially transparent, that dims the source (map) behind
    /// the flying card — decoupled from the card so each interpolates on its
    /// own terms.
    private static func makeDimView(frame: CGRect) -> UIView {
        let dim = UIView(frame: frame)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        return dim
    }
}
