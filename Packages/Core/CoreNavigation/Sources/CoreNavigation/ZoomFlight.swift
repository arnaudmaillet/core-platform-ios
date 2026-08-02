import UIKit

/// The flying unit shared by both dismissal drivers — the non-interactive
/// `ZoomAnimator` and the interactive grab (`ZoomDismissInteractionController`)
/// — plus the stage dressing they set identically (dim, receded presenter
/// chrome, display corner radius). One veneer factory, two choreographies:
/// however a dismissal is driven, the card, shadow, resting chrome, and source
/// handshake are the same objects posed by the same code.
///
/// Every property that differs between poses is UIView-animatable, so setting
/// a pose inside an animation block sweeps the whole card — frame, radius,
/// resting chrome, shadow, page chrome, video scale — as one unit. Frame,
/// center, and transform all interpolate linearly in the same animation
/// parameter, so the chrome and video layers stay exactly full-bleed within the
/// morphing card on every frame ("lockstep" is a property of the math, not of
/// synchronized clocks).
@MainActor
struct ZoomFlight {
    let card: any ZoomFlightCard
    /// The destination's chrome replica, riding inside the card.
    let chrome: UIView?
    /// Stand-in for the source's drop shadow (the card clips, so it can't cast
    /// one itself). Fixed at the source rect; fades out as the card leaves and
    /// back in as it returns. Inert for sources that rest flat.
    let shadow: UIView
    let sourceFrame: CGRect
    let pageFrame: CGRect
    /// The size the live surface is actually laid out at — native aspect when
    /// the card knows it, the page viewport otherwise. Every pose scales
    /// against this, NOT against `pageFrame`, or the cover math would describe
    /// a surface that does not exist.
    let liveMediaSize: CGSize

    /// How far the presenting screen recedes behind a flight (depth cue).
    static let presenterDepthScale: CGFloat = 0.95
    /// Grab feedback: the card's scale the instant a dismissal starts — it
    /// visibly detaches from the screen canvas before flying home.
    static let detachScale: CGFloat = 0.95

    /// The smallest the card may shrink to while the finger still holds it.
    ///
    /// A held card is still the PAGE — the viewer is deciding, not landing —
    /// and a page that shrinks toward thumbnail size under the hand reads as
    /// the post having already gone. Clamping keeps the thing being dragged
    /// recognisably the thing being dismissed; the remaining distance to the
    /// tile is covered by the release spring, which is the moment the outcome
    /// is actually decided.
    static let minimumGrabScale: CGFloat = 0.6

    /// The single spring every FLIGHT lands on — the non-interactive present
    /// and tap-back (`ZoomAnimator`) and the released grab
    /// (`ZoomDismissInteractionController`) — so all three settle with identical
    /// physics. Damping just under 1 gives a hair of overshoot ("placed", not
    /// "switched to"); shared here so no driver can drift from the others.
    ///
    /// A non-interactive leg starts with `springVelocity` (a lively push off
    /// the mark); a grab feeds in the hand's release velocity instead, so a
    /// hard fling overshoots more than a tap — but the CURVE is the same one.
    static let springDamping: CGFloat = 0.82
    static let springDuration: TimeInterval = 0.42
    static let springVelocity: CGFloat = 0.6

    /// Builds the card in page pose (so the chrome replica can resolve its
    /// full-screen layout before the first frame) plus its shadow stand-in.
    /// The caller inserts both into the container and lays out.
    static func build(
        source: any ZoomTransitionSource,
        destination: (any ZoomTransitionDestination)?,
        sourceFrame: CGRect,
        pageFrame: CGRect
    ) -> ZoomFlight {
        let card = source.makeZoomFlightCard()
        card.frame = pageFrame
        card.isUserInteractionEnabled = false
        // Live media, either direction: the source may already have mirrored a
        // live-previewing thumbnail inside `makeZoomFlightCard` (present leg);
        // failing that, the destination mirrors its active page's player
        // (dismiss leg) — so a playing video never freezes into a cover at
        // either handshake. On a present the destination's page isn't playing
        // yet and refuses.
        // Donation before mirroring, both directions. A mirror is a second
        // `AVPlayerLayer` with no decoded frame — blank for ~70-100ms while the
        // other side is already hidden, which is the flash at the start of the
        // flight. Moving the view that is already rendering has no such window;
        // mirroring stays as the fallback for sources that cannot give theirs
        // up.
        if card.zoomLiveMediaSurface == nil, let destination,
           let donated = destination.zoomDonateLiveMediaView() {
            card.adoptZoomLiveMediaView(donated)
        }
        if card.zoomLiveMediaSurface == nil, let destination {
            card.adoptZoomLiveMedia { surface in destination.zoomMirrorLiveMedia(onto: surface) }
        }
        // The native aspect is read AFTER the card has its surface, and the
        // order is load-bearing: on the dismiss leg the surface arrives from
        // the destination donation just above, and reading the size before it
        // answered nil — the page-size fallback. A page-shaped surface is
        // ALREADY the feed's crop, so the flight showed that crop miniaturised
        // all the way home and the landing's own aspect-fill snapped to the
        // tile's true crop at the end: the double-crop mismatch the note on
        // `liveMediaLayoutSize` describes, reintroduced by an ordering change
        // and measured on device as the landing zoom snap.
        let liveMediaSize = Self.liveMediaLayoutSize(native: card.zoomLiveMediaNativeSize,
                                                     page: pageFrame.size)
        if card.zoomLiveMediaSurface != nil {
            card.prepareZoomLiveMediaForFlight(destinationSize: liveMediaSize)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] build live=\(card.zoomLiveMediaSurface != nil) destination=\(destination != nil)")
        }
        #endif

