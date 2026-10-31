import Testing
import UIKit
@testable import Feed

/// The playhead's drawing, once (#1964): the Shots strip's clip bar and the
/// sound sheet's track draw their played part, cursor and loading pulse with
/// the same `PlayheadBarRenderer`.
@MainActor
struct PlayheadBarTests {
    private func bar(width: CGFloat = 200) -> PlayheadBarView {
        let bar = PlayheadBarView(frame: CGRect(x: 0, y: 0, width: width, height: PlayheadBarView.cursorRoom))
        bar.layoutIfNeeded()
        return bar
    }

    /// The played part is the fraction of the track's width; none without a
    /// position.
    @Test func thePlayedPartIsTheFractionOfTheTrack() {
        let bar = bar()
        #expect(bar.debugPlayedWidth == nil, "a position drawn before any was known")
        bar.setProgress(0.25)
        #expect(bar.debugPlayedWidth == 50)
        bar.setProgress(1.4)
        #expect(bar.debugPlayedWidth == 200, "the played part overran the track")
        bar.setProgress(nil)
        #expect(bar.debugPlayedWidth == nil)
    }

    /// Loading hands the bar to the pulse, and back.
    @Test func loadingHandsTheBarToThePulse() {
        let bar = bar()
        bar.setProgress(0.5)
        bar.setLoading(true)
        #expect(bar.debugIsLoading)
        bar.setLoading(false)
        #expect(!bar.debugIsLoading)
        #expect(bar.debugPlayedWidth == 100)
    }

    /// The Shots strip draws with the same renderer: its cursor's sizes are
    /// the renderer's.
    @Test func theStripSharesTheRenderersCursor() {
        #expect(SnapMediaPageBarView.cursorDiameter == PlayheadBarRenderer.cursorDiameter)
        #expect(SnapMediaPageBarView.handledCursorSize == PlayheadBarRenderer.handledCursorSize)
    }
}
