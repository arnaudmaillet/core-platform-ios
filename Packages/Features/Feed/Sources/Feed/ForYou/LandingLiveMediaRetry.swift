import CoreModels
import CoreNavigation
import MediaPlayback
import UIKit

/// Keeps asking for the LANDING row's moving picture for as long as the flight
/// is in the air.
///
/// ## Why asking once is not enough
///
/// The landing operand is joined to whatever the landing row is drawing, and at
/// the instant the card is built that row may be drawing nothing: it scrolled
/// out of the autoplay window while the post was open, or it never entered one.
/// A single ask at take-off answers nil there and the card falls back to the
/// still — which is the thumbnail this whole operand exists to remove.
///
/// So the first refusal DEMANDS playback instead of accepting it
/// (`GridVideoPlaybackCoordinator.demandFlightPlayback`, whose entire reason to
/// exist is a flight that needs a player the ordinary ranking will not grant),
/// and this keeps asking until that start produces a frame. The same shape as
/// `ZoomLiveMediaRetry`, which does it for the DEPARTURE — and deliberately not
/// the same class: that one owns the card's flying surface and poses it by
/// transform every frame, while this operand is autoresized inside the pane and
/// needs installing exactly once.
///
/// ## Bounded, and quiet when there is nothing to wait for
///
/// The window is the flight's own spring. Past it the card is about to hand over
/// to the row, so a later adoption could only mutate a card on its way out.
@MainActor
final class LandingLiveMediaRetry: NSObject {
    private weak var card: (any ZoomFlightCard)?
    private let ask: () -> UIView?
    private let deadline: CFTimeInterval
    private var link: CADisplayLink?

    /// Starts asking. Returns nil — and costs nothing — when the first ask
    /// already succeeded, which is the common case: the row the viewer opened
    /// keeps its loan for the whole trip.
    @discardableResult
    static func arm(
        card: any ZoomFlightCard,
        window: CFTimeInterval = ZoomFlightSpring.duration,
        ask: @escaping () -> UIView?
    ) -> LandingLiveMediaRetry? {
        if let surface = ask() {
            card.setZoomLandingLiveMedia(surface)
            return nil
        }
        let retry = LandingLiveMediaRetry(card: card, window: window, ask: ask)
        retry.start()
        return retry
    }

    private init(
        card: any ZoomFlightCard, window: CFTimeInterval, ask: @escaping () -> UIView?
    ) {
        self.card = card
        self.ask = ask
        self.deadline = CACurrentMediaTime() + window
        super.init()
    }

    private func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    #if DEBUG
    /// The display link's own beat, for a suite that cannot wait for frames —
    /// the same entry point the link uses, so a test cannot pin a route the app
    /// never takes.
    func debugTick() { tick() }
    var debugIsAsking: Bool { link != nil }
    #endif

    @objc private func tick() {
        // A card that left the tree took its flight with it.
        guard let card, card.window != nil else { return stop() }
        guard CACurrentMediaTime() < deadline else { return stop() }
        guard let surface = ask() else { return }
        card.setZoomLandingLiveMedia(surface)
        stop()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f landing operand ADOPTED mid-flight",
                         CACurrentMediaTime()))
        }
        #endif
    }
}
