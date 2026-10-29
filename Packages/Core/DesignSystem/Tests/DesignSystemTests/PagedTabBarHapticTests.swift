import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// THE PILL'S DRAG TICKS (#1886): one `tick` each time the dragged pill's
/// centre crosses into another segment. A tap on a segment and a page set
/// by the host play nothing (#1881).
@MainActor
struct PagedTabBarHapticTests {
    private func bar() -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .floating)
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: PagedTabBar.Style.floating.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    @Test func aDragTicksOncePerSegmentCrossed() throws {
        let bar = bar()
        let centres = bar.debugSegmentFrames.map(\.midX)
        try #require(centres.count == 3)
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) {
            #expect(bar.debugBeginPillDrag(atViewportX: centres[0]))
            // Across the first, along the second, into the third, back.
            for x in [centres[0] + 20, centres[1], centres[1] + 10, centres[2], centres[1]] {
                now += 1
                bar.debugDragPill(toViewportX: x)
            }
            bar.debugEndPillDrag()
        }
        #expect(recorder.played == [.tick, .tick, .tick], "\(recorder.played)")
    }

    @Test func aTapOrAProgrammaticPagePlaysNothing() {
        let bar = bar()
        let played = HapticRecorder.recording {
            bar.debugSimulateTap(at: 2)
            bar.setProgress(1)
            bar.setProgress(0)
        }
        #expect(played.isEmpty, "\(played)")
    }
}
