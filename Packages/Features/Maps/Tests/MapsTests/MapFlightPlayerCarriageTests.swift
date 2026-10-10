import CoreModels
import Foundation
import MediaPlayback
import Testing
@testable import Maps

/// What a marker's flight card is carrying, which is the fact the arriving page
/// reads to decide whether to hold its own playback back.
///
/// ⚠️ THE ANSWER IS ABOUT A PLAYER, NOT ABOUT MEDIA. A video pin wearing a
/// baked sprite sheet is animating and is not playing: the sheet is a bundled
/// picture with no `AVPlayer` behind it, so the page it opens can start
/// decoding at take-off instead of at the landing. Deferring there bought a
/// beat of poster-then-black against a collision that cannot happen — the
/// defect this rule exists to end.
///
/// Asserted through the static rule rather than through a built source: this
/// target never instantiates an `MKMapView` (see `MapAnnotationPopTests`).
@MainActor
struct MapFlightPlayerCarriageTests {
    @Test("A pin that is not previewing flies a sheet, and a sheet is nobody's player")
    func aStillPinCarriesNothing() {
        #expect(MapPinZoomSource.fliesLivePlayer(canMirror: true, isLivePreviewing: false) == false)
    }

    @Test("A pin previewing live flies the page's own player — the deferral's whole reason")
    func aLivePinCarriesThePlayer() {
        #expect(MapPinZoomSource.fliesLivePlayer(canMirror: true, isLivePreviewing: true))
    }

    @Test("A cluster has no single post to preview, so its card can carry no player")
    func aClusterCarriesNothing() {
        #expect(MapPinZoomSource.fliesLivePlayer(canMirror: false, isLivePreviewing: nil) == false)
        // Even handed an answer, which it never is: no mirror, no carriage.
        #expect(MapPinZoomSource.fliesLivePlayer(canMirror: false, isLivePreviewing: true) == false)
    }

    @Test("A source that can mirror but cannot be asked says the conservative thing")
    func anUnaskableSourceDefersRatherThanGuesses() {
        // The wiring that would produce this — a `mirrorLive` passed without
        // its probe — is a mistake, and the failure it must not have is the
        // page blanking a card mid-flight. Deferring costs a beat; guessing
        // wrong costs the picture.
        #expect(MapPinZoomSource.fliesLivePlayer(canMirror: true, isLivePreviewing: nil))
    }
}

/// The donor player a flight card is mirroring, and the sweep that used to kill
/// it mid-air.
///
/// ⚠️ `setSurfaceVisible(false, keeping:)` spares one pin so the hero can fly
/// its live preview — and `update(candidates:)` swept it away again. With the
/// surface hidden, `update` chooses NOTHING, so its "stop everything not
/// chosen" loop stopped the kept pin too. It is called on every query result,
/// every annotation add and every pan settle, so a result landing inside the
/// 0.42s flight blanked the video in the window with nothing in any log to say
/// why. The exemption was a one-shot; it had to be a state.
@MainActor
struct MapDonorPlayerCarriageTests {

    private final class SpyHost: MapVideoHost {
        let videoRenderView = VideoRenderView()
        var onReuse: (() -> Void)?
        private(set) var began = 0
        private(set) var ended = 0
        func beginVideoPreview() { began += 1 }
        func endVideoPreview() { ended += 1 }
    }

    /// Nothing is ever asked to play: `update` and `setSurfaceVisible` decide
    /// WHICH pins should be playing, and that decision is the whole subject.
    private struct SilentSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    /// A coordinator the map has told it is on screen — every test here is
    /// about what a VISIBLE map does (it is not visible at birth).
    private func makeCoordinator() -> (MapVideoPlaybackCoordinator, VideoPlaybackController) {
        let pool = VideoPlaybackController(source: SilentSource(), poolSize: 4, capacity: 4)
        let coordinator = MapVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        coordinator.setSurfaceVisible(true)
        return (coordinator, pool)
    }

