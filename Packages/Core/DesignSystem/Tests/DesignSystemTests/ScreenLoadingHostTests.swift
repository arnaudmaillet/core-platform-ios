import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// A screen's three layers on the kit's timing (#1768): nothing for the
/// delay, the skeleton held its minimum, the content or the status after it,
/// and "taking longer" with a retry that starts the wait again.
@MainActor
struct ScreenLoadingHostTests {
    private typealias ManualClock = SkeletonGateTests.ManualClock

    @MainActor
    private struct Screen {
        let container = UIView()
        let skeleton = UIView()
        let content = UIView()
        let status = UIView()

        var visible: ScreenLoadingHost.Layer? {
            let shown = [(skeleton, ScreenLoadingHost.Layer.skeleton), (content, .content), (status, .status)]
                .filter { !$0.0.isHidden }
            return shown.count == 1 ? shown[0].1 : nil
        }
    }

    private func host(_ screen: Screen, _ time: ManualClock) -> ScreenLoadingHost {
        ScreenLoadingHost(
            container: screen.container, skeleton: screen.skeleton,
            content: screen.content, status: screen.status, clock: time.clock
        )
    }

    @Test func nothingBeforeTheDelayThenTheSkeleton() {
        let time = ManualClock()
        let screen = Screen()
        let host = host(screen, time)
        host.load()
        #expect(screen.visible == nil)
        #expect(host.shown == nil)
        time.advance(LoadingTiming.skeletonDelay)
        #expect(screen.visible == .skeleton)
    }

    @Test func aFastLoadNeverShowsTheSkeleton() {
        let time = ManualClock()
        let screen = Screen()
        let host = host(screen, time)
        host.load()
        time.advance(0.05)
        host.showContent()
        #expect(screen.visible == .content)
        time.advance(1)
        #expect(screen.visible == .content)
    }

    @Test func theSkeletonStaysItsMinimum() {
        let time = ManualClock()
        let screen = Screen()
        let host = host(screen, time)
        host.load()
        time.advance(LoadingTiming.skeletonDelay)
        host.showContent()
        #expect(screen.visible == .skeleton, "the skeleton left before its minimum")
        time.advance(LoadingTiming.minimum)
        #expect(screen.visible == .content)
    }

    @Test func takingLongerThenRetry() {
        let time = ManualClock()
        let screen = Screen()
        let host = host(screen, time)
        var warned = 0
        host.onTakingLonger = { [weak host] in
            warned += 1
            host?.showStatus()
        }
        host.load()
        // Two steps: the manual clock stamps a step's work at its end.
        time.advance(LoadingTiming.skeletonDelay)
        time.advance(LoadingTiming.takingLonger - LoadingTiming.skeletonDelay)
        #expect(warned == 1)
        #expect(screen.visible == .status)

        // Try Again: the wait starts over, the status goes at once.
        host.load()
        #expect(screen.visible == nil)
        time.advance(LoadingTiming.skeletonDelay)
        #expect(screen.visible == .skeleton)
        host.showContent()
        time.advance(LoadingTiming.minimum)
        #expect(screen.visible == .content)
        time.advance(LoadingTiming.takingLonger)
        #expect(warned == 1, "a second warning for a load that answered")
    }

    @Test func aRefreshKeepsTheContent() {
        let time = ManualClock()
        let screen = Screen()
        let host = host(screen, time)
        host.showContent()
        host.load()
        time.advance(1)
        #expect(screen.visible == .content)
    }
}
