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
/// The flight's spring, for anything OUTSIDE this module that has to move with
/// it.
///
/// ⚠️ ONE SOURCE, deliberately. A feature that opens a window on the same beat
/// as a flight needs the same duration and the same damping, and a second copy
/// of three numbers agrees on the day it is written and drifts from the first
/// correction onward — the reasoning `TextRevealInstaller` already records for
/// its thirteen fields.
@MainActor
public enum ZoomFlightSpring {
    public static var duration: TimeInterval { ZoomFlight.springDuration }
    public static var damping: CGFloat { ZoomFlight.springDamping }
    public static var velocity: CGFloat { ZoomFlight.springVelocity }
}

#if DEBUG
/// Samples the flying card and its live media **every frame**, under
/// `-grab-geometry`.
///
/// ⚠️ THE ONE-SHOT PROBES IN THE POSES CANNOT ANSWER A QUESTION ABOUT MOTION.
/// They print from inside an animation block, so they say whether the card and
/// its surface agreed at the instant a pose was set — not whether they stay in
/// step across the frames the viewer actually watches. A report that "the media
/// lags on the way back" is entirely about those frames, and reading them out
/// of a screen recording failed twice: the window extracted at an estimated
/// timestamp turned out to be the next gesture.
///
/// A display link samples the PRESENTATION layer, which is what is on screen,
/// on the same clock CoreAnimation composites on.
@MainActor
final class ZoomGeometrySampler {
    static let shared = ZoomGeometrySampler()
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-grab-geometry") }

    private var link: CADisplayLink?
    private weak var card: (any ZoomFlightCard)?
    private var label = ""
    private var frame = 0

    func start(card: any ZoomFlightCard, label: String) {
        guard Self.isOn else { return }
        stop()
        self.card = card
        self.label = label
        frame = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        print("[sample] --- \(label) ---")
    }

