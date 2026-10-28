import DesignSystem
import Testing
import UIKit
@testable import Maps

/// The locate button waiting for a first fix (#1775): past the loader's
/// grace, the kit's loader in the glyph's place — kept through a redraw of
/// the button.
@MainActor
struct LocateButtonWaitTests {
    @Test func theLoaderTakesTheGlyphsPlaceUntilTheFix() {
        let controls = MapLocationControlsView()
        controls.apply(.button(.allowed))
        controls.setLocating(true)
        #expect(controls.isLocating)
        #expect(!controls.debugShowsLocating, "a loader before the grace")
        controls.debugElapseLocatingGrace()
        #expect(controls.debugShowsLocating)
        controls.apply(.button(.allowed))
        #expect(controls.debugShowsLocating, "a redraw put the glyph back over the wait")
    }
}
