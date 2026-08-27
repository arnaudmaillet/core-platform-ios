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
    private let ask: () -> UIView?
    private let pageSize: CGSize
    private let deadline: CFTimeInterval
    private var link: CADisplayLink?
    private var liveMediaSize: CGSize = .zero
    private var hasAdopted = false

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
            // The source is held WEAKLY through this closure's own capture, so
            // a flight outliving its screen stops asking rather than keeping a
            // grid that is being torn down alive to answer.
            ask: { [weak source] in source?.zoomLiveMediaSurfaceIfReady() }
        )
        retry.start()
        return retry
    }

    private init(card: any ZoomFlightCard,
                 pageSize: CGSize,
                 window: CFTimeInterval,
                 ask: @escaping () -> UIView?) {
        self.card = card
        self.pageSize = pageSize
        self.ask = ask
        self.deadline = CACurrentMediaTime() + window
        super.init()
    }

    #if DEBUG
    /// The display link's own beat, for a suite that cannot wait for frames.
    /// Deliberately the SAME entry point the link uses: a test driving a
    /// parallel implementation would pin a route the app never takes.
    func debugTick() { tick() }
    /// Whether the retry is still asking.
    var debugIsAsking: Bool { link != nil }
    #endif

    private func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        // A card that left the tree took its flight with it — landed,
        // cancelled, or caught and thrown by something else.
        guard let card, card.window != nil else { return stop() }

        if hasAdopted {
            follow(card)
            // The follow ends with the FLIGHT, not with the adoption: the
            // surface must still be posed on the frame the card lands on.
            if CACurrentMediaTime() >= deadline { stop() }
            return
        }
        guard CACurrentMediaTime() < deadline else { return stop() }
        guard let surface = ask() else { return }
        adopt(surface, on: card)
    }

    private func adopt(_ surface: UIView, on card: any ZoomFlightCard) {
        card.adoptZoomLiveMediaView(surface)
        // The card is free to refuse — a wrong surface type, or one it has
        // since acquired for itself. Refusing is not a reason to stop asking.
        guard card.zoomLiveMediaSurface === surface else { return }
        liveMediaSize = ZoomFlight.liveMediaLayoutSize(
            native: card.zoomLiveMediaNativeSize, page: pageSize
        )
        card.prepareZoomLiveMediaForFlight(destinationSize: liveMediaSize)
        hasAdopted = true
        follow(card)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f retry ADOPTED mid-flight (%@)",
                         CACurrentMediaTime(), String(describing: type(of: surface))))
        }
        #endif
    }

    /// Poses the surface on the card's CURRENT on-screen size.
    ///
    /// Unanimated by construction: every value here is derived from a frame
    /// that has already been composited, so an implicit animation would be a
    /// second interpolation of an interpolation — the drift this class exists
    /// to avoid.
    private func follow(_ card: any ZoomFlightCard) {
        guard !card.zoomLiveMediaTracksCardBounds,
              let surface = card.zoomLiveMediaSurface
        else { return }
        let size = (card.layer.presentation() ?? card.layer).bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = ZoomFlight.liveMediaScale(covering: size, surface: liveMediaSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.transform = CGAffineTransform(scaleX: scale, y: scale)
        surface.center = CGPoint(x: size.width / 2, y: size.height / 2)
        CATransaction.commit()
    }
}
