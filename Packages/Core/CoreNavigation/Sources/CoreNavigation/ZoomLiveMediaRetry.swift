import UIKit

/// Keeps asking for the flight's live video after take-off, and puts it on the
/// card mid-air when it finally exists.
///
/// ⚠️ THE PLAYER IS NOT LATE BY MISTAKE — it is late by design, and this is the
/// piece that makes that survivable.
///
/// A tile only holds a decoder while the grid decides it should: a feed being
/// thrown attaches nothing, a pool at capacity refuses, and even a granted
/// player resolves its URL a turn later and decodes its first frame ~100ms
/// after that. Tap during any of those windows and `makeZoomFlightCard` has
/// nothing live to hand over, so the card flies the THUMBNAIL for the whole
/// transition and lands on a page that is already playing. That is the
/// intermittent "the player did not attach": nothing is broken, the question
/// was simply asked once, at the only moment the answer could still be no.
///
/// So it is asked again, every display refresh, for a bounded window. The
/// moment a surface exists the card adopts it — cover still up until
/// `revealOnFirstFrame` fires, so a surface that arrives without pixels can
/// never blank the card.
///
/// ⚠️ AND THE SURFACE IS THEN DRIVEN PER-FRAME, not animated.
///
/// A card mid-flight is being interpolated by a running
/// `UIViewPropertyAnimator` whose curve this class has no handle on. Starting a
/// second animation toward the same landing would agree at both ends and
/// disagree everywhere between — the video's crop sliding against the card's
/// edges for the rest of the flight. Reading the card's PRESENTATION size each
/// tick and posing the surface from it is exact by construction: the same cover
/// math the grab driver uses, fed the frame that is actually on screen.
@MainActor
final class ZoomLiveMediaRetry: NSObject {
    private weak var card: (any ZoomFlightCard)?
    /// Tries to put live media on the card and reports the surface that ended
    /// up there, or nil for "not yet".
    ///
    /// ⚠️ A CLOSURE THAT ACTS, not one that answers, because the two ends
    /// hand media over differently: a tile GIVES its view, a page MIRRORS its
    /// player onto the card's own surface. Modelling only the first shape is
    /// what limited this class to sources for as long as sources were the only
    /// side that could be late.
    private let acquire: (any ZoomFlightCard) -> UIView?
    private let pageSize: CGSize
    /// Whether an adoption is an ARRIVAL over this card's own picture, and so
    /// fades in, or a surface the card was always going to be flying.
    private let fadesIn: Bool
    private let deadline: CFTimeInterval
    private var link: CADisplayLink?
    private var liveMediaSize: CGSize = .zero
    private var hasAdopted = false
    /// Set once the card's presentation has been seen AWAY from its model, so a
    /// flight sampled before its animation has started cannot read as landed.
    private var hasTravelled = false
    private var hasArrived = false

    /// How long after take-off a surface is still worth adopting.
    ///
    /// Past the flight's own settle there is nothing left to improve: the card
    /// is about to hand its media to the landed page, which starts its own
    /// playback. A window that outlived the flight would only be a chance to
    /// mutate a card on its way out.
    static let window: CFTimeInterval = ZoomFlight.springDuration

    /// Starts a retry for a card that took off without live media. Returns nil
    /// — and costs nothing — when there is nothing to wait for.
    @discardableResult
    static func arm(
        card: any ZoomFlightCard,
        pageSize: CGSize,
        source: any ZoomTransitionSource,
        window: CFTimeInterval = ZoomLiveMediaRetry.window
    ) -> ZoomLiveMediaRetry? {
        guard card.zoomLiveMediaSurface == nil else { return nil }
        let retry = ZoomLiveMediaRetry(
            card: card,
            pageSize: pageSize,
            window: window,
            // A tile's surface is the card's own picture in motion — the same
            // post, the same crop, already what the card was showing. It
            // replaces the cover rather than arriving over it.
            fadesIn: false,
            // The source is held WEAKLY through this closure's own capture, so
            // a flight outliving its screen stops asking rather than keeping a
            // grid that is being torn down alive to answer.
            acquire: { [weak source] card in
                guard let surface = source?.zoomLiveMediaSurfaceIfReady() else { return nil }
                card.adoptZoomLiveMediaView(surface)
                // The card is free to refuse — a wrong surface type, or one it
                // has since acquired for itself. Refusing is not a reason to
                // stop asking.
                return card.zoomLiveMediaSurface === surface ? surface : nil
            }
        )
        retry.start()
        return retry
    }

