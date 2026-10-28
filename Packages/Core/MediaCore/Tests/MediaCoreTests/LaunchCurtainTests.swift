import Testing
import UIKit
@testable import MediaCore

/// The launch screen held over the shell until the first post has what it
/// shows, then faded out (#1812).
@MainActor
@Suite(.serialized)
struct LaunchCurtainTests {
    /// What decides the lift: a launch elsewhere at once, the page's signal,
    /// or the cap — nothing else.
    /// Without a QA start index, the curtain lifts on the first page that has
    /// what it shows; under `-snap-start-index` (DEBUG) it waits for the page
    /// asked for (#1855). A test process carries no such flag.
    @Test func theCurtainLiftsOnTheFirstPageOutsideAQAStartIndex() {
        #expect(!ProcessInfo.processInfo.arguments.contains(LaunchCurtain.startIndexFlag))
        #expect(LaunchCurtain.readyMilestone == "shots.firstPageReady")
        #expect(LaunchCurtain.cap == 2)
    }

    @Test func theRevealDecision() {
        #expect(LaunchCurtain.decision(pageReady: false, sinceLaunch: 0.4, opensElsewhere: true) == .route)
        #expect(LaunchCurtain.decision(pageReady: true, sinceLaunch: 0.4, opensElsewhere: false) == .ready)
        #expect(LaunchCurtain.decision(pageReady: false, sinceLaunch: LaunchCurtain.cap, opensElsewhere: false) == .capped)
        #expect(LaunchCurtain.decision(pageReady: false, sinceLaunch: 1.2, opensElsewhere: false) == nil)
        #expect(LaunchCurtain.decision(pageReady: false, sinceLaunch: nil, opensElsewhere: false) == nil)
    }

    private func shell() -> (UIWindow, UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        return (window, root)
    }

    private func settle(looks: Int = 200, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The curtain covers the shell — which keeps rendering under it, never
    /// hidden — until the page's signal; a committed frame later it lifts, and
    /// once faded it is gone from the window.
    @Test func theCurtainLiftsOnTheSignalAndIsRemovedAfterTheFade() async {
        let (window, root) = shell()
        defer { window.isHidden = true }
        let milestone = "test.curtain.\(UUID().uuidString)"
        let curtain = LaunchCurtain(curtain: UIView(), owner: NSObject(), readyMilestone: milestone)

        curtain.hold(over: window, opensElsewhere: false)
        #expect(curtain.isUp && curtain.curtainIsShown)
        #expect(!root.view.isHidden && root.view.alpha == 1, "the shell was hidden while it waits")

        LaunchTimeline.mark(milestone)
        #expect(await settle { !curtain.isUp }, "the signal never lifted the curtain")
        #expect(curtain.revealed == .ready)
        #expect(await settle { !curtain.curtainIsShown }, "the curtain stayed in the window after its fade")
    }

    /// A launch that opens somewhere else does not wait for Shots.
    @Test func aLaunchElsewhereLiftsAtOnce() {
        let (window, _) = shell()
        defer { window.isHidden = true }
        let curtain = LaunchCurtain(curtain: UIView(), owner: NSObject(), readyMilestone: "test.never")

        curtain.hold(over: window, opensElsewhere: true)

        #expect(!curtain.isUp)
        #expect(curtain.revealed == .route)
    }

    /// Sound waits for the lift: the flag is up while the curtain is, and
    /// down from the moment the fade begins.
    @Test func soundWaitsForTheLift() {
        let (window, _) = shell()
        defer { window.isHidden = true }
        let curtain = LaunchCurtain(curtain: UIView(), owner: NSObject(), readyMilestone: "test.never.2")

        curtain.hold(over: window, opensElsewhere: false)
        #expect(LaunchTimeline.curtainIsUp)
        curtain.lift(.capped)
        #expect(!LaunchTimeline.curtainIsUp)
        #expect(curtain.revealed == .capped)
    }
}
