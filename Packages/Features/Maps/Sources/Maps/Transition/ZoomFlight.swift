import CoreNavigation
import UIKit

/// The flying unit shared by both dismissal drivers — the non-interactive
/// `MapsZoomAnimator` and the interactive grab (`ZoomDismissInteractionController`)
/// — plus the stage dressing they set identically (dim, receded map chrome,
/// display corner radius). One veneer factory, two choreographies: however a
/// dismissal is driven, the card, shadow, ring, and pin handshake are the
/// same objects posed by the same code.
///
/// Every property that differs between poses is UIView-animatable, so setting
/// a pose inside an animation block sweeps the whole card — frame, radius,
/// ring, shadow, chrome, video scale — as one unit. Frame, center, and
/// transform all interpolate linearly in the same animation parameter, so the
/// chrome and video layers stay exactly full-bleed within the morphing card
/// on every frame ("lockstep" is a property of the math, not of synchronized
/// clocks).
@MainActor
struct ZoomFlight {
    let card: PinCardView
    let chrome: UIView?
    /// Stand-in for the pin's drop shadow (the card clips, so it can't cast
    /// one itself). Fixed at the pin rect; fades out as the card leaves and
    /// back in as it returns.
    let shadow: UIView
    let pinFrame: CGRect
    let pageFrame: CGRect

    /// How far the presenting map recedes behind a flight (depth cue).
    static let mapDepthScale: CGFloat = 0.95
    /// Grab feedback: the card's scale the instant a dismissal starts — it
    /// visibly detaches from the screen canvas before flying home.
    static let detachScale: CGFloat = 0.95

    /// Builds the card in page pose (so the chrome replica can resolve its
    /// full-screen layout before the first frame) plus its shadow stand-in.
    /// The caller inserts both into the container and lays out.
    static func build(
        source: MapPinZoomSource,
        destination: (any ZoomTransitionDestination)?,
        pinFrame: CGRect,
        pageFrame: CGRect
    ) -> ZoomFlight {
        let card = source.makeFlightCard()
        card.frame = pageFrame
        card.isUserInteractionEnabled = false
        // Live media, either direction: the source mirrors a live-previewing
        // pin (present leg, inside makeFlightCard); failing that, the
        // destination mirrors its active page's player (dismiss leg) — so a
        // playing video never freezes into a cover at either handshake. On a
        // present the destination's page isn't playing yet and refuses.
        if card.videoRenderView.isHidden,
           destination?.zoomMirrorLiveMedia(onto: card.videoRenderView) == true {
            card.videoRenderView.setPoster(card.imageView.image)
            card.videoRenderView.isHidden = false
        }
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
        return ZoomFlight(card: card, chrome: chrome, shadow: shadow, pinFrame: pinFrame, pageFrame: pageFrame)
    }

    // MARK: - Poses

    /// Exact twin of the annotation at its map rect: pin radius, ring and
    /// shadow visible, media cropped to the pin square, chrome invisible.
    func poseAsPin() {
        poseAsPin(at: pinFrame)
    }

    /// `poseAsPin` with a freshly computed landing rect — the interactive
    /// driver recomputes the pin's on-screen rect at *release* time, because
    /// its stage-time value can be seconds old and taken on a map view that
    /// was re-attached before its restored camera fully settled. The shadow
    /// stand-in retargets with it (repositioned here at whatever alpha it
    /// has; callers animate only its alpha).
    func poseAsPin(at landing: CGRect) {
        card.frame = landing
        card.setCornerRadius(PinCardView.cornerRadius)
        card.ringView.alpha = 1
        shadow.frame = CGRect(origin: landing.origin, size: shadow.frame.size)
        shadow.alpha = 1
        let center = CGPoint(x: landing.width / 2, y: landing.height / 2)
        if !card.videoRenderView.isHidden {
            let scale = PinCardView.videoFlightScale(covering: landing.size, surface: pageFrame.size)
            card.videoRenderView.transform = CGAffineTransform(scaleX: scale, y: scale)
            card.videoRenderView.center = center
        }
        if let chrome {
            chrome.transform = CGAffineTransform(
                scaleX: landing.width / pageFrame.width,
                y: landing.height / pageFrame.height
            )
            chrome.center = center
            chrome.alpha = 0
        }
    }

    /// Exact stand-in for the landed page: full-bleed, display-corner radius,
    /// pin chrome gone, page chrome fully readable.
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

    /// The floating card, *position excluded*: page content scaled about the
    /// card's own center, ring/shadow off, chrome fully readable. This is the
    /// grab's morph channel — the interactive driver sets `card.center`
    /// separately every pan event (the position channel), so the card can
    /// float freely under the finger while `scale` tracks dismissal progress.
    func poseFloating(scale: CGFloat, cornerRadius: CGFloat) {
        card.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: pageFrame.width * scale, height: pageFrame.height * scale)
        )
        card.setCornerRadius(cornerRadius)
        card.ringView.alpha = 0
        shadow.alpha = 0
        let center = CGPoint(x: card.bounds.width / 2, y: card.bounds.height / 2)
        if !card.videoRenderView.isHidden {
            card.videoRenderView.transform = CGAffineTransform(scaleX: scale, y: scale)
            card.videoRenderView.center = center
        }
        if let chrome {
            chrome.transform = CGAffineTransform(scaleX: scale, y: scale)
            chrome.center = center
            chrome.alpha = 1
        }
    }

    /// The page pose scaled about the page center — the non-interactive
    /// "pick up, then fly" detach dip. (The interactive grab uses
    /// `poseFloating` instead, keeping position on its own channel.)
    func poseDetached(scale: CGFloat, cornerRadius: CGFloat) {
        poseFloating(scale: scale, cornerRadius: cornerRadius)
        card.center = CGPoint(x: pageFrame.midX, y: pageFrame.midY)
    }

    // MARK: - Stage dressing

    /// A black view, initially transparent, that dims the source (map) behind
    /// the flying card — decoupled from the card so each interpolates on its
    /// own terms.
    static func makeDimView(frame: CGRect) -> UIView {
        let dim = UIView(frame: frame)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        return dim
    }

    /// Rounds the receding map like a system card. The radius is *constant* —
    /// set while the view is still bezel-aligned (invisible at scale 1, since
    /// the display already clips this exact curve) — and the depth transform
    /// then renders it as `scale × radius` on every frame, spring overshoot
    /// and interactive scrubs included. Proportional corner curvature with
    /// nothing to synchronize.
    static func applyRecededChrome(to view: UIView?, radius: CGFloat) {
        guard let view else { return }
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
    }

    /// Cleared only while the reset is undetectable: under the opaque feed
    /// (present) or back at scale 1, where the bezel clips the same curve
    /// (dismiss).
    static func clearRecededChrome(from view: UIView?) {
        guard let view else { return }
        view.layer.cornerRadius = 0
        view.layer.masksToBounds = false
    }

    /// The physical display's corner radius, so the card's corners land flush
    /// on the device's own — dynamic because it differs per model (0 on
    /// square-cornered devices, ~39–62 across the notch/Dynamic Island fleet).
    /// Shared with the timeline slide via CoreNavigation's `ScreenGeometry`,
    /// so every screen-impersonating surface rounds identically.
    static func screenCornerRadius(behind view: UIView) -> CGFloat {
        ScreenGeometry.cornerRadius(behind: view)
    }
}
