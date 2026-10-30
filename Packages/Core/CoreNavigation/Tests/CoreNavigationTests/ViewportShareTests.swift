import Testing
import UIKit
@testable import CoreNavigation

/// The share of a screen still on screen (#1914): the rule a clip's gate
/// reads — it plays at half and above, and its sound follows the share.
@MainActor
struct ViewportShareTests {
    private let screen = CGRect(x: 0, y: 0, width: 400, height: 800)

    /// A push slides the cover in from the trailing edge: the host's share
    /// is what the cover leaves.
    @Test func theShareIsWhatTheCoverLeaves() {
        func share(coverX: CGFloat) -> CGFloat {
            ViewportShare.share(host: screen, cover: screen.offsetBy(dx: coverX, dy: 0), in: screen)
        }
        #expect(share(coverX: 400) == 1, "an off-screen cover hid something")
        #expect(abs(share(coverX: 200) - 0.5) < 0.001)
        #expect(abs(share(coverX: 100) - 0.25) < 0.001)
        #expect(share(coverX: 0) == 0)
    }

    @Test func aClipPlaysAtHalfAndAbove() {
        #expect(ViewportShare.plays(at: 1))
        #expect(ViewportShare.plays(at: 0.5))
        #expect(!ViewportShare.plays(at: 0.49))
        #expect(!ViewportShare.plays(at: 0))
    }

    /// The sound: full on the whole screen, silent at half, where the clip
    /// pauses.
    @Test func theSoundFollowsTheShare() {
        #expect(ViewportShare.volume(at: 1) == 1)
        #expect(abs(ViewportShare.volume(at: 0.75) - 0.5) < 0.001)
        #expect(ViewportShare.volume(at: 0.5) == 0)
        #expect(ViewportShare.volume(at: 0.2) == 0)
    }

    /// A host's own fraction is reported once per change, clamped.
    @Test func aReportedFractionIsToldOnce() {
        let share = ViewportShare(host: UIView())
        var told: [CGFloat] = []
        share.onChange = { told.append($0) }
        share.report(0.4)
        share.report(0.4)
        share.report(1.7)
        #expect(told == [0.4, 1])
        #expect(share.share == 1)
    }
}
