import CoreGraphics
import Testing
import UIKit
@testable import DesignSystem

/// THE PULL TO REFRESH'S ONE RULE (#2235). The profile and For You fired
/// sooner than Messages (the owner, 2026-11-10): two mechanisms, two
/// distances, and a ring and a tick that matched neither. One distance now —
/// the ring full, the tick and the trigger — read the same way on every
/// screen, under a finger only, and both indicators take that one decision.
@MainActor
struct PullRefreshRuleTests {
    private let threshold = PullRefreshRule.threshold

    // MARK: - The shared decision

    @Test func aFingersPullRefreshesAtTheThresholdAndNotBefore() {
        func decide(_ pulled: CGFloat) -> Bool {
            PullRefreshRule.shouldRefresh(
                pulled: pulled, isTracking: true, isRefreshing: false, wasShortUnderFinger: true
            )
        }
        #expect(!decide(threshold - 1), "a pull short of the threshold refreshed")
        #expect(decide(threshold), "a pull at the threshold did not refresh")
        #expect(decide(threshold + 40), "a pull past the threshold did not refresh")
    }

    @Test func withoutAFingerNothingRefreshes() {
        #expect(!PullRefreshRule.shouldRefresh(
            pulled: threshold + 40, isTracking: false, isRefreshing: false, wasShortUnderFinger: true
        ), "a fling or a bounce past the threshold refreshed")
    }

    @Test func aCaughtBounceAlreadyPastTheThresholdDoesNotRefresh() {
        #expect(!PullRefreshRule.shouldRefresh(
            pulled: threshold + 40, isTracking: true, isRefreshing: false, wasShortUnderFinger: false
        ))
    }

    @Test func oneRefreshAtATime() {
        #expect(!PullRefreshRule.shouldRefresh(
            pulled: threshold + 40, isTracking: true, isRefreshing: true, wasShortUnderFinger: true
        ))
    }

    /// The measure is the overscroll past the list's top, whatever its inset.
    @Test func theMeasureIgnoresTheInsets() {
        #expect(PullRefreshRule.pulled(contentOffsetY: -threshold, topInset: 0) == threshold)
        #expect(PullRefreshRule.pulled(contentOffsetY: -200 - threshold, topInset: 200) == threshold)
        #expect(PullRefreshRule.pulled(contentOffsetY: 300, topInset: 200) == -500)
    }

    // MARK: - The ring, the tick and the trigger: one distance

    @Test func theRingIsFullExactlyWhereTheRefreshFires() {
        #expect(PullRefreshRule.progress(pulled: threshold - 1) < 1)
        #expect(PullRefreshRule.progress(pulled: threshold) == 1)
        #expect(PullRefreshRule.progress(pulled: threshold * 2) == 1)
        #expect(PullRefreshRule.progress(pulled: -10) == 0)

        // Read a finger's pull point by point: the trigger fires, and the
        // tick sounds, on the reading the ring turns full — the same one.
        let trigger = PullRefreshTrigger()
        var firedAt: CGFloat?
        var tickedAt: CGFloat?
        for pulled in stride(from: CGFloat(0), through: threshold + 30, by: 1) {
            let wasArmed = trigger.feedback.isArmed
            let fires = trigger.update(pulled: pulled, isTracking: true, isRefreshing: firedAt != nil)
            if fires, firedAt == nil { firedAt = pulled }
            if !wasArmed, trigger.feedback.isArmed, tickedAt == nil { tickedAt = pulled }
        }
        let fullAt = stride(from: CGFloat(0), through: threshold + 30, by: 1)
            .first { PullRefreshRule.progress(pulled: $0) >= 1 }
        #expect(firedAt == threshold)
        #expect(tickedAt == firedAt, "the tick and the trigger came apart")
        #expect(fullAt == firedAt, "the ring and the trigger came apart")
    }

    @Test func theTriggerFiresOncePerPull() {
        let trigger = PullRefreshTrigger()
        #expect(!trigger.update(pulled: 20, isTracking: true, isRefreshing: false))
        #expect(trigger.update(pulled: threshold, isTracking: true, isRefreshing: false))
        // Held past it, the refresh done: no second refresh without the pull
        // going short again.
        #expect(!trigger.update(pulled: threshold + 20, isTracking: true, isRefreshing: false))
        #expect(!trigger.update(pulled: threshold - 10, isTracking: true, isRefreshing: false))
        #expect(
            trigger.update(pulled: threshold + 1, isTracking: true, isRefreshing: false), "a second pull did not fire"
        )
    }

    @Test func aPullLetGoShortNeverFires() {
        let trigger = PullRefreshTrigger()
        #expect(!trigger.update(pulled: threshold - 20, isTracking: true, isRefreshing: false))
        // Let go: the list's own travel afterwards is not a pull.
        #expect(!trigger.update(pulled: threshold + 10, isTracking: false, isRefreshing: false))
        #expect(!trigger.feedback.isArmed, "a drift past the threshold ticked")
    }

    /// A fling into the top bounces past the threshold with no finger; a
    /// finger catching it there did not pull it so far.
    @Test func aBounceNeverFiresNorTicks() {
        let trigger = PullRefreshTrigger()
        for pulled in stride(from: CGFloat(0), through: threshold + 50, by: 10) {
            #expect(!trigger.update(pulled: pulled, isTracking: false, isRefreshing: false))
        }
        // Caught past the threshold, and pulled on.
        #expect(!trigger.update(pulled: threshold + 50, isTracking: true, isRefreshing: false), "a caught bounce fired")
        #expect(!trigger.update(pulled: threshold + 60, isTracking: true, isRefreshing: false))
        #expect(!trigger.feedback.isArmed, "a caught bounce ticked")
    }

    // MARK: - Both mechanisms take the shared decision

    @Test func theHeroIndicatorFiresUnderTheFingerAtTheThreshold() {
        let indicator = HeroPullToRefreshView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        indicator.minimumShown = 0
        var refreshes = 0
        indicator.onRefresh = { refreshes += 1 }

        indicator.setPull(threshold - 1, isTracking: true)
        #expect(refreshes == 0 && !indicator.debugIsRefreshing, "short of the threshold, it refreshed")
        indicator.setPull(threshold, isTracking: true)
        #expect(refreshes == 1 && indicator.debugIsRefreshing, "at the threshold, under a finger, it did not refresh")
        #expect(indicator.debugThresholdFeedback.isArmed, "it refreshed without the tick")
        indicator.setPull(threshold + 30, isTracking: true)
        #expect(refreshes == 1)
        indicator.endRefreshing()

        // A bounce past it with no finger: nothing.
        indicator.setPull(0)
        indicator.setPull(threshold + 30)
        #expect(refreshes == 1 && !indicator.debugIsRefreshing, "a bounce refreshed")
    }

    @Test func theRefreshControlFiresUnderTheFingerAtTheThreshold() {
        let (window, _, control) = installedControl()
        defer { window.isHidden = true }
        var refreshes = 0
        control.onRefresh = { refreshes += 1 }

        control.debugFollow(pulled: 0, isTracking: true)
        control.debugFollow(pulled: threshold - 1, isTracking: true)
        #expect(refreshes == 0 && !control.isRefreshing, "short of the threshold, it refreshed")
        control.debugFollow(pulled: threshold, isTracking: true)
        #expect(refreshes == 1, "at the threshold, under a finger, it did not refresh")
        #expect(control.isRefreshing, "the rule fired without UIKit's refreshing state (its hold)")
        #expect(control.debugThresholdFeedback.isArmed, "it refreshed without the tick")
        control.endRefreshing()
    }

    @Test func theRefreshControlNeverFiresOnABounce() {
        let (window, list, control) = installedControl()
        defer { window.isHidden = true }
        var refreshes = 0
        control.onRefresh = { refreshes += 1 }
        let top = list.adjustedContentInset.top
        for distance in stride(from: CGFloat(0), through: threshold + 40, by: 10) {
            list.contentOffset.y = -top - distance
            control.debugFollow(list, isTracking: false)
        }
        #expect(refreshes == 0 && !control.isRefreshing, "a fling's bounce refreshed")
    }

    /// The threshold is read past the list's top, so a hosted list's inset —
    /// For You under its header — cannot move it. (The list read is not the
    /// one the control observes: setting an observed offset reads it again,
    /// with no finger.)
    @Test func theRefreshControlsDistanceIgnoresTheListsInset() {
        let (window, _, control) = installedControl()
        defer { window.isHidden = true }
        var refreshes = 0
        control.onRefresh = { refreshes += 1 }
        let hosted = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        hosted.contentInsetAdjustmentBehavior = .never
        hosted.contentInset.top = 180
        hosted.contentSize = CGSize(width: 390, height: 2000)

        hosted.contentOffset.y = -180
        control.debugFollow(hosted, isTracking: true)
        hosted.contentOffset.y = -180 - (threshold - 1)
        control.debugFollow(hosted, isTracking: true)
        #expect(refreshes == 0, "the inset counted as pull")
        hosted.contentOffset.y = -180 - threshold
        control.debugFollow(hosted, isTracking: true)
        #expect(refreshes == 1)
        control.endRefreshing()
    }

    /// UIKit's own trigger, at UIKit's distance, is held: the host is told
    /// only once the finger's pull reaches the app's threshold, and a finger
    /// letting go short ends UIKit's refresh at once.
    @Test func uikitsOwnTriggerWaitsForTheRule() {
        let (window, _, control) = installedControl()
        defer { window.isHidden = true }
        var refreshes = 0
        control.onRefresh = { refreshes += 1 }

        control.debugFollow(pulled: 20, isTracking: true)
        control.debugNativeTrigger()
        #expect(control.debugIsNativeRefreshPending)
        #expect(refreshes == 0, "UIKit's distance refreshed")
        control.debugFollow(pulled: threshold, isTracking: true)
        #expect(refreshes == 1, "the pull reached the threshold and did not refresh")
        #expect(!control.debugIsNativeRefreshPending)
        control.endRefreshing()
        #expect(!control.isRefreshing)

        // Again, let go short this time.
        control.debugFollow(pulled: 0, isTracking: false)
        control.debugFollow(pulled: 20, isTracking: true)
        control.debugNativeTrigger()
        let endsBefore = control.debugEndsPassedToUIKit
        control.debugFollow(pulled: 60, isTracking: false)
        #expect(refreshes == 1, "a pull let go short refreshed")
        #expect(!control.isRefreshing, "UIKit's refresh outlived the short pull")
        #expect(!control.debugIsNativeRefreshPending)
        #expect(control.debugEndsPassedToUIKit == endsBefore + 1)
    }

    /// A programmatic refresh — a host showing a load it started — is not a
    /// pull: no `onRefresh`.
    @Test func aProgrammaticRefreshIsNotAPull() {
        let (window, _, control) = installedControl()
        defer { window.isHidden = true }
        var refreshes = 0
        control.onRefresh = { refreshes += 1 }
        control.beginRefreshing()
        #expect(control.isRefreshing && refreshes == 0)
        control.endRefreshing()
    }

    // MARK: - Helpers

    private func installedControl() -> (UIWindow, UIScrollView, AppRefreshControl) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let list = UIScrollView(frame: window.bounds)
        list.contentSize = CGSize(width: 390, height: 2000)
        window.addSubview(list)
        let control = AppRefreshControl()
        control.minimumShown = 0
        control.debugLoader.reducesMotion = { false }
        list.refreshControl = control
        window.isHidden = false
        return (window, list, control)
    }
}
