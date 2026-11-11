import DesignSystem
import Testing
import UIKit
@testable import Upload

/// The media editor's play and pause are the owner's (#2276), swapped by
/// the app's one swap: the timeline's button and the flash.
@MainActor
struct PlayPauseSiteTests {
    /// The timeline's button shows the owner's play while stopped and pause
    /// while it plays, at its 13 pt semibold.
    @Test func theTimelinesButtonShowsTheOwnersGlyphs() throws {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        track.layoutIfNeeded()
        let configuration = MediaTimelineTrackView.playGlyphConfiguration
        let play = try #require(track.debugPlayGlyph)
        #expect(play.isSymbolImage)
        #expect(play.size == AppSymbol.play.image(configuration)?.size)
        track.showPaused(false)
        let pause = try #require(track.debugPlayGlyph)
        #expect(pause.size == AppSymbol.pause.image(configuration)?.size)
        #expect(track.debugShowsPause)
    }

    /// The flash names the state with the owner's glyph; a second tap while
    /// it still shows swaps it in place — one glyph left once it lands.
    @Test func theFlashShowsTheOwnersGlyphs() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        let flash = MediaPlaybackFlashView()
        flash.reducesMotion = { false }
        window.addSubview(flash)
        flash.flash(paused: true, at: CGPoint(x: 195, y: 400))
        let pause = try #require(flash.debugGlyphImage)
        #expect(pause.isSymbolImage && pause.size == AppSymbol.pause.image()?.size)
        flash.flash(paused: false, at: CGPoint(x: 195, y: 400))
        let play = try #require(flash.debugGlyphImage)
        #expect(play.size == AppSymbol.play.image()?.size)
        for _ in 0..<40 where PlayPauseGlyph.debugCopies(of: flash.debugGlyphView) > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(PlayPauseGlyph.debugCopies(of: flash.debugGlyphView) == 0, "the swap left a copy behind")
    }
}
