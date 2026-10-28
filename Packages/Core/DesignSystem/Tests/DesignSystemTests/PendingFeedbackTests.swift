import Testing
import UIKit
@testable import DesignSystem

/// A menu action under way (#1775): its loading toast past the loader's
/// grace, the answer in its place — and a fast answer alone.
@MainActor
struct PendingFeedbackTests {
    private func hosting() -> (UIViewController, UIWindow) {
        let screen = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.isHidden = false
        return (screen, window)
    }

    @Test func aFastAnswerShowsAlone() {
        let (screen, window) = hosting()
        defer { window.isHidden = true }
        let time = ManualLoadingClock()
        let pending = PendingFeedback("Blocking @ava…", from: screen, clock: time.clock)

        time.advance(LoadingTiming.loaderGrace / 2)
        let answer = pending.succeed("Blocked @ava")
        #expect(answer?.content.key == pending.id)
        time.advance(LoadingTiming.loaderGrace)
        #expect(!pending.isShowingLoading, "a spinner after the answer")
    }

    @Test func aSlowAnswerTakesTheLoadingToastsPlace() {
        let (screen, window) = hosting()
        defer { window.isHidden = true }
        let time = ManualLoadingClock()
        let pending = PendingFeedback("Sending report…", from: screen, clock: time.clock)
        #expect(!pending.isShowingLoading, "a spinner before the grace")

        time.advance(LoadingTiming.loaderGrace)
        #expect(pending.isShowingLoading, "nothing said while the action was out")
        let answer = pending.fail("Couldn't send this report")
        #expect(answer?.content.key == pending.id, "the answer did not take the loading toast's place")
        #expect(!pending.isShowingLoading)
        #expect(pending.succeed("Report sent") == nil, "a second answer")
    }

    /// The screen gone: nothing said, and no loading toast left behind.
    @Test func aScreenGoneSaysNothing() {
        let time = ManualLoadingClock()
        var screen: UIViewController? = UIViewController()
        let pending = PendingFeedback("Following @ava…", from: screen!, clock: time.clock)
        screen = nil
        time.advance(LoadingTiming.loaderGrace)
        #expect(!pending.isShowingLoading)
        #expect(pending.succeed("Following @ava") == nil)
    }
}