    func stop() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        card = nil
    }

    /// Where a layer's PRESENTATION sits in screen points.
    ///
    /// ⚠️ NOT `layer.convert(_:to: nil)`. That answered with the layer's own
    /// origin on every frame of every run in this session — which is why the
    /// sampler's `dx`/`dy` were a flat +0.0 whatever the geometry did, and why
    /// the card's logged rect came out at {0, 0}. Two identically wrong
    /// conversions compared against each other agree perfectly and say nothing.
    ///
    /// Walking the superlayer chain and summing each presented frame's origin
    /// is correct because every layer in a flight has `bounds.origin == .zero`:
    /// each step contributes exactly where its own presentation sits inside its
    /// parent. Nil when any layer in the chain has no presentation, which is
    /// itself worth seeing rather than papering over with the model value.
    private static func presentedOrigin(of layer: CALayer) -> CGPoint? {
        var point = CGPoint.zero
        var node: CALayer? = layer
        while let current = node, current.superlayer != nil {
            guard let presented = current.presentation() else { return nil }
            point.x += presented.frame.origin.x
            point.y += presented.frame.origin.y
            node = current.superlayer
        }
        return point
    }

    /// The presented opacity a layer is actually drawn at, from `layer` up to
    /// (and excluding) `ancestor` — every host in between multiplied in.
    private static func effectiveOpacity(of layer: CALayer, under ancestor: CALayer) -> Float? {
        var value: Float = 1
        var node: CALayer? = layer
        while let current = node, current !== ancestor {
            guard let presented = current.presentation() else { return nil }
            value *= presented.opacity
            node = current.superlayer
        }
        return value
    }

    @objc private func tick() {
        guard let card else { stop(); return }
        frame += 1
        let cardPres = card.layer.presentation()?.bounds.width
        let surface = card.zoomLiveMediaSurface
        let surfPres = surface?.layer.presentation()?.bounds.width
        // ⚠️ SIZE IS HALF THE QUESTION, and answering only that half is how a
        // broken fix got called finished. A surface can present the card's
        // exact width and still be drawn in the wrong place — this file's own
        // `ZoomLiveMediaRetry` records the shape of it: "the model said 402x874
        // at scale 0.42 centred, while the presentation was a 34x66 patch at
        // (-92, -244)". Width agreed there too.
        let cardOrigin = Self.presentedOrigin(of: card.layer)
        let surfOrigin = surface.flatMap { Self.presentedOrigin(of: $0.layer) }
        let dx = (cardOrigin != nil && surfOrigin != nil) ? surfOrigin!.x - cardOrigin!.x : Double.nan
        let dy = (cardOrigin != nil && surfOrigin != nil) ? surfOrigin!.y - cardOrigin!.y : Double.nan
        // The gap that matters: what the viewer sees of the card against what
        // the viewer sees of its picture. Both read from the presentation, in
        // the same frame.
        let gap = (cardPres != nil && surfPres != nil) ? surfPres! - cardPres! : Double.nan
        // ⚠️ THE SURFACE'S IDENTITY, because `zoomLiveMediaSurface` is a
        // COMPUTED property that can answer with a different object from one
        // frame to the next — the card's own view before a donation, the
        // donated one after. A size that "jumps" may be two views, not one
        // view moving.
        let id = surface.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) % 100000) }
        // ⚠️ THE SURFACE'S MODEL TOO. Without it "the surface jumps" cannot be
        // told apart from "the surface's model was set late": the first is a
        // missing animation, the second is a missing resize, and they need
        // opposite fixes.
        // ⚠️ AND THE COVER, IN THE SAME LINE. Everything above describes the
        // live surface, and on a present the live surface is not yet the
        // picture: the card's still is, drawn directly beneath it. A sampler
        // that reports only the surface answers questions about a view the
        // viewer cannot see — which is exactly how "the surface presents 402
        // from frame 2" and a filmed content landmark that tracked the card
        // rigidly (best match at s=1.00) were both true at once, and how a
        // change that made the surface animate could measure clean and be
        // reported worse. `showing=` names which of the two is drawn.
        let cover = card.zoomCoverSurface
        let coverPres = cover?.layer.presentation()?.bounds.width
        let coverOrigin = cover.flatMap { Self.presentedOrigin(of: $0.layer) }
        let cdx = (cardOrigin != nil && coverOrigin != nil) ? coverOrigin!.x - cardOrigin!.x : Double.nan
        let cdy = (cardOrigin != nil && coverOrigin != nil) ? coverOrigin!.y - cardOrigin!.y : Double.nan
        // What the viewer actually gets. The surface wins only while it is
        // parented, unhidden and not transparent; otherwise the cover is the
        // frame — and "both" is the crossfade, the one interval where a
        // mismatch between them is visible as a jump.
        // ⚠️ PRESENTED opacity, never `view.alpha`. A fade-in writes the model
        // to 1 in the frame it starts, so `alpha` says "fully visible" for the
        // whole ramp — and this line said `showing=both` from the second frame
        // of a present whose video was in fact still almost transparent. Model
        // values written by the same call that logs them always agree with
        // themselves; that is the trap this whole file exists to avoid.
        // ⚠️ AND EVERY OPACITY BETWEEN IT AND THE CARD, not the view's own. A
        // live surface is normally parented on a HOST, and the host's alpha is
        // the channel the card fades it with — so a surface held at zero
        // through its host reads 1.00 here and the line says `showing=both`
        // over a picture nobody can see. That is the same class of lie as
        // reading `alpha` instead of the presented opacity, one level up.
        let surfOpacity = surface.flatMap { Self.effectiveOpacity(of: $0.layer, under: card.layer) }
        let coverOpacity = cover.flatMap { Self.effectiveOpacity(of: $0.layer, under: card.layer) }
        let surfaceDraws = surface.map {
            !$0.isHidden && (surfOpacity ?? $0.layer.opacity) > 0.01 && $0.window != nil
        } ?? false
        let coverDraws = cover.map { !$0.isHidden && (coverOpacity ?? $0.layer.opacity) > 0.01 } ?? false
        let showing = surfaceDraws && coverDraws ? "both" : (surfaceDraws ? "surf" : (coverDraws ? "cover" : "none"))
        print(String(format: "[sample] %@ f%03d cardModel=%.2f cardPres=%.2f surfModel=%.2f surfPres=%.2f gap=%+.2f surf=%@ anims=%d hidden=%@",
                     label, frame, card.bounds.width, cardPres ?? -1,
                     surface?.bounds.width ?? -1, surfPres ?? -1, gap, id ?? "nil",
                     surface?.layer.animationKeys()?.count ?? 0,
                     (surface?.isHidden ?? true) ? "Y" : "n")
              + String(format: " dx=%+.1f dy=%+.1f", dx, dy)
              + String(format: " | covModel=%.2f covPres=%.2f covGap=%+.2f covAnims=%d covAlpha=%.2f cdx=%+.1f cdy=%+.1f sAlpha=%.2f showing=%@",
                       cover?.bounds.width ?? -1, coverPres ?? -1,
                       (cardPres != nil && coverPres != nil) ? coverPres! - cardPres! : Double.nan,
                       cover?.layer.animationKeys()?.count ?? 0,
                       Double(coverOpacity ?? -1), cdx, cdy,
                       Double(surfOpacity ?? -1), showing)
              // ⚠️ AND WHERE THE PICTURE IS INSIDE THAT SURFACE. Everything
              // else here is about the window; this is about the video in it.
              // A rect that stays at the page's crop while the window travels
              // is a defect in the PLAYER, and reads identically to a perfect
              // one in every measurement of the bounds.
              + " vRect=\(card.zoomLiveMediaContentRect.map { NSCoder.string(for: $0) } ?? "-")"
              // ⚠️ AND THE CARD'S PRESENTED RECT IN SCREEN POINTS, so a filmed
              // frame can be cropped to the card EXACTLY rather than to an
              // estimate. Measuring a transition off a recording has failed
              // twice in this session for want of it: a window extracted at a
              // guessed timestamp turned out to be the next gesture, and a
              // search band fixed in screen space latched onto a different
              // feature and "proved" the media shrank twice as fast as the
              // card. With this, the film is aligned to the log by matching
              // this width sequence, and every crop is the card's own box.
              + " cardRect=\(Self.presentedOrigin(of: card.layer).map { o in NSCoder.string(for: CGRect(origin: o, size: card.layer.presentation()?.bounds.size ?? .zero)) } ?? "-")")
    }
}
#endif

