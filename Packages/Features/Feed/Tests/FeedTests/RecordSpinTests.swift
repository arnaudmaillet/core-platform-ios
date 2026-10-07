import QuartzCore
import Testing
@testable import Feed

/// The cover turning like a record while its sound plays (#580).
@MainActor
struct RecordSpinTests {
    @Test func aPlayingSoundTurnsTheCover() {
        let layer = CALayer()
        layer.setRecordSpinning(true, reducesMotion: false)
        #expect(layer.animation(forKey: "sound.recordSpin") != nil)
        #expect(layer.speed == 1)
    }

    /// Reduce Motion or Power Saving: the cover stays still, so an endless
    /// turn doesn't keep the screen redrawing for as long as the sound plays.
    @Test func underReducedMotionTheCoverStaysStill() {
        let layer = CALayer()
        layer.setRecordSpinning(true, reducesMotion: true)
        #expect(layer.animation(forKey: "sound.recordSpin") == nil)
    }

    /// Turning Power Saving on mid-play pauses the turn where it is.
    @Test func reducedMotionMidPlayPausesTheTurn() {
        let layer = CALayer()
        layer.setRecordSpinning(true, reducesMotion: false)
        layer.setRecordSpinning(true, reducesMotion: true)
        #expect(layer.speed == 0)
    }
}
