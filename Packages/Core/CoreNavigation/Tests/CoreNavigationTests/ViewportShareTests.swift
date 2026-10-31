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
            ViewportShare.share(coveredBy: screen.offsetBy(dx: coverX, dy: 0), in: screen)
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

    /// The host's own arrival or departure (a push, a pop, a grab holding
    /// it): the part of the SCREEN it takes.
    @Test func aMovingHostTakesItsPartOfTheScreen() {
        func share(_ host: CGRect) -> CGFloat { ViewportShare.ownShare(of: host, in: screen) }
        #expect(share(screen) == 1)
        #expect(abs(share(screen.offsetBy(dx: 200, dy: 0)) - 0.5) < 0.001, "a slide half off")
        #expect(abs(share(screen.offsetBy(dx: 300, dy: 0)) - 0.25) < 0.001)
        #expect(share(screen.offsetBy(dx: 400, dy: 0)) == 0)
        // Held smaller in the middle of the screen, as a grab holds it: the
        // screen it takes, not its own size.
        #expect(abs(share(CGRect(x: 80, y: 160, width: 240, height: 480)) - 0.36) < 0.001)
        #expect(share(.zero) == 0)
    }

    /// A departure settles on gone once it completes, and on whole again
    /// when it is abandoned.
    @Test func aDepartureEndsGoneOrWhole() {
        let share = ViewportShare(host: UIView())
        let abandoned = share.beginDeparture()
        share.report(0.7)
        share.transitionEnded(abandoned, cancelled: true, coversAtEnd: true)
        #expect(share.share == 1, "an abandoned grab left the host short of its screen")
        let gone = share.beginDeparture()
        share.transitionEnded(gone, cancelled: false, coversAtEnd: true)
        #expect(share.share == 0)
    }

    /// An arrival (a push bringing the host in) settles on whole once it
    /// completes, and on gone when it is abandoned.
    @Test func anArrivalEndsWholeOrGone() {
        let share = ViewportShare(host: UIView())
        share.report(0)
        let abandoned = share.beginDeparture()
        share.transitionEnded(abandoned, cancelled: true, coversAtEnd: false)
        #expect(share.share == 0, "an abandoned push left the host playing")
        let arrived = share.beginDeparture()
        share.transitionEnded(arrived, cancelled: false, coversAtEnd: false)
        #expect(share.share == 1)
    }

    /// The gate a host with no sound to fade reads: told once per flip.
    @Test func thePlaysGateIsToldOncePerFlip() {
        let share = ViewportShare(host: UIView())
        var told: [Bool] = []
        share.onPlaysChange = { told.append($0) }
        share.report(0.8)
        share.report(0.4)
        share.report(0.2)
        share.report(0.5)
        share.report(1)
        #expect(told == [false, true])
        #expect(share.plays)
    }

    /// A screen leaving with no transition to follow (a tab switch) reports
    /// gone at once; coming back with none leaves the start to its host.
    @Test func aScreenWithNoTransitionActsNow() {
        let screen = UIViewController()
        let share = ViewportShare(host: screen.view)
        #expect(share.screenWillDisappear(screen) == .now)
        #expect(share.share == 0)
        #expect(share.screenWillAppear(screen) == .now)
    }

    /// The leak the owner filmed: a page popped and shrunk by iOS, over the
    /// screen it uncovers. Measured against the same screen, the two shares
    /// add up to 1 at every frame, and at most one of them plays.
    @Test func twoScreensNeverPlayTogether() {
        for step in 0...40 {
            let progress = CGFloat(step) / 40
            let scale = 1 - 0.08 * progress
            let width = screen.width * scale, height = screen.height * scale
            let leaving = CGRect(
                x: screen.width * progress + (screen.width - width) / 2,
                y: (screen.height - height) / 2, width: width, height: height
            )
            let top = ViewportShare.ownShare(of: leaving, in: screen)
            let under = ViewportShare.share(coveredBy: leaving, in: screen) - ViewportShare.coveredYield
            #expect(!(ViewportShare.plays(at: top) && ViewportShare.plays(at: under)),
                    "both played at progress \(progress): \(top) over \(under)")
        }
        // The exact half goes to the screen on top.
        let half = screen.offsetBy(dx: screen.width / 2, dy: 0)
        #expect(ViewportShare.plays(at: ViewportShare.ownShare(of: half, in: screen)))
        #expect(!ViewportShare.plays(at: ViewportShare.share(coveredBy: half, in: screen) - ViewportShare.coveredYield))
    }

    /// The screen under a moving one follows its share rather than measuring
    /// it again: the complement, told in the same breath, so the two never
    /// both hold half — not even for a frame.
    @Test func aCoveredScreenFollowsTheScreenOverIt() {
        let top = UIView(), under = UIView()
        let topShare = ViewportShare(host: top)
        let underShare = ViewportShare(host: under)
        _ = underShare.beginTracking(top)
        _ = topShare.beginDeparture()
        topShare.adopt(underShare)
        for value in stride(from: CGFloat(1), through: 0, by: -0.01) {
            topShare.report(value)
            #expect(abs(topShare.share + underShare.share - 1) < 0.002)
            #expect(!(topShare.plays && underShare.plays), "both played at \(value)")
        }
        #expect(underShare.plays)
    }

    /// A screen inside a sheet takes its half of the SHEET: a section pushed
    /// half way across a medium-detent sheet holds half of it, though that is
    /// a quarter of the display.
    @Test func aScreenInASheetTakesItsHalfOfTheSheet() {
        let sheet = CGRect(x: 0, y: 400, width: 400, height: 400)
        let section = sheet.offsetBy(dx: 200, dy: 0)
        #expect(abs(ViewportShare.ownShare(of: section, in: sheet) - 0.5) < 0.001)
        #expect(abs(ViewportShare.ownShare(of: section, in: screen) - 0.25) < 0.001, "the premise: a quarter of the display")
        #expect(ViewportShare.plays(at: ViewportShare.ownShare(of: section, in: sheet)))
    }

    /// A sheet over the host is followed with no transition to end it, and
    /// settled when it goes. A newer transition owns the share meanwhile.
    @Test func aSheetIsFollowedUntilItGoes() {
        let host = UIView()
        let share = ViewportShare(host: host)
        share.trackCover(UIView())
        share.report(0.3)
        share.endCoverTracking(coveredAtEnd: false)
        #expect(share.share == 1, "the sheet gone left the host short of its screen")

        share.trackCover(UIView())
        let push = share.beginTracking(UIView())
        share.endCoverTracking(coveredAtEnd: false)
        share.report(0.2)
        #expect(share.share == 0.2, "an old sheet's end settled a newer transition's share")
        share.transitionEnded(push, cancelled: false, coversAtEnd: true)
        #expect(share.share == 0)
    }
}