@MainActor
struct ZoomFlight {
    /// What the drivers MOVE: its frame, centre, transform and bounds are the
    /// flight's position and size channels, and removing it ends the flight.
    ///
    /// The source's own card — except when the page FITS its picture
    /// (`ZoomPageFraming`), where it is the page window (`ZoomPageWindowCard`)
    /// carrying that card inside it. Either way it spans the tile at one end
    /// and the page at the other, so no driver needs to know which.
    let card: any ZoomFlightCard
    /// What draws the PICTURE — the card the source made. Every pose rounds,
    /// blends and scales the live surface against THIS card, because the
    /// surface lives in its coordinates. Identical to `card` unless the page
    /// fits.
    let mediaCard: any ZoomFlightCard
    /// How the page frames its picture when it does not fill — nil for the
    /// flight that has always existed.
    let framing: ZoomPageFraming?
    /// The destination's chrome replica, riding inside the card.
    let chrome: UIView?
    /// Stand-in for the source's drop shadow (the card clips, so it can't cast
    /// one itself). Fixed at the source rect; fades out as the card leaves and
    /// back in as it returns. Inert for sources that rest flat.
    let shadow: UIView
    let sourceFrame: CGRect
    let pageFrame: CGRect
    /// Where the PICTURE is on the landed page, in the container's space: the
    /// page itself unless the page fits, then the fitted rect inside it. What
    /// the live surface is sized to cover at the page end, and where a hoisted
    /// surface takes off from.
    let mediaFrame: CGRect
    /// The size the live surface is actually laid out at — native aspect when
    /// the card knows it, the page viewport otherwise. Every pose scales
    /// against this, NOT against `pageFrame`, or the cover math would describe
    /// a surface that does not exist.
    let liveMediaSize: CGSize