        let chrome = destination?.zoomFlightChrome()
        if let chrome {
            chrome.autoresizingMask = []
            chrome.bounds = CGRect(origin: .zero, size: pageFrame.size)
            chrome.center = CGPoint(x: pageFrame.width / 2, y: pageFrame.height / 2)
            // Below the resting chrome: at the source end that furniture must
            // read as the source's own, over everything.
            if let resting = card.zoomRestingChrome {
                card.insertSubview(chrome, belowSubview: resting)
            } else {
                card.addSubview(chrome)
            }
        }

        let shadow = UIView(frame: sourceFrame)
        shadow.backgroundColor = .clear
        shadow.isUserInteractionEnabled = false
        card.applyZoomRestingShadow(to: shadow.layer)
        // A clear view casts nothing on its own; the explicit path draws the
        // source's silhouette. Harmless when the card declined to set a shadow.
        shadow.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: sourceFrame.size),
            cornerRadius: card.zoomRestingCornerRadius
        ).cgPath
        return ZoomFlight(
            card: card, chrome: chrome, shadow: shadow,
            sourceFrame: sourceFrame, pageFrame: pageFrame,
            liveMediaSize: liveMediaSize
        )
    }

    // MARK: - Poses

    /// Exact twin of the source thumbnail at its rect: resting radius, resting
    /// chrome and shadow visible, media cropped to the thumbnail, page chrome
    /// invisible.
    func poseAtSource() {
        poseAtSource(at: sourceFrame)
    }

    /// `poseAtSource` with a freshly computed landing rect — the interactive
    /// driver recomputes the source's on-screen rect at *release* time, because
    /// its stage-time value can be seconds old and taken on a view that was
    /// re-attached before it settled. The shadow stand-in retargets with it
    /// (repositioned here at whatever alpha it has; callers animate only its
    /// alpha).
    func poseAtSource(at landing: CGRect) {
        card.frame = landing
        card.setZoomCornerRadius(card.zoomRestingCornerRadius)
        card.zoomRestingChrome?.alpha = 1
        shadow.frame = CGRect(origin: landing.origin, size: shadow.frame.size)
        shadow.alpha = 1
        let center = CGPoint(x: landing.width / 2, y: landing.height / 2)
        if let surface = card.zoomLiveMediaSurface, !card.zoomLiveMediaTracksCardBounds {
            let scale = Self.liveMediaScale(covering: landing.size, surface: liveMediaSize)
            surface.transform = CGAffineTransform(scaleX: scale, y: scale)
            surface.center = center
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
    /// resting chrome gone, page chrome fully readable.
    func poseAsPage(cornerRadius: CGFloat) {
        card.frame = pageFrame
        card.setZoomCornerRadius(cornerRadius)
        card.zoomRestingChrome?.alpha = 0
        shadow.alpha = 0
        let center = CGPoint(x: pageFrame.width / 2, y: pageFrame.height / 2)
        if let surface = card.zoomLiveMediaSurface, !card.zoomLiveMediaTracksCardBounds {
            surface.transform = .identity
            surface.center = center
        }
        if let chrome {
            chrome.transform = .identity
            chrome.center = center
            chrome.alpha = 1
        }
    }

    /// The floating card, *position excluded*: page content scaled about the
    /// card's own center, resting chrome/shadow off, page chrome fully
    /// readable. This is the grab's morph channel — the interactive driver sets
    /// `card.center` separately every pan event (the position channel), so the
    /// card can float freely under the finger while `scale` tracks progress.
    func poseFloating(scale: CGFloat, cornerRadius: CGFloat) {
        card.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: pageFrame.width * scale, height: pageFrame.height * scale)
        )
        card.setZoomCornerRadius(cornerRadius)
        card.zoomRestingChrome?.alpha = 0
        shadow.alpha = 0
        let center = CGPoint(x: card.bounds.width / 2, y: card.bounds.height / 2)
        if let surface = card.zoomLiveMediaSurface {
            surface.transform = CGAffineTransform(scaleX: scale, y: scale)
            surface.center = center
        }
        if let chrome {
            chrome.transform = CGAffineTransform(scaleX: scale, y: scale)
            chrome.center = center
            chrome.alpha = 1
        }
    }

    /// The card partway home: size and corner radius interpolated between the
    /// detached page (`t == 0`) and the landing rect (`t == 1`), with the
    /// chrome and video layers re-fitted to the morphing bounds on every step.
    /// Position is excluded — the interactive driver owns that channel.
    ///
    /// This is what keeps a grab honest. Scaling the page rect uniformly and
    /// only adopting the target's shape at release means the card spends the
    /// whole drag as the wrong shape and then snaps into the right one: barely
    /// noticeable flying to a 56pt square pin, glaring flying to a mosaic brick
    /// that may be portrait, landscape or square. Interpolating the size
    /// directly means the card is always exactly as far home as the finger has
    /// taken it, and the release spring is a short continuation rather than a
    /// correction.
    ///
    /// The two chrome ALPHAS deliberately do not interpolate here: cross-fading
    /// the page's caption against the tile's counters mid-drag reads as two
    /// half-drawn overlays. They swap inside the release spring
    /// (`poseAtSource`/`poseAsPage`), where one of them is always the answer.
    func poseInterpolated(
        _ progress: CGFloat, from startSize: CGSize, to landing: CGRect, startCornerRadius: CGFloat
    ) {
        let t = min(max(progress, 0), 1)
        let size = CGSize(
            width: startSize.width + (landing.width - startSize.width) * t,
            height: startSize.height + (landing.height - startSize.height) * t
        )
        card.bounds = CGRect(origin: .zero, size: size)
        card.setZoomCornerRadius(
            startCornerRadius + (card.zoomRestingCornerRadius - startCornerRadius) * t
        )
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if let surface = card.zoomLiveMediaSurface {
            guard !card.zoomLiveMediaTracksCardBounds else { return }
            // Interpolate the SCALE between the two endpoint scales, rather
            // than recomputing a cover scale from the interpolated size.
            //
            // `liveMediaScale` is a `max` of two ratios, and which one wins can
            // CHANGE mid-drag: with the surface at native 16:9 (1553x874) and
            // the card travelling 402x874 -> 267x133, height governs at the
            // page end and width governs at the tile end. At that crossover the
            // derivative jumps, which reads as the video barely shrinking and
            // then snapping. Interpolating the scale is monotonic by
            // construction and still lands on exactly the right cover scale at
            // both ends, because those are the values being interpolated
            // between.
            //
            // The animator legs never showed this: UIView interpolates the
            // transform itself between two posed endpoints, which is already
            // linear in scale. Only the grab recomputes per frame.
            let startScale = Self.liveMediaScale(covering: startSize, surface: liveMediaSize)
            let endScale = Self.liveMediaScale(covering: landing.size, surface: liveMediaSize)
            let scale = startScale + (endScale - startScale) * t
            surface.transform = CGAffineTransform(scaleX: scale, y: scale)
            surface.center = center
        }
        if let chrome {
            chrome.transform = CGAffineTransform(
                scaleX: size.width / pageFrame.width, y: size.height / pageFrame.height
            )
            chrome.center = center
        }
    }

    // MARK: - Stage dressing

    /// The size to lay the flight's live surface out at.
    ///
    /// The media's NATIVE aspect, sized so it just covers the page — not the
    /// page's own size. A page-sized surface is already a crop (the page
    /// renders aspect-fill), so scaling it down to a tile crops a SECOND time,
    /// from the page's crop rather than from the media. The landing tile shows
    /// aspect-fill of the native media, so the two disagree and the mismatch
    /// lands as a snap.
    ///
    /// At native aspect, `liveMediaScale` covering either endpoint reproduces
    /// that endpoint's own aspect-fill exactly, so the card's animating bounds
    /// are the only crop in the flight.
    ///
    /// Sized to just cover the page rather than at raw pixel dimensions so the
    /// page end sits at scale ~1 and the surface is never resampled up from
    /// something smaller than the screen.
    static func liveMediaLayoutSize(native: CGSize?, page: CGSize) -> CGSize {
        guard let native, native.width > 0, native.height > 0,
              page.width > 0, page.height > 0
        else { return page }
        let cover = max(page.width / native.width, page.height / native.height)
        return CGSize(width: native.width * cover, height: native.height * cover)
    }

    /// The uniform scale that makes a `surface`-sized video layer cover a
    /// `size`-sized card — the flight-video analog of `scaleAspectFill`.
    static func liveMediaScale(covering size: CGSize, surface: CGSize) -> CGFloat {
        ZoomTransitionGeometry.mediaFillScale(covering: size, surface: surface)
    }

    /// A black view, initially transparent, that dims the source screen behind
    /// the flying card — decoupled from the card so each interpolates on its
    /// own terms.
    static func makeDimView(frame: CGRect) -> UIView {
        let dim = UIView(frame: frame)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        return dim
    }

    /// Rounds the receding presenter like a system card. The radius is
    /// *constant* — set while the view is still bezel-aligned (invisible at
    /// scale 1, since the display already clips this exact curve) — and the
    /// depth transform then renders it as `scale × radius` on every frame,
    /// spring overshoot and interactive scrubs included. Proportional corner
    /// curvature with nothing to synchronize.
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
    /// Shared with the timeline slide via `ScreenGeometry`, so every
    /// screen-impersonating surface rounds identically.
    static func screenCornerRadius(behind view: UIView) -> CGFloat {
        ScreenGeometry.cornerRadius(behind: view)
    }
}
