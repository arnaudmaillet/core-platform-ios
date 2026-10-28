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

    /// No fix past `takingLonger`: the wait ends and the viewer is told,
    /// once. A fix in time tells nothing.
    @Test func aFixThatNeverComesEndsTheWaitAndSaysSo() {
        let time = ManualLoadingClock()
        let controls = MapLocationControlsView()
        controls.clock = time.clock
        controls.apply(.button(.allowed))
        var toldGaveUp = 0
        controls.setLocating(true) { toldGaveUp += 1 }
        time.advance(LoadingTiming.takingLonger - 1)
        #expect(controls.isLocating)
        #expect(toldGaveUp == 0)
        time.advance(1)
        #expect(toldGaveUp == 1)
        // The loader has its minimum, then goes.
        time.advance(LoadingTiming.minimum)
        #expect(!controls.isLocating, "still waiting past takingLonger")
        #expect(!controls.debugShowsLocating)

        controls.setLocating(true) { toldGaveUp += 1 }
        time.advance(1)
        controls.setLocating(false)
        time.advance(LoadingTiming.takingLonger)
        #expect(toldGaveUp == 1, "a fix in time still gave up")
    }
}