    /// The same wait, pointed at the ARRIVING page instead of the departing
    /// thumbnail — the present leg's mirror image, and it exists for the same
    /// reason in reverse.
    ///
    /// A marker flies a sprite sheet: no player leaves with the card, so the
    /// only place this post's video can be decoding is the page underneath.
    /// It is decoding — the destination is told at staging that nothing is
    /// flying its player and starts at take-off — but its first frame lands a
    /// couple of hundred milliseconds later, and `ZoomFlight.build` asked once,
    /// before there was anything to say yes to. So the card spent the whole
    /// flight showing a 172pt cover blown up sevenfold, and the sharp picture
    /// appeared only after the landing. Filmed.
    ///
    /// ⚠️ ARMED ONLY WHERE THE PAGE IS ALLOWED TO PLAY IN FLIGHT. A destination
    /// that stood its playback down has nothing to mirror, and asking it every
    /// refresh for the length of a flight would be a question whose answer is
    /// known. The caller gates on the same fact it told the destination.
    ///
    /// ⚠️ The mirror moves the render slot to the card (only the most recently
    /// attached layer is guaranteed to draw), so the page is blank BEHIND the
    /// card until `zoomTransitionDidEnd` reclaims it. That is the dismiss leg's
    /// mechanism run backwards, and the landing already reclaims.
    @discardableResult
    static func arm(
        card: any ZoomFlightCard,
        pageSize: CGSize,
        mirroring destination: any ZoomTransitionDestination,
        window: CFTimeInterval = ZoomLiveMediaRetry.window
    ) -> ZoomLiveMediaRetry? {
        guard card.zoomLiveMediaSurface == nil else { return nil }
        let retry = ZoomLiveMediaRetry(
            card: card,
            pageSize: pageSize,
            window: window,
            // The other screen's picture, arriving over this one's.
            fadesIn: true,
            acquire: { [weak destination] card in
                guard let destination else { return nil }
                card.adoptZoomLiveMedia { destination.zoomMirrorLiveMedia(onto: $0) }
                return card.zoomLiveMediaSurface
            }
        )
        retry.start()
        return retry
    }

    private init(card: any ZoomFlightCard,
                 pageSize: CGSize,
                 window: CFTimeInterval,
                 fadesIn: Bool,
                 acquire: @escaping (any ZoomFlightCard) -> UIView?) {
        self.card = card
        self.pageSize = pageSize
        self.fadesIn = fadesIn
        self.acquire = acquire
        self.deadline = CACurrentMediaTime() + window
        super.init()
        #if DEBUG
        ZoomDebugCensus.increment(ZoomDebugCensus.Key.liveMediaRetry)
        #endif
    }

    #if DEBUG
    deinit {
        ZoomDebugCensus.decrement(ZoomDebugCensus.Key.liveMediaRetry)
    }
    #endif

    #if DEBUG
    /// The display link's own beat, for a suite that cannot wait for frames.
    /// Deliberately the SAME entry point the link uses: a test driving a
    /// parallel implementation would pin a route the app never takes.
    func debugTick() { tick() }
    /// Whether the retry is still asking.
    var debugIsAsking: Bool { link != nil }
    /// The landing, for a suite that cannot wait out a real flight. The SAME
    /// entry point the deadline takes, for the reason `debugTick` states: a
    /// test driving a parallel implementation would pin a route the app never
    /// takes — and the arrival of a held-back surface happens exactly here.
    func debugFinish() { stop() }
    #endif

