import Testing
@testable import Feed

/// Which surface a landing page keeps (#639).
///
/// ⚠️ A CARD SURFACE WITH NO FRAME HANDS NOTHING OVER. The landing adopts the
/// card's surface to continue the frame it was showing. One whose mirror never
/// drew replaced a page that was already showing its poster, and the viewer got
/// black and the spinner until the adopted surface drew.
@MainActor
struct LandingAdoptionTests {
    @Test("A frameless card surface never replaces a page that is already showing something")
    func aFramelessSurfaceIsRefused() {
        #expect(SnapFeedCell.keepsOwnSurface(incomingHasFrame: false, ownIsShowing: true))
    }

    @Test("A card surface with a frame is adopted, as always: it continues the picture the card flew")
    func aDrawingSurfaceIsAdopted() {
        #expect(!SnapFeedCell.keepsOwnSurface(incomingHasFrame: true, ownIsShowing: true))
        #expect(!SnapFeedCell.keepsOwnSurface(incomingHasFrame: true, ownIsShowing: false))
    }

    @Test("With nothing on the page either, the adoption goes ahead: there is nothing to lose")
    func nothingToKeep() {
        #expect(!SnapFeedCell.keepsOwnSurface(incomingHasFrame: false, ownIsShowing: false))
    }
}
