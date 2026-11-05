import DesignSystem
import Testing
import UIKit
@testable import CoreNavigation

/// On a native push, a vertical close is a PULL (#2045, #2046): no pop at
/// the drag's begin; a release past the threshold of visible lift pops
/// through the chevron's path; short of it, or a flick short of it, nothing
/// closes. A window or a flight keeps its grab.
///
/// ⚠️ `.serialized`: each test pumps the shared main run loop.
@Suite(.serialized)
@MainActor
struct PullToCloseTests {
    /// A page that lifts by exactly the finger's travel, and remembers.
    final class Page: UIViewController, VerticalPullClosing {
        var travels: [CGFloat] = []
        var ends: [Bool] = []
        func pullToClose(travel: CGFloat, along axis: ZoomDismissAxis) -> CGFloat {
            travels.append(travel)
            return travel
        }
        func endPullToClose(commit: Bool) { ends.append(commit) }
    }

    func stack() -> (UIWindow, UINavigationController, Page, InteractiveSlideDismissal) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        let feed = Page()
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.setViewControllers([root, feed], animated: false)
        window.layoutIfNeeded()
        let slide = InteractiveSlideDismissal()
        slide.attach(to: feed, axes: [.horizontal, .vertical])
        slide.install(on: nav)
        slide.closesByPull = true
        return (window, nav, feed, slide)
    }

    @Test(arguments: [ZoomDismissAxis.upward, .vertical])
    func aPullPastTheThresholdPopsThroughTheChevronsPath(_ axis: ZoomDismissAxis) async {
        let (window, nav, feed, slide) = stack()
        defer { window.isHidden = true }
        var hooks: [ZoomDismissAxis] = []
        slide.onWillBeginPop = { hooks.append($0) }
        let threshold = HeroPullToRefreshView.threshold
        let pulled = slide.debugPerformPull(travel: threshold + 1, axis: axis) {
            #expect(nav.transitionCoordinator == nil, "a pop started at the drag's begin")
            #expect(hooks.isEmpty, "the landing was staged before the release")
        }
        #expect(pulled)
        #expect(feed.ends == [true])
        #expect(hooks == [axis], "the landing is staged at the committed release")
        #expect(nav.transitionCoordinator?.isInteractive == false || nav.topViewController !== feed,
                "no pop followed the release")
    }

    @Test(arguments: [ZoomDismissAxis.upward, .vertical])
    func aPullShortOfTheThresholdStays(_ axis: ZoomDismissAxis) {
        let (window, nav, feed, slide) = stack()
        defer { window.isHidden = true }
        var hooks = 0
        slide.onWillBeginPop = { _ in hooks += 1 }
        #expect(slide.debugPerformPull(travel: HeroPullToRefreshView.threshold - 1, axis: axis))
        #expect(feed.ends == [false])
        #expect(hooks == 0, "a pull let go short staged a landing")
        #expect(nav.topViewController === feed)
        #expect(nav.transitionCoordinator == nil)
    }

    /// The release takes distance only: a drag the system cancels never
    /// closes, whatever it reached.
    @Test func aCancelledPullStays() {
        let (window, nav, feed, slide) = stack()
        defer { window.isHidden = true }
        #expect(slide.debugPerformPull(travel: 400, axis: .upward, ended: false))
        #expect(feed.ends == [false])
        #expect(nav.topViewController === feed)
    }

    /// The threshold is the app's pull distance, at ±1 pt.
    @Test func theThresholdIsThePullToRefreshs() {
        let threshold = HeroPullToRefreshView.threshold
        #expect(InteractiveSlideDismissal.pullCommits(lift: threshold))
        #expect(!InteractiveSlideDismissal.pullCommits(lift: threshold - 1))
        #expect(InteractiveSlideDismissal.pullCommits(lift: threshold + 1))
    }

    /// A window or a flight — `closesByPull` off — keeps its grab: no pull.
    /// The rightward swipe is never a pull either.
    @Test func onlyANativePushsVerticalClosesArePulls() {
        let (window, _, feed, slide) = stack()
        defer { window.isHidden = true }
        #expect(!slide.debugPerformPull(travel: 300, axis: .horizontal))
        slide.closesByPull = false
        #expect(!slide.debugPerformPull(travel: 300, axis: .upward))
        #expect(feed.travels.isEmpty)
        slide.closesByPull = true
        slide.resetForNewPresentation()
        #expect(!slide.closesByPull, "the next opening inherited this one's push")
    }
}
