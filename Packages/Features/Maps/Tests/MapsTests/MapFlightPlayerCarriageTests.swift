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
