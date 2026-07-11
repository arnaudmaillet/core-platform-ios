import CoreNavigation
import UIKit

/// Drives one leg of the hero/zoom transition with a single *flying card*: a
/// `PinCardView` — the very component the map pin renders — carrying the media
/// plus a live replica of the destination's UI chrome. The card's **frame**
/// animates between the pin's rect and full screen, so both endpoints are
/// exact by construction: at the pin end the card *is* a pin (56pt square,
/// 12pt round corners, 2pt ring, square aspect-fill crop, drop shadow), at the
/// screen end it *is* the page (full-bleed, display-corner radius). Between
/// them the crop morphs — no anisotropic squash, no elliptical corners.
///
/// A live-previewing pin flies *live*: its pooled player is mirrored onto the
/// card's own render surface (two `AVPlayerLayer`s, one player, one clock), so
/// tapping an animating pin never freezes it. The video layer is laid out once
/// at destination size and driven by a uniform-scale transform, because an
/// `AVPlayerLayer` does not track a bounds animation smoothly.
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
    private let source: MapPinZoomSource
    private weak var destination: (any ZoomTransitionDestination)?
    private let duration: TimeInterval = 0.42
    /// How far the presenting map recedes during the flight (depth cue).
    private static let mapDepthScale: CGFloat = 0.95

    init(isPresenting: Bool, source: MapPinZoomSource, destination: any ZoomTransitionDestination) {
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

        let pinFrame = source.zoomHeroFrame(in: container)
        let pageFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds

        // The feed's *content* hides for the flight — the card is its
        // stand-in — but the presented container stays visible and clear, so
        // the real navigation bar keeps its native screen-space layout from
        // frame 0 and never pops or morphs. The card flies beneath it.
        destination?.setZoomContentHidden(true)
        toView.backgroundColor = .clear

        let flight = makeFlight(pinFrame: pinFrame, pageFrame: pageFrame)
        container.insertSubview(flight.card, belowSubview: toView)
        container.insertSubview(flight.shadow, belowSubview: flight.card)
        // Resolve the chrome replica's full-screen layout (safe areas, text
        // wrapping) while the card still spans the page; its bounds never
        // change again, so nothing can relayout mid-flight.
        container.layoutIfNeeded()

        // Pose the card as the pin and swap the real pin for it inside this
        // same transaction: the twin is pixel-identical (same component, same
        // ring, same crop, live video mirrored), so no frame can render a
        // mismatch — or both pins, or neither.
        flight.poseAsPin()
        source.hideSourcePin()

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
            // Lands flush with the device's own display corners, so the reveal
            // of the (screen-clipped) feed underneath is seamless.
            flight.poseAsPage(cornerRadius: screenRadius)
        } completion: { _ in
            self.destination?.setZoomContentHidden(false)
            flight.card.removeFromSuperview()
            flight.shadow.removeFromSuperview()
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

        let pageFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds
        let pinFrame = source.zoomHeroFrame(in: container)

        // Dim starts opaque (fully presented) and lifts to reveal the map as
        // the card shrinks.
        let dim = Self.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let flight = makeFlight(pinFrame: pinFrame, pageFrame: pageFrame)
        container.insertSubview(flight.card, belowSubview: fromView)
        container.insertSubview(flight.shadow, belowSubview: flight.card)
        container.layoutIfNeeded()
        // Starts flush with the device's own display corners (visually identical
        // to the screen-clipped feed it replaces); rounds back to the pin.
        let screenRadius = Self.screenCornerRadius(behind: container)
        flight.poseAsPage(cornerRadius: screenRadius)
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
        // unit: card shrinks + rounds + regrows its ring and shadow, chrome
        // fades, dim lifts, map returns.
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            flight.poseAsPin()
            dim.alpha = 0
            presentingView?.transform = .identity
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            flight.card.removeFromSuperview()
            flight.shadow.removeFromSuperview()
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

    // MARK: - Flight

    /// The flying unit and its two poses. Every property that differs between
    /// the poses is UIView-animatable, so setting a pose inside an animation
    /// block sweeps the whole card — frame, radius, ring, shadow, chrome,
    /// video scale — as one scrubable unit. Frame, center, and transform all
    /// interpolate linearly in the same animation parameter, so the chrome and
    /// video layers stay exactly full-bleed within the morphing card on every
    /// frame ("lockstep" is a property of the math, not of synchronized
    /// clocks).
    private struct Flight {
        let card: PinCardView
        let chrome: UIView?
        /// Stand-in for the pin's drop shadow (the card clips, so it can't
        /// cast one itself). Fixed at the pin rect; fades out as the card
        /// leaves and back in as it returns.
        let shadow: UIView
        let pinFrame: CGRect
        let pageFrame: CGRect

        /// Exact twin of the annotation at its map rect: pin radius, ring and
        /// shadow visible, media cropped to the pin square, chrome invisible.
        func poseAsPin() {
            card.frame = pinFrame
            card.setCornerRadius(PinCardView.cornerRadius)
            card.ringView.alpha = 1
            shadow.alpha = 1
            let center = CGPoint(x: pinFrame.width / 2, y: pinFrame.height / 2)
            if !card.videoRenderView.isHidden {
                let scale = PinCardView.videoFlightScale(covering: pinFrame.size, surface: pageFrame.size)
                card.videoRenderView.transform = CGAffineTransform(scaleX: scale, y: scale)
                card.videoRenderView.center = center
            }
            if let chrome {
                chrome.transform = CGAffineTransform(
                    scaleX: pinFrame.width / pageFrame.width,
                    y: pinFrame.height / pageFrame.height
                )
                chrome.center = center
                chrome.alpha = 0
            }
        }

        /// Exact stand-in for the landed page: full-bleed, display-corner
        /// radius, pin chrome gone, page chrome fully readable.
        func poseAsPage(cornerRadius: CGFloat) {
            card.frame = pageFrame
            card.setCornerRadius(cornerRadius)
            card.ringView.alpha = 0
            shadow.alpha = 0
            let center = CGPoint(x: pageFrame.width / 2, y: pageFrame.height / 2)
            if !card.videoRenderView.isHidden {
                card.videoRenderView.transform = .identity
                card.videoRenderView.center = center
            }
            if let chrome {
                chrome.transform = .identity
                chrome.center = center
                chrome.alpha = 1
            }
        }
    }

    /// Builds the card in page pose (so the chrome replica can resolve its
    /// full-screen layout before the first frame) plus its shadow stand-in.
    private func makeFlight(pinFrame: CGRect, pageFrame: CGRect) -> Flight {
        let card = source.makeFlightCard()
        card.frame = pageFrame
        card.isUserInteractionEnabled = false
        if !card.videoRenderView.isHidden {
            card.prepareVideoForFlight(destinationSize: pageFrame.size)
        }

        let chrome = destination?.zoomFlightChrome()
        if let chrome {
            chrome.autoresizingMask = []
            chrome.bounds = CGRect(origin: .zero, size: pageFrame.size)
            chrome.center = CGPoint(x: pageFrame.width / 2, y: pageFrame.height / 2)
            // Below the ring: at the pin end the ring must read as the pin's
            // border over everything, exactly as on the map.
            card.insertSubview(chrome, belowSubview: card.ringView)
        }

        let shadow = UIView(frame: pinFrame)
        shadow.backgroundColor = .clear
        shadow.isUserInteractionEnabled = false
        PinCardView.applyPinShadow(to: shadow.layer)
        // A clear view casts nothing on its own; the explicit path draws the
        // pin's silhouette.
        shadow.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: pinFrame.size),
            cornerRadius: PinCardView.cornerRadius
        ).cgPath
        return Flight(card: card, chrome: chrome, shadow: shadow, pinFrame: pinFrame, pageFrame: pageFrame)
    }

    // MARK: - Receded map chrome

    /// Rounds the receding map like a system card. The radius is *constant* —
    /// set while the view is still bezel-aligned (invisible at scale 1, since
    /// the display already clips this exact curve) — and the depth transform
    /// then renders it as `scale × radius` on every frame, spring overshoot
    /// and interactive scrubs included. Proportional corner curvature with
    /// nothing to synchronize.
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
