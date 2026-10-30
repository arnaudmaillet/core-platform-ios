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

    /// Two transitions overlapping (a push begun before the previous one's
    /// completion ran): the older end neither settles the share nor stops the
    /// newer one's sampling; the newer end does.
    @Test func onlyTheLatestTransitionSettlesTheShare() {
        let share = ViewportShare(host: UIView())
        let first = share.beginTracking(UIView())
        let second = share.beginTracking(UIView())
        share.transitionEnded(first, cancelled: false, coversAtEnd: true)
        #expect(share.share == 1, "the older push's end overwrote the newer transition's share")
        share.transitionEnded(second, cancelled: true, coversAtEnd: true)
        #expect(share.share == 1)
        let third = share.beginTracking(UIView())
        share.transitionEnded(third, cancelled: false, coversAtEnd: true)
        #expect(share.share == 0)
    }

    /// A cancelled transition hands the host its own screen as the cover
    /// (the owner's device: a drag toward the profile abandoned left the
    /// post paused, silent). The host, or a screen holding it, never covers
    /// it; the transition's real cover, tracked from its start, settles it.
    @Test func theHostIsNeverItsOwnCover() {
        let screen = UIView()
        let host = UIView()
        screen.addSubview(host)
        let share = ViewportShare(host: host)
        #expect(!share.isCover(host))
        #expect(!share.isCover(screen), "the screen holding the host covered it")
        #expect(share.isCover(UIView()))

        // The push over the host, abandoned: its re-appearance is not tracked,
        // and the push's own end gives the host back its screen.
        let push = share.beginTracking(UIView())
        share.report(0.2)
        share.transitionEnded(push, cancelled: true, coversAtEnd: true)
        #expect(share.share == 1)
    }
}
