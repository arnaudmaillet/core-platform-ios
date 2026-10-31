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

    /// The video's handling (the owner, 2026-10-31): under the finger the
    /// track grows to 8 pt and the cursor turns into the pill; a drag seeks
    /// from where the playhead was; the released position is held.
    @Test func theBarGrowsAndSeeksUnderTheFinger() {
        let bar = bar()
        bar.isScrubbable = true
        bar.setProgress(0.5)
        var began = 0, sought: [Double] = [], ended: [Double?] = []
        bar.onScrubBegan = { began += 1 }
        bar.onSeekRequested = { sought.append($0) }
        bar.onScrubEnded = { ended.append($0) }

        bar.debugScrub(.began, atX: 100)
        bar.debugFinishTweens()
        #expect(bar.debugTrackHeight == SnapMediaPageBarView.handledTrackHeight)
        #expect(bar.debugCursorSize == SnapMediaPageBarView.handledCursorSize)

        bar.debugScrub(.changed, atX: 150)
        #expect(began == 1)
        #expect(abs((sought.last ?? 0) - 0.75) < 0.001, "the drag did not seek from the playhead")
        bar.debugScrub(.ended, atX: 150)
        bar.debugFinishTweens()
        #expect(ended.count == 1 && abs((ended[0] ?? 0) - 0.75) < 0.001)
        #expect(bar.debugTrackHeight == SnapMediaPageBarView.clipTrackHeight)
        #expect(bar.debugHeldPlayhead != nil, "the released position was not held")
    }

    /// A tap seeks where it lands; a bar that is not scrubbable ignores it.
    @Test func aTapSeeksWhereItLands() {
        let bar = bar()
        var sought: [Double] = []
        bar.onSeekRequested = { sought.append($0) }
        bar.debugScrub(.began, atX: 50)
        bar.debugScrub(.ended, atX: 50)
        #expect(sought.isEmpty, "a bar that is not scrubbable took a tap")
        bar.isScrubbable = true
        bar.debugScrub(.began, atX: 50)
        bar.debugScrub(.ended, atX: 50)
        #expect(sought == [0.25])
    }

    /// The pans above the bar wait for its scrub to fail — the sheet's drag
    /// and its scroll stand down while the finger is on the bar — and only
    /// once the bar takes a finger.
    @Test func thePansAboveTheBarStandDownForItsScrub() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let scroll = UIScrollView(frame: window.bounds)
        window.addSubview(scroll)
        window.isHidden = false
        defer { window.isHidden = true }
        let bar = bar()
        scroll.addSubview(bar)
        #expect(!bar.debugHolds(scroll.panGestureRecognizer), "a bar that takes no finger held a pan")
        bar.isScrubbable = true
        #expect(bar.debugHolds(scroll.panGestureRecognizer), "the scroll's pan would move with the scrub")
    }
}
