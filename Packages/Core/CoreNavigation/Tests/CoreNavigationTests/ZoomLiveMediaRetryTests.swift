@testable import CoreNavigation
import Testing
import UIKit

/// A card that took off with a poster is not a card that must keep one.
///
/// The whole class exists because the grid's answer to "is this post playing?"
/// is a function of TIME — the tap itself is often what starts the player — so
/// these pin the two halves of asking again: that a card already flying video
/// arms nothing, and that a surface arriving one frame after take-off still
/// reaches the card.
@MainActor
struct ZoomLiveMediaRetryTests {
    /// The smallest card that can hold a live surface, with the same adopt
    /// semantics the real ones have: take the view, keep it, report it.
    private final class StubCard: UIView, ZoomFlightCard {
        private(set) var preparedSize: CGSize?
        private(set) var wasAskedToFade = false
        var zoomLiveMediaSurface: UIView?
        var zoomRestingCornerRadius: CGFloat { 12 }
        var zoomRestingChrome: UIView? { nil }
        func setZoomCornerRadius(_ radius: CGFloat) {}
        func adoptZoomLiveMediaView(_ view: UIView) {
            addSubview(view)
            zoomLiveMediaSurface = view
        }
        func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
            preparedSize = destinationSize
        }
        func fadeInAdoptedLiveMedia(over duration: TimeInterval) {
            wasAskedToFade = true
        }
    }

    /// A source whose answer changes with time, which is the only thing about
    /// the real one that matters here.
    private final class StubSource: NSObject, ZoomTransitionSource {
        var surface: UIView?
        private(set) var asks = 0
        func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
        var zoomSourceIsOnScreen: Bool { true }
        func makeZoomFlightCard() -> any ZoomFlightCard { StubCard() }
        func setZoomSourceHidden(_ hidden: Bool) {}
        func zoomLiveMediaSurfaceIfReady() -> UIView? {
            asks += 1
            return surface
        }
    }

    /// A card that MIRRORS instead of taking a view — a marker's card, whose
    /// own render surface is the thing the page's player is attached to.
    private final class StubMirroringCard: UIView, ZoomFlightCard {
        let ownSurface = UIView()
        private(set) var preparedSize: CGSize?
        /// The duration the card was asked to fade its adopted media in over,
        /// nil when it was never asked.
        private(set) var fadeDuration: TimeInterval?
        private var isLive = false
        var zoomLiveMediaSurface: UIView? { isLive ? ownSurface : nil }
        var zoomRestingCornerRadius: CGFloat { 12 }
        var zoomRestingChrome: UIView? { nil }
        func setZoomCornerRadius(_ radius: CGFloat) {}
        func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
            guard mirror(ownSurface) else { return }
            addSubview(ownSurface)
            isLive = true
        }
        func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
            preparedSize = destinationSize
        }
        func fadeInAdoptedLiveMedia(over duration: TimeInterval) {
            fadeDuration = duration
        }
    }

    /// A page whose player arrives while the card is in the air, which is the
    /// whole shape of a map present: the marker flew a sheet, so the only
    /// player this post has is the one the page started at take-off.
    private final class StubPage: NSObject, ZoomTransitionDestination {
        var isPlaying = false
        private(set) var asks = 0
        func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
        func zoomFlightChrome() -> UIView? { nil }
        func setZoomContentHidden(_ hidden: Bool) {}
        func zoomTransitionDidEnd() {}
        var isReadyForInteractiveDismissal: Bool { true }
        func setContentScrollEnabled(_ enabled: Bool) {}
        func zoomMirrorLiveMedia(onto surface: UIView) -> Bool {
            asks += 1
            return isPlaying
        }
    }

    /// A card must be in a window for the retry to consider it airborne, and a
    /// test has no screen — so it gets one.
    private func staged(_ card: UIView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        card.frame = window.bounds
        window.addSubview(card)
        window.isHidden = false
        return window
    }

    /// ⚠️ A CARD THAT IS ALREADY FLYING VIDEO ARMS NOTHING.
    ///
    /// The retry costs a display link and a question per frame. Paying that for
    /// the common case — the tile was playing, the handshake worked — would be
    /// a per-transition cost for an answer already in hand.
    @Test func nothingIsArmedWhenTheCardLeftWithItsPicture() {
        let card = StubCard()
        card.zoomLiveMediaSurface = UIView()
        let source = StubSource()

        let retry = ZoomLiveMediaRetry.arm(card: card, pageSize: CGSize(width: 402, height: 874),
                                           source: source)

        #expect(retry == nil)
        #expect(source.asks == 0)
    }

    /// ⚠️ AND A SURFACE THAT ARRIVES AFTER TAKE-OFF STILL LANDS ON THE CARD.
    ///
    /// The measured sequence: the tap grants the tile a player, the URL
    /// resolves a turn later, the first frame decodes ~100ms in. Asked once, at
    /// flight-build time, the grid can only say no — and the flight carries the
    /// thumbnail for its whole length even though the picture existed for most
    /// of it.
    @Test func aSurfaceThatArrivesMidFlightIsAdopted() {
        let card = StubCard()
        let window = staged(card)
        let source = StubSource()
        // A window measured in minutes, not the flight's own: this test is
        // about the ADOPTION, and a real 0.42s window is a wall clock the test
        // runner can and did outrun between two assertions.
        let retry = ZoomLiveMediaRetry.arm(card: card, pageSize: CGSize(width: 402, height: 874),
                                           source: source, window: 600)

        // Frame 1: the grid still has nothing. The card keeps its poster and
        // the retry keeps asking — this is the state that used to be final.
        retry?.debugTick()
        #expect(card.zoomLiveMediaSurface == nil)
        #expect(retry?.debugIsAsking == true)

        // Frame 2: the player exists.
        let arrived = UIView()
        source.surface = arrived
        retry?.debugTick()

        // ⚠️ THE SOURCE IS ASKED ONCE PER FRAME, and this is the assertion
        // that catches the way this seam silently dies: the late ask reaches
        // conformers through `any ZoomTransitionSource`, so if it is ever
        // demoted from a protocol REQUIREMENT to an extension member, dispatch
        // goes static and every source answers the default's nil forever. That
        // failure looks exactly like "no player was ready" — the retry runs,
        // reports itself asking, and adopts nothing.
        #expect(source.asks == 2)
        #expect(card.zoomLiveMediaSurface === arrived)
        // And it is laid out for the flight, not merely parented: a surface
        // posed at the card's tile-sized bounds shows a crop of a crop.
        #expect(card.preparedSize == CGSize(width: 402, height: 874))
        window.isHidden = true
    }

    /// ⚠️ AND THE ASKING STOPS, whatever happens.
    ///
    /// Past the flight's settle the card is about to hand its media to a page
    /// that starts its own playback, so a late adoption can only mutate a card
    /// on its way out. A retry that outlived its flight would also outlive the
    /// screen that answers it.
    @Test func theRetryGivesUpAtItsWindow() {
        let card = StubCard()
        let window = staged(card)
        let source = StubSource()
        let retry = ZoomLiveMediaRetry.arm(card: card, pageSize: CGSize(width: 402, height: 874),
                                           source: source, window: 0)

        retry?.debugTick()

        #expect(retry?.debugIsAsking == false)
        #expect(source.asks == 0)
        #expect(card.zoomLiveMediaSurface == nil)
        window.isHidden = true
    }

    /// A card that never reached a window — a flight cancelled before its first
    /// frame — is not something to keep polling for.
    @Test func anUnstagedCardStopsTheRetry() {
        let card = StubCard()
        let source = StubSource()
        let retry = ZoomLiveMediaRetry.arm(card: card, pageSize: CGSize(width: 402, height: 874),
                                           source: source)

        retry?.debugTick()

        #expect(retry?.debugIsAsking == false)
        #expect(source.asks == 0)
    }

    /// ⚠️ THE LATE SIDE OF A MAP PRESENT IS THE ARRIVAL, NOT THE DEPARTURE.
    ///
    /// A marker flies a sprite sheet — nothing live leaves with the card — so
    /// the only surface this post can be decoding on is the page underneath,
    /// and it starts at take-off precisely because nothing is flying its
    /// player. Its first frame still lands mid-air, after the flight was built
    /// and told no. Without this the card wore a 172pt cover blown up sevenfold
    /// for the whole transition and the sharp picture appeared after the
    /// landing. Filmed, by the user, twice.
    @Test func aPageThatStartsPlayingMidFlightReachesTheCard() {
        let card = StubMirroringCard()
        let window = staged(card)
        let page = StubPage()
        let retry = ZoomLiveMediaRetry.arm(card: card, pageSize: CGSize(width: 402, height: 874),
                                           mirroring: page, window: 600)

        // Frame 1: the page's `play` has not registered yet — the state
        // `ZoomFlight.build` reads once and used to take as final.
        retry?.debugTick()
        #expect(card.zoomLiveMediaSurface == nil)
        #expect(retry?.debugIsAsking == true)

        // Frame 2: the player is attached.
        page.isPlaying = true
        retry?.debugTick()

        #expect(page.asks == 2, "the page must be asked every frame, not once")
        #expect(card.zoomLiveMediaSurface === card.ownSurface)
        // Laid out for the PAGE, not for the card's current tile-sized bounds:
        // a surface posed at the marker's size shows a crop of a crop.
        #expect(card.preparedSize == CGSize(width: 402, height: 874))
        window.isHidden = true
    }

    /// The same economy as the source arm: a card already flying video asks
    /// nobody, and a page is never asked to mirror a player the card holds.
    @Test func aLiveCardAsksThePageNothing() {
        let card = StubMirroringCard()
        card.adoptZoomLiveMedia { _ in true }
        let page = StubPage()

        let retry = ZoomLiveMediaRetry.arm(card: card, pageSize: CGSize(width: 402, height: 874),
                                           mirroring: page)

        #expect(retry == nil)
        #expect(page.asks == 0)
    }

    /// ⚠️ A SURFACE CAN ARRIVE ALREADY ANIMATING, and then posing it moves
    /// nothing at all.
    ///
    /// The surface a page mirrors onto is the card's OWN, and it has been
    /// inside the card since take-off — so the card's animated bounds gave it
    /// inherited position/bounds animations through autoresizing, and they are
    /// still running when the retry adopts. `follow` writes MODEL values with
    /// actions disabled, which a live animation simply outranks: measured on
    /// the simulator as a model saying 402x874 at scale 0.42, centred, while
    /// the presentation was a 34x66 patch at (-92, -244) — the misplaced
    /// rectangle of video on a black card that was filmed.
    ///
    /// A surface donated by the OTHER screen never had this, which is why the
    /// source arm went years without needing it.
    @Test func anAlreadyAnimatingSurfaceIsStilled() {
        let card = StubMirroringCard()
        let window = staged(card)
        let page = StubPage()
        page.isPlaying = true
        // What the card's animated layout leaves behind on its own subview.
        let inherited = CABasicAnimation(keyPath: "position")
        inherited.fromValue = CGPoint(x: 0, y: 0)
        inherited.toValue = CGPoint(x: 200, y: 400)
        inherited.duration = 10
        card.ownSurface.layer.add(inherited, forKey: "position")
        let poster = CALayer()
        poster.add(inherited, forKey: "position")
        card.ownSurface.layer.addSublayer(poster)

        let retry = ZoomLiveMediaRetry.arm(card: card, pageSize: CGSize(width: 402, height: 874),
                                           mirroring: page, window: 600)
        retry?.debugTick()

        #expect(card.zoomLiveMediaSurface === card.ownSurface)
        #expect(card.ownSurface.layer.animationKeys() == nil,
                "the adopted surface kept the animation that outranks every pose")
        #expect(poster.animationKeys() == nil,
                "the poster inside it lags the same way, so it is stilled too")
        window.isHidden = true
    }

    /// ⚠️ WHICH SIDE THE PICTURE CAME FROM DECIDES HOW IT APPEARS.
    ///
    /// A tile's surface is the card's own picture in motion — same post, same
    /// crop, already what the card was showing — so it replaces the cover and
    /// nothing should be seen to happen. A page's is the OTHER end of the
    /// flight arriving, and it comes up over a departure that stays fully
    /// drawn: the same law the reveal runs on.
    @Test func onlyTheArrivingSideFadesIn() {
        let arriving = StubMirroringCard()
        let arrivingWindow = staged(arriving)
        let page = StubPage()
        page.isPlaying = true
        ZoomLiveMediaRetry.arm(card: arriving, pageSize: CGSize(width: 402, height: 874),
                               mirroring: page, window: 600)?.debugTick()
        let fade = arriving.fadeDuration
        #expect(fade != nil, "the arriving picture cut in instead of fading")
        // The rest of the flight, floored so a late adoption is still seen to
        // arrive rather than snapping in over three milliseconds.
        #expect((fade ?? 0) >= 0.2)
        arrivingWindow.isHidden = true

        let departing = StubCard()
        let departingWindow = staged(departing)
        let source = StubSource()
        source.surface = UIView()
        ZoomLiveMediaRetry.arm(card: departing, pageSize: CGSize(width: 402, height: 874),
                               source: source, window: 600)?.debugTick()
        #expect(departing.zoomLiveMediaSurface === source.surface)
        #expect(departing.wasAskedToFade == false,
                "the card's own picture in motion was faded in over itself")
        departingWindow.isHidden = true
    }
}

