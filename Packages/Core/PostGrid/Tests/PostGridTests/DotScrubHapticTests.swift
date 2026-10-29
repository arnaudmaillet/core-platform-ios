import DesignSystem
import Foundation
import Testing
import UIKit
@testable import PostGrid

/// THE DOTS SCRUB IN STEPS (#1885): one `step` per page the finger crosses,
/// as on the post screen's bar — none for a page the host moves to.
@MainActor
struct DotScrubHapticTests {
    @Test func theDotScrubStepsOncePerPageAndNeverForAProgrammaticChange() {
        let indicator = MediaPageIndicatorView()
        indicator.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
        indicator.configure(count: 10, current: 0)
        let page = MediaPageIndicatorView.pointsPerPage
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) {
            indicator.debugScrub(.began, atX: 10)
            for x in [10 + page * 0.4, 10 + page, 10 + page * 1.2, 10 + page * 2, 10 + page * 4] {
                now += 1
                indicator.debugScrub(.changed, atX: x)
            }
            indicator.debugScrub(.ended, atX: 10 + page * 4)
        }
        #expect(recorder.played == [.step, .step, .step], "\(recorder.played)")

        let moved = HapticRecorder.recording {
            indicator.setCurrent(4)
            indicator.setCurrent(7)
        }
        #expect(moved.isEmpty, "a programmatic page played \(moved)")
    }
}
