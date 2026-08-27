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

    /// A card must be in a window for the retry to consider it airborne, and a
    /// test has no screen — so it gets one.
    private func staged(_ card: StubCard) -> UIWindow {
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
}