    /// Whether the flight is a page window around the picture's card.
    var isFramed: Bool { card !== mediaCard }

    /// The corner a page-end pose gives the PICTURE's card. A fitted picture
    /// is drawn square by the page — its corners are nowhere near the
    /// display's own — so the card must be square there too, or it lands
    /// rounded and snaps sharp; the window carries the display's radius. The
    /// page's radius otherwise, which is the card being the page.
    func mediaCornerRadius(forPage radius: CGFloat) -> CGFloat {
        isFramed ? 0 : radius
    }

    /// Places the picture's card inside the window, for a window of `size`,
    /// from covering it (`fit == 0`, the tile) to fitted in it (`fit == 1`,
    /// the page). A no-op for a filling flight, where the two are one view.
    ///
    /// Called ONLY from the poses, inside their animation blocks — see
    /// `ZoomPageWindowCard` for what a second writer cost.
    private func placeMedia(_ rect: CGRect) {
        guard isFramed else { return }
        mediaCard.frame = rect
    }

    /// The picture's card's rect in a window of `size` at `fit` — the window's
    /// own bounds for a filling flight.
    private func mediaRect(inWindowOfSize size: CGSize, fit: CGFloat) -> CGRect {
        guard let framing, isFramed else { return CGRect(origin: .zero, size: size) }
        return ZoomTransitionGeometry.pageWindowMediaRect(
            window: size, aspect: framing.mediaAspect, fit: fit
        )
    }

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
    /// - Parameter presents: which leg this is, and it decides only one thing —
    ///   how media taken from the DESTINATION appears. On a present that media
    ///   is the arrival, so it comes up over the card's own picture; on a
    ///   dismissal it is the departing page itself and simply replaces it.
    ///
    /// The destination is asked how it frames its picture
    /// (`zoomPageFraming`). Nil builds exactly the flight that existed before
    /// pages could fit: one card, flown to the page. Otherwise the source's
    /// card rides inside a `ZoomPageWindowCard`, fitted in it at the page end.
    static func build(
        source: any ZoomTransitionSource,
        destination: (any ZoomTransitionDestination)?,
        sourceFrame: CGRect,
        pageFrame: CGRect,
        presents: Bool = false
    ) -> ZoomFlight {
        let card = source.makeZoomFlightCard()
        card.frame = pageFrame
        card.isUserInteractionEnabled = false
        // A twin, not content: VoiceOver reads the real screens on either side.
        // Left exposed, it read a duplicate caption and author off the chrome
        // replica — for up to 3s when the card stays on as a landing cover.
        card.accessibilityElementsHidden = true
        // The card's own still is the page's fallback for a shape it has not
        // measured and a backdrop it has not rendered — a cold open's page has
        // neither yet, and the tile's cover is the same picture.
        let framing = destination?.zoomPageFraming(
            sourcePicture: (card.zoomCoverSurface as? UIImageView)?.image
        )
        let window = framing.map { ZoomPageWindowCard(media: card, framing: $0, frame: pageFrame) }
        window?.accessibilityElementsHidden = true
        let fittedMedia: CGRect = framing.map {
            let size = ZoomTransitionGeometry.fittedMediaSize(aspect: $0.mediaAspect, in: pageFrame.size)
            return CGRect(
                x: pageFrame.midX - size.width / 2, y: pageFrame.midY - size.height / 2,
                width: size.width, height: size.height
            )
        } ?? pageFrame
        if window != nil {
            // In the window's space from here on, at its page-end place; every
            // later placement is a pose's.
            card.frame = fittedMedia.offsetBy(dx: -pageFrame.minX, dy: -pageFrame.minY)
        }
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
            // ⚠️ THE SAME DOOR THE RETRY GOES THROUGH NEEDS THE SAME MANNERS.
            //
            // A present that gets its picture HERE rather than mid-flight is
            // still getting the arriving page's picture, and it must arrive the
            // way `ZoomLiveMediaRetry` makes it arrive — over the card's own,
            // which stays drawn. Without this the card cuts to a poster of the
            // page over its animating sprite sheet at take-off, and the flight
            // that finally got its media early would look worse than the one
            // that got it late.
            //
            // Unreachable today (the page's playback has not registered by the
            // time this asks), and one timing change away from being reachable
            // — which is exactly when a hole like this ships.
            if presents, card.zoomLiveMediaSurface != nil {
                card.fadeInAdoptedLiveMedia(over: Self.springDuration)
            }
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
        //
        // Sized to cover the PICTURE's page-end rect: the page itself, or the
        // fitted rect when the page fits — which has the clip's own aspect, so
        // the page end is the surface at scale ~1 and a fit drawn by fill math.
        let liveMediaSize = Self.liveMediaLayoutSize(native: card.zoomLiveMediaNativeSize,
                                                     page: fittedMedia.size)
        if card.zoomLiveMediaSurface != nil {
            card.prepareZoomLiveMediaForFlight(destinationSize: liveMediaSize)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] build live=\(card.zoomLiveMediaSurface != nil) destination=\(destination != nil)"
                  + " framed=\(framing.map { "\($0.mediaAspect.width)x\($0.mediaAspect.height)" } ?? "no")")
        }
        #endif

        let chrome = destination?.zoomFlightChrome()
        if let chrome {
            chrome.autoresizingMask = []
            chrome.bounds = CGRect(origin: .zero, size: pageFrame.size)
            chrome.center = CGPoint(x: pageFrame.width / 2, y: pageFrame.height / 2)
            // Below the resting chrome: at the source end that furniture must
            // read as the source's own, over everything.
            //
            // A page window is the exception, and cannot follow the rule: the
            // resting chrome lives inside the picture's card, which at the page
            // end no longer spans the page, and the replica has to reach into
            // the bands. So it rides over the picture in the window. The two
            // are never both opaque — the replica is at zero wherever the
            // resting chrome is at one — so the order only decides which of
            // two half-faded layers is on top mid-flight.
            if let window {
                window.addSubview(chrome)
            } else if let resting = card.zoomRestingChrome {
                card.insertSubview(chrome, belowSubview: resting)
            } else {
                card.addSubview(chrome)
            }
        }

        // NOT rasterised, and the reasoning is worth keeping because this is
        // the obvious next idea whenever the flight is accused of stuttering.
        //
        // This replica is the ONLY live view hierarchy the flight animates —
        // the destination is hidden the whole way (`setZoomContentHidden`), so
        // the card is already the lightweight proxy a "snapshot instead of the
        // live view" strategy asks for. Its bounds are fixed before the first
        // frame, so nothing in it relayouts either; flattening it could only
        // remove per-frame COMPOSITING of its sublayers.
        //
        // Measured (`shouldRasterize` on this layer, 3 runs each): the
        // flight-start gap did not improve — 56.6 ms against 61.3 ms — though
        // total drops over the window fell from 22 to 16 per run. It is
        // declined anyway, because the card is TRANSFORM-scaled from tile to
        // full screen: a texture cached at display scale is then magnified,
        // and the chrome's text goes soft for the length of the flight. A
        // sharper settle is not worth a blurry flight.
        //
        // Flattening the whole CARD is worse than useless: it carries the live
        // video surface, and a cached texture freezes it — which is precisely
        // the pause this work exists to remove.
        //
        // The stall this keeps being reached for is not compositing at all. It
        // is ~85-115 ms of synchronous main-thread work inside
        // `pushViewController`, sampled to UIKit materialising the
        // destination's bar glass, and it happens BEFORE any frame is
        // rendered. No proxy for the content can move it. See
        // `ZoomFlightProfiler`.

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
            card: window ?? card, mediaCard: card, framing: window == nil ? nil : framing,
            chrome: chrome, shadow: shadow,
            sourceFrame: sourceFrame, pageFrame: pageFrame, mediaFrame: fittedMedia,
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
        // A page window's picture is the WHOLE window at this end — the
        // source's own aspect-fill crop, at the source's own corner — so the
        // take-off and the landing are the tile, pixel for pixel, and the
        // backdrop behind it is entirely covered.
        placeMedia(mediaRect(inWindowOfSize: landing.size, fit: 0))
        if isFramed { mediaCard.setZoomCornerRadius(mediaCard.zoomRestingCornerRadius) }
        // The thumbnail end is the source's OWN picture, whole. Set
        // unconditionally, like every other channel in this pose, so a flight
        // that was caught and released mid-blend still lands on the exact twin
        // the handshake depends on rather than on whatever fraction it was
        // holding.
        mediaCard.setZoomContentBlend(1)
        mediaCard.zoomRestingChrome?.alpha = 1
        shadow.frame = CGRect(origin: landing.origin, size: shadow.frame.size)
        shadow.alpha = 1
        let center = CGPoint(x: landing.width / 2, y: landing.height / 2)
        if let surface = mediaCard.zoomLiveMediaSurface, !mediaCard.zoomLiveMediaTracksCardBounds {
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
        // A page window's picture is FITTED at this end, square-cornered, on
        // the page's backdrop: the page's own composition.
        let media = mediaRect(inWindowOfSize: pageFrame.size, fit: 1)
        placeMedia(media)
        if isFramed { mediaCard.setZoomCornerRadius(0) }
        // The full-screen end is the PAGE's picture — the one the card was
        // handed as its departure operand. A card with no second picture reads
        // this as the no-op it is.
        mediaCard.setZoomContentBlend(0)
        mediaCard.zoomRestingChrome?.alpha = 0
        shadow.alpha = 0
        let center = CGPoint(x: pageFrame.width / 2, y: pageFrame.height / 2)
        if let surface = mediaCard.zoomLiveMediaSurface, !mediaCard.zoomLiveMediaTracksCardBounds {
            if isFramed {
                // Covering the fitted rect, which has the clip's own shape —
                // scale ~1, the surface's layout size — and centred in it.
                let scale = Self.liveMediaScale(covering: media.size, surface: liveMediaSize)
                surface.transform = CGAffineTransform(scaleX: scale, y: scale)
                surface.center = CGPoint(x: media.width / 2, y: media.height / 2)
            } else {
                surface.transform = .identity
                surface.center = center
            }
        }
        if let chrome {
            chrome.transform = .identity
            chrome.center = center
            chrome.alpha = 1
        }
        #if DEBUG
        // Same probe as `poseFloating`, on the two legs a grab's RELEASE and
        // the PRESENT both drive. Model against presentation, because the model
        // agreeing with itself proves nothing about what is on screen.
        if ProcessInfo.processInfo.arguments.contains("-grab-geometry") {
            let pres = card.layer.presentation()?.bounds
            print(String(format: "[page] %.3f card=%@ pres=%@ anim=[%@] | %@",
                         CACurrentMediaTime(), NSCoder.string(for: card.bounds),
                         pres.map { NSCoder.string(for: $0) } ?? "nil",
                         card.layer.animationKeys()?.joined(separator: ",") ?? "-",
                         mediaCard.zoomLiveMediaDebugState))
        }
        #endif
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
        // Still the page, so still the page's COMPOSITION: a held page window
        // keeps its picture fitted, scaled with it, for the reason the blend
        // below states — the morph toward the tile belongs to the release.
        let media = mediaRect(inWindowOfSize: card.bounds.size, fit: 1)
        placeMedia(media)
        if isFramed { mediaCard.setZoomCornerRadius(0) }
        // Still the page, so still the page's picture. A held card is the thing
        // being decided about rather than a thing on its way home — the same
        // reasoning that keeps the page's ASPECT here instead of morphing it
        // under the finger — so the blend belongs to the release, which is when
        // the outcome is known. Stated rather than left implicit: this pose is
        // re-applied on every pan event, and a channel it does not name is a
        // channel that can carry a stale value into a whole grab.
        mediaCard.setZoomContentBlend(0)
        mediaCard.zoomRestingChrome?.alpha = 0
        shadow.alpha = 0
        let center = CGPoint(x: card.bounds.width / 2, y: card.bounds.height / 2)
        // ⚠️ THE SAME GUARD THE OTHER FOUR POSES HAVE, and its absence here was
        // a live defect the moment a card started tracking its own bounds.
        //
        // A tracking card sizes its surface from its own bounds; writing a
        // centre on top of that fights the autoresizing every pan event, and on
        // a surface anchored at its top-left it puts the picture's CORNER at
        // the card's centre — filmed on the dismiss as a second, differently
        // cropped rectangle inset into the bottom-right quadrant.
        if let surface = mediaCard.zoomLiveMediaSurface, !mediaCard.zoomLiveMediaTracksCardBounds {
            if isFramed {
                let fitScale = Self.liveMediaScale(covering: media.size, surface: liveMediaSize)
                surface.transform = CGAffineTransform(scaleX: fitScale, y: fitScale)
                surface.center = CGPoint(x: media.width / 2, y: media.height / 2)
            } else {
                surface.transform = CGAffineTransform(scaleX: scale, y: scale)
                surface.center = center
            }
        }
        if let chrome {
            chrome.transform = CGAffineTransform(scaleX: scale, y: scale)
            chrome.center = center
            chrome.alpha = 1
        }
        #if DEBUG
        // `-grab-geometry`: the whole chain, once per pan event.
        //
        // Filmed and measured: during a grab the video inside the card shrinks
        // about TWICE as fast as the card does — content separation -15.7%
        // against a card height of -7.6%, drifting monotonically and freezing
        // the instant the card stops. Every structural reading says it should
        // be rigid: this pose scales `bounds` uniformly, nothing else scales
        // the card, the surface is full-bleed and autoresized, and an
        // aspect-fill of a wider-than-tall video into a narrower card is
        // height-driven and therefore vertically invariant. One of those four
        // is false, and only the running app can say which.
        if ProcessInfo.processInfo.arguments.contains("-grab-geometry") {
            // ⚠️ THE MODEL AGREEING PROVES NOTHING. Both values below are
            // written in the same turn, so of course they match — the first
            // pass of this probe read only those and concluded "rigid". What a
            // viewer sees is the PRESENTATION, and a layer carrying an
            // animation presents an interpolated value while its model has
            // already arrived. `card.center` is set directly on every pan
            // (`ZoomDismissInteractionController`) while `card.bounds` may be
            // riding `springDetach`'s spring, so the two channels can be on
            // different clocks — which is what "the video follows the drag with
            // a delay" would be.
            let cardPres = card.layer.presentation()?.bounds
            let cardKeys = card.layer.animationKeys()?.joined(separator: ",") ?? "-"
            print(String(format: "[grab] %.3f scale=%.4f card=%@ pres=%@ anim=[%@] | %@",
                         CACurrentMediaTime(), scale,
                         NSCoder.string(for: card.bounds),
                         cardPres.map { NSCoder.string(for: $0) } ?? "nil",
                         cardKeys, mediaCard.zoomLiveMediaDebugState))
        }
        #endif
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
    ///
    /// The card's PICTURE blend does interpolate, and the difference is not an
    /// inconsistency. The rule above is not "never cross-fade": it is that a
    /// fade only works against NOTHING, because two half-drawn runs of text
    /// draw both of them. The blend's two operands are opaque pictures with one
    /// of them fully opaque behind the other at every instant, so every frame
    /// it produces is a whole photograph rather than two transparent ones —
    /// and a card whose far end is line art blends the disc and the glyph as
    /// one opaque unit for exactly that reason. Excluding it would also put
    /// back the snap this function exists to remove: the card would be
    /// pin-sized and pin-shaped at `t == 1` while still wearing the page's
    /// picture, and the swap would have to land in a single frame.
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
        // A page window's picture travels from fitted in the detached page to
        // the whole tile on the same `t` — the blend of the two endpoint rects,
        // which is the curve the release spring then continues on.
        var media = CGRect(origin: .zero, size: size)
        if let framing, isFramed {
            media = ZoomTransitionGeometry.interpolatedWindowMediaRect(
                from: startSize, to: landing.size, aspect: framing.mediaAspect, progress: t
            )
            placeMedia(media)
            mediaCard.setZoomCornerRadius(mediaCard.zoomRestingCornerRadius * t)
        }
        // Ahead of the live-surface block below, which returns early for cards
        // that size their own surface — the blend belongs to every card, not
        // only to the ones that fall through.
        mediaCard.setZoomContentBlend(t)
        let center = CGPoint(x: media.midX - media.minX, y: media.midY - media.minY)
        // ⚠️ THE CONDITION IS ON THE SURFACE BLOCK, NOT ON THE FUNCTION. It was
        // a `guard … else { return }` inside this block, so a tracking card
        // carrying live media returned here and never posed its CHROME for the
        // whole interpolation — the card's furniture frozen at its last value
        // while the card morphed under it.
        if let surface = mediaCard.zoomLiveMediaSurface, !mediaCard.zoomLiveMediaTracksCardBounds {
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
            //
            // A page window starts from its FITTED picture, not from the
            // window: that is the rect the surface covers at `t == 0`.
            let startCover = framing.map {
                ZoomTransitionGeometry.fittedMediaSize(aspect: $0.mediaAspect, in: startSize)
            } ?? startSize
            let startScale = Self.liveMediaScale(covering: isFramed ? startCover : startSize,
                                                 surface: liveMediaSize)
            let endScale = Self.liveMediaScale(covering: landing.size, surface: liveMediaSize)
            let scale = startScale + (endScale - startScale) * t
            surface.transform = CGAffineTransform(scaleX: scale, y: scale)
            surface.center = center
        }
        if let chrome {
            chrome.transform = CGAffineTransform(
                scaleX: size.width / pageFrame.width, y: size.height / pageFrame.height
            )
            chrome.center = CGPoint(x: size.width / 2, y: size.height / 2)
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
        ZoomTransitionGeometry.mediaLayoutSize(native: native, covering: page)
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
        RecededChromeSnapshot.take(of: view.layer)
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
    }

    /// Cleared only while the reset is undetectable: under the opaque feed
    /// (present) or back at scale 1, where the bezel clips the same curve
    /// (dismiss).
    ///
    /// ⚠️ RESTORED, not zeroed. Every depth view so far happened not to clip
    /// or round on its own, so writing `0` / `false` looked like a reset; a
    /// presenter whose depth view did would have lost its own rounding after
    /// the first flight. The values the first apply found are put back.
    static func clearRecededChrome(from view: UIView?) {
        guard let view else { return }
        let found = RecededChromeSnapshot.release(of: view.layer)
        view.layer.cornerRadius = found?.cornerRadius ?? 0
        view.layer.cornerCurve = found?.cornerCurve ?? view.layer.cornerCurve
        view.layer.masksToBounds = found?.masksToBounds ?? false
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

/// What a depth view's layer looked like before the receded chrome was put on
/// it, held until the chrome comes off. The FIRST apply wins: a dismissal
/// re-applies over a present's chrome that was cleared, and a re-apply over
/// chrome still on would otherwise snapshot the chrome itself.
@MainActor
enum RecededChromeSnapshot {
    struct Values {
        let cornerRadius: CGFloat
        let cornerCurve: CALayerCornerCurve
        let masksToBounds: Bool
    }

    private struct Entry {
        weak var layer: CALayer?
        let values: Values
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func take(of layer: CALayer) {
        entries = entries.filter { $0.value.layer != nil }
        let key = ObjectIdentifier(layer)
        guard entries[key] == nil else { return }
        entries[key] = Entry(layer: layer, values: Values(
            cornerRadius: layer.cornerRadius,
            cornerCurve: layer.cornerCurve,
            masksToBounds: layer.masksToBounds
        ))
    }

    static func release(of layer: CALayer) -> Values? {
        let key = ObjectIdentifier(layer)
        defer { entries[key] = nil }
        guard let entry = entries[key], entry.layer === layer else { return nil }
        return entry.values
    }
}