    @Test func aReconcileDuringAFlightLeavesTheDonorPlaying() {
        let (coordinator, _) = makeCoordinator()
        let donor = SpyHost()
        let other = SpyHost()
        let donorID = PostID(rawValue: "post-donor")
        let otherID = PostID(rawValue: "post-other")
        let url = URL(string: "mock://video/1")!

        coordinator.update(candidates: [
            MapVideoPlaybackCoordinator.Candidate(id: donorID, url: url, host: donor),
            MapVideoPlaybackCoordinator.Candidate(id: otherID, url: url, host: other),
        ])
        #expect(donor.began == 1)
        #expect(other.began == 1)

        // The flight takes off: the map goes away, the donor is spared.
        coordinator.setSurfaceVisible(false, keeping: donorID)
        #expect(other.ended == 1, "the pins the flight is not carrying must stop")
        #expect(donor.ended == 0, "the donor is what the card is mirroring")

        // A query result lands mid-flight — the reconcile that used to kill it.
        coordinator.update(candidates: [
            MapVideoPlaybackCoordinator.Candidate(id: donorID, url: url, host: donor),
            MapVideoPlaybackCoordinator.Candidate(id: otherID, url: url, host: other),
        ])
        #expect(donor.ended == 0, "the reconcile swept away the player the card was flying")
    }

    @Test func theLandingEndsTheSparing() {
        let (coordinator, _) = makeCoordinator()
        let donor = SpyHost()
        let donorID = PostID(rawValue: "post-donor")
        coordinator.update(candidates: [
            MapVideoPlaybackCoordinator.Candidate(id: donorID, url: URL(string: "mock://video/1")!, host: donor)
        ])
        coordinator.setSurfaceVisible(false, keeping: donorID)
        coordinator.stopAll()
        #expect(donor.ended == 1, "the flight landed and nothing releases the donor")
    }

    /// Coming back to the map clears the exemption, so the next hide starts
    /// from a clean slate rather than inheriting the last flight's donor.
    @Test func returningToTheMapForgetsTheDonor() {
        let (coordinator, _) = makeCoordinator()
        let donor = SpyHost()
        let donorID = PostID(rawValue: "post-donor")
        let url = URL(string: "mock://video/1")!
        coordinator.update(candidates: [MapVideoPlaybackCoordinator.Candidate(id: donorID, url: url, host: donor)])
        coordinator.setSurfaceVisible(false, keeping: donorID)
        coordinator.setSurfaceVisible(true)
        // Nothing chosen any more: the sweep must now be free to stop it.
        coordinator.update(candidates: [])
        #expect(donor.ended == 1, "a stale exemption kept a pin playing off-screen")
    }

    /// ⚠️ A MAP NOBODY HAS SHOWN PLAYS NOTHING.
    ///
    /// `update` runs on every annotation add, so a map built before it is on
    /// screen is asked to play long before `viewWillAppear` — and with the old
    /// `true` default it did, on players the rest of the app shares.
    @Test func aMapNeverShownPlaysNothing() {
        let pool = VideoPlaybackController(source: SilentSource(), poolSize: 4, capacity: 4)
        let coordinator = MapVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        let pin = SpyHost()
        let id = PostID(rawValue: "post-pin")

        coordinator.update(candidates: [
            MapVideoPlaybackCoordinator.Candidate(id: id, url: URL(string: "mock://video/1")!, host: pin)
        ])

        #expect(pin.began == 0, "a map that was only constructed started a preview")
    }

    /// The witness: told it is visible, the same candidate plays. A gate that
    /// never opened would pass the test above on its own.
    @Test func theFirstAppearanceStartsWhatTheMapAlreadyHolds() {
        let pool = VideoPlaybackController(source: SilentSource(), poolSize: 4, capacity: 4)
        let coordinator = MapVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        let pin = SpyHost()
        let candidate = MapVideoPlaybackCoordinator.Candidate(
            id: PostID(rawValue: "post-pin"), url: URL(string: "mock://video/1")!, host: pin
        )
        coordinator.update(candidates: [candidate])

        coordinator.setSurfaceVisible(true)
        coordinator.update(candidates: [candidate])

        #expect(pin.began == 1)
    }
}