    private func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        // The backstop: a flight that never settles — caught, cancelled, torn
        // down — still has to hand its picture over rather than leave it held.
        if let card { arrive(card) }
    }

    /// Whether the card's presentation has caught up with where it is going.
    ///
    /// Both axes, because a spring on a card that changes aspect reaches one
    /// before the other. A tolerance rather than equality: a presentation lands
    /// on its model asymptotically and would never test equal.
    private func cardHasSettled(_ card: any ZoomFlightCard) -> Bool {
        guard let presented = card.layer.presentation()?.bounds.size else { return true }
        let target = card.layer.bounds.size
        guard target.width > 0, target.height > 0 else { return false }
        return abs(presented.width - target.width) <= max(0.5, target.width * 0.005)
            && abs(presented.height - target.height) <= max(0.5, target.height * 0.005)
    }

    /// Poses the held surface exactly, then lets it be seen.
    ///
    /// The first instant it CAN be posed exactly is the card's own landing: the
    /// card is the page then, so this pose crosses no gap and the fade that
    /// follows has nothing to reconcile. Floored at 0.2s, for the reason the
    /// fade always was — a surface adopted in the last few milliseconds should
    /// still be SEEN to arrive rather than cut.
    private func arrive(_ card: any ZoomFlightCard) {
        guard hasAdopted, fadesIn, !hasArrived else { return }
        hasArrived = true
        poseAtLanding(card)
        card.fadeInAdoptedLiveMedia(over: 0.2)
    }

    @objc private func tick() {
        // A card that left the tree took its flight with it — landed,
        // cancelled, or caught and thrown by something else.
        guard let card, card.window != nil else { return stop() }

        if hasAdopted {
            follow(card)
            // ⚠️ THE ARRIVAL IS THE CARD STOPPING, NOT THE CLOCK RUNNING OUT.
            // This window is the spring's NOMINAL duration, and a spring is
            // visually still long before it is nominally over — releasing on
            // the deadline left a third of a second of blurred cover on a page
            // that had already landed. The hold exists because a travelling
            // card cannot be posed exactly, so it ends when the card stops
            // travelling.
            if !hasArrived, hasTravelled, cardHasSettled(card) { arrive(card) }
            // The follow ends with the FLIGHT, not with the adoption: the
            // surface must still be posed on the frame the card lands on.
            if CACurrentMediaTime() >= deadline { stop() }
            return
        }
        if !hasTravelled, !cardHasSettled(card) { hasTravelled = true }
        guard CACurrentMediaTime() < deadline else { return stop() }
        guard let surface = acquire(card) else { return }
        adopt(surface, on: card)
    }

    private func adopt(_ surface: UIView, on card: any ZoomFlightCard) {
        liveMediaSize = ZoomFlight.liveMediaLayoutSize(
            native: card.zoomLiveMediaNativeSize, page: pageSize
        )
        // ⚠️ THE SURFACE MAY ARRIVE ALREADY ANIMATING, and then no amount of
        // posing it moves anything.
        //
        // A surface that came from the other SCREEN is a fresh subview with no
        // animations on it, and every value written below lands. A card's OWN
        // surface does not: it has been inside the card since take-off, so the
        // card's animated bounds gave it inherited position/bounds animations
        // through autoresizing, and those are still running. `follow` writes
        // MODEL values with actions disabled — correct, and completely
        // invisible while a live animation owns the presentation. Measured: the
        // model said 402x874 at scale 0.42 centred, while the presentation was
        // a 34x66 patch at (-92, -244) — exactly the misplaced rectangle of
        // video on a black card that was filmed.
        //
        // Recursive, because the poster inside the surface inherited the same
        // animation and lags the same way.
        Self.stopInheritedAnimations(on: surface.layer)
        // ⚠️ AFTER the stilling, never before, and this ORDER is the fix. The
        // sweep is a recursive `removeAllAnimations`, so a layout written ahead
        // of it survives only as a model value — and the model is already the
        // card's landing size while the card is a third of the way there. That
        // is how the surface came to present the page's full width against a
        // 138pt window: 263.68pt of disagreement, with `surfAnims=0` beside it
        // saying plainly that nothing was driving it.
        card.prepareZoomLiveMediaForFlight(destinationSize: liveMediaSize)
        // ⚠️ AND THE ARRIVAL WAITS FOR THE LANDING. A surface acquired after
        // the flight's animation block has run has missed the only pose that is
        // exact; `follow` below is a display link and is a frame behind by
        // construction. Held at zero it does not matter what it is posed at
        // until the card has stopped — see
        // `ZoomFlightCard.holdAdoptedLiveMediaUntilLanding`.
        //
        // Only the fading arm: a card adopting its OWN surface is showing the
        // same picture it already showed, and holding it back would blank a
        // tile that was never wrong.
        if fadesIn { card.holdAdoptedLiveMediaUntilLanding() }
        hasAdopted = true
        follow(card)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f retry ADOPTED mid-flight (%@)",
                         CACurrentMediaTime(), String(describing: type(of: surface))))
        }
        #endif
    }

    /// Clears animations from a layer tree, so per-frame posing is what the
    /// screen shows.
    private static func stopInheritedAnimations(on layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach(stopInheritedAnimations)
    }

    /// Poses the surface on the card's CURRENT on-screen size.
    ///
    /// Unanimated by construction: every value here is derived from a frame
    /// that has already been composited, so an implicit animation would be a
    /// second interpolation of an interpolation — the drift this class exists
    /// to avoid.
    private func follow(_ card: any ZoomFlightCard) {
        pose(card, in: (card.layer.presentation() ?? card.layer).bounds.size)
    }

    /// The landing pose, taken from the card's MODEL bounds.
    ///
    /// The presentation is still a fraction of a point out at the moment the
    /// window closes — a spring overshoots to 405.8 and settles back — and the
    /// held-back arrival is about to be faded up against it. The model is where
    /// the card is going to be, which is the only value worth landing on.
    private func poseAtLanding(_ card: any ZoomFlightCard) {
        pose(card, in: card.layer.bounds.size)
    }

    private func pose(_ card: any ZoomFlightCard, in size: CGSize) {
        guard !card.zoomLiveMediaTracksCardBounds,
              let surface = card.zoomLiveMediaSurface
        else { return }
        guard size.width > 0, size.height > 0 else { return }
        let scale = ZoomFlight.liveMediaScale(covering: size, surface: liveMediaSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.transform = CGAffineTransform(scaleX: scale, y: scale)
        surface.center = CGPoint(x: size.width / 2, y: size.height / 2)
        CATransaction.commit()
    }
}
