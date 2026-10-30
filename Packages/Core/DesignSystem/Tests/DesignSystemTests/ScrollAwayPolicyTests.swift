import Testing
import UIKit
@testable import DesignSystem

/// Away from its start, a stream's slot offers the way back (#1929).
struct ScrollAwayPolicyTests {
    private let viewport: CGFloat = 700

    /// It shows past a viewport, on the viewer's own scroll only, and hides
    /// under half a viewport whatever moved it.
    @Test func showsPastAViewportOnTheViewersScrollAndHidesUnderHalf() {
        var policy = ScrollAwayPolicy()
        let answer1 = policy.update(distance: 800, viewport: viewport, isUserScroll: false)
        #expect(!answer1, "a programmatic move showed it")
        let answer2 = policy.update(distance: 600, viewport: viewport, isUserScroll: true)
        #expect(!answer2, "it showed within a viewport")
        let answer3 = policy.update(distance: 800, viewport: viewport, isUserScroll: true)
        #expect(answer3)
        // Between the thresholds it holds: no flicker at the edge.
        let answer4 = policy.update(distance: 500, viewport: viewport, isUserScroll: true)
        #expect(answer4)
        let answer5 = policy.update(distance: 300, viewport: viewport, isUserScroll: false)
        #expect(!answer5, "it stayed near the start")
    }

    /// A stream that fits never shows it.
    @Test func aStreamThatFitsNeverShowsIt() {
        var policy = ScrollAwayPolicy()
        let answer6 = policy.update(distance: 0, viewport: viewport, isUserScroll: true)
        #expect(!answer6)
        let answer7 = policy.update(distance: 0, viewport: 0, isUserScroll: true)
        #expect(!answer7)
    }
}

/// The hold that arms an action on any view (#1929): the "+"'s timing and
/// disc, over the composer's slot.
@MainActor
struct HoldToArmPresenterTests {
    @Test func aHeldPressRaisesTheDiscAndFiresWhenTheRingFills() async throws {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let slot = UIView(frame: CGRect(x: 300, y: 700, width: 48, height: 48))
        host.view.addSubview(slot)
        var fired = 0
        let hold = HoldToArmPresenter(view: slot) { .symbol("pin") }
        hold.firedFace = { .symbol("pin.fill") }
        hold.onFire = { fired += 1 }

        hold.debugPress()
        let disc = try #require(hold.debugDisc, "no disc rose")
        #expect(disc.frame.maxY <= slot.frame.minY, "the disc is not over the slot")
        for _ in 0..<200 where fired == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fired == 1, "the ring filled and nothing fired")
        #expect(disc.debugGlyphImage == UIImage(systemName: "pin.fill"), "the disc did not say the new state")
        #expect(hold.debugDisc == nil)
    }

    @Test func liftedEarlyNothingFires() {
        let slot = UIView()
        var fired = 0
        let hold = HoldToArmPresenter(view: slot) { .symbol("pin") }
        hold.onFire = { fired += 1 }
        hold.debugPress()
        hold.debugRelease()
        #expect(fired == 0)
        #expect(hold.debugDisc == nil)
    }

    /// The "+"'s placement (#1929): a host hanging the hold on a whole bar
    /// says where the disc goes and in which view, and hears the press come
    /// and go — the selection lock's two ends.
    @Test func aHostPlacesTheDiscAndHearsThePress() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let bar = UIView(frame: CGRect(x: 0, y: 760, width: 390, height: 84))
        let overlay = UIView(frame: window.bounds)
        root.view.addSubview(bar)
        root.view.addSubview(overlay)
        let bubble = CGRect(x: 326, y: 770, width: 48, height: 48)
        var events: [String] = []
        let hold = HoldToArmPresenter(view: bar) { .symbol("camera.fill") }
        hold.host = { overlay }
        hold.discFrame = { host in HoldToArmPresenter.frame(over: bubble, in: host.bounds) }
        hold.onPressBegan = { events.append("began") }
        hold.onPressFinished = { events.append("finished") }

        hold.debugPress(at: CGPoint(x: bubble.midX, y: 10))
        let disc = try #require(hold.debugDisc)
        #expect(disc.superview === overlay, "the disc is not in the host's view")
        #expect(abs(disc.frame.midX - min(bubble.midX, 390 - HoldToArmPresenter.Metrics.edgeMargin - disc.frame.width / 2)) < 0.5)
        #expect(disc.frame.maxY == bubble.minY - HoldToArmPresenter.Metrics.gap)
        #expect(hold.isHolding)
        hold.debugRelease()
        #expect(!hold.isHolding)
        #expect(events == ["began", "finished"])
    }

    /// The default placement: over the view, clear of the screen's sides,
    /// and under a ceiling when one is given.
    @Test func theDiscFrameStaysClearOfTheEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let side = HoldRingDiscView.Metrics.diameter
        let nearEdge = HoldToArmPresenter.frame(over: CGRect(x: 370, y: 700, width: 20, height: 20), in: bounds)
        #expect(nearEdge.maxX <= 390 - HoldToArmPresenter.Metrics.edgeMargin + 0.5)
        #expect(nearEdge.height == side)
        let underCeiling = HoldToArmPresenter.frame(
            over: CGRect(x: 100, y: 700, width: 48, height: 48), ceiling: 650, in: bounds
        )
        #expect(underCeiling.maxY == 650 - HoldToArmPresenter.Metrics.gap)
    }
}
