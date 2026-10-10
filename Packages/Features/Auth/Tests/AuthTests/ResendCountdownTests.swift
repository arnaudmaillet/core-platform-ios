import Foundation
import Testing
import UIKit
@testable import Auth

/// The code step's resend countdown ends with its screen (#784).
///
/// ⚠️ **ITS ONLY `invalidate()` WAS IN THE ROW'S UPDATE.** The 1 s timer holds
/// its screen weakly, so backing out mid-countdown released the screen and
/// left the timer repeating on the main run loop for the rest of the session,
/// with nothing left to stop it. It now stops when the step disappears, runs
/// again if the step comes back, and invalidates itself on its first tick
/// without an owner.
@MainActor
struct ResendCountdownTests {
    @Test func theResendTimerStopsItselfOnceItsStepIsReleased() async throws {
        weak var released: VerificationCodeViewController?
        // Built and dropped inside a pool, so nothing autoreleased keeps the
        // step alive past the block.
        let timer: Timer? = autoreleasepool {
            let step = VerificationCodeViewController(destination: "ada@example.com", resendAfter: 60)
            step.loadViewIfNeeded()
            released = step
            return step.resendTimer
        }
        let countdown = try #require(timer, "guard: loading the step started no countdown")
        try #require(released == nil, "guard: something still holds the step, so it was never released")
        try #require(countdown.isValid, "guard: the countdown ended before its first tick")

        // The timer ticks every second on the main run loop; this gives it
        // turns until it has stopped, and gives up after about 10 s of them.
        let stopped = await settle { !countdown.isValid }
        #expect(stopped, "the resend timer kept ticking after its step was released")
    }

    /// Popped, or covered by the next step: either way the step disappears
    /// while something may still hold it.
    @Test func theResendTimerStopsWhenItsStepDisappears() throws {
        let step = VerificationCodeViewController(destination: "ada@example.com", resendAfter: 60)
        step.loadViewIfNeeded()
        appear(step)
        let countdown = try #require(step.resendTimer, "guard: the step shows no countdown")
        try #require(countdown.isValid, "guard: the countdown ended before the step left")

        disappear(step)

        #expect(!countdown.isValid, "the resend timer kept ticking after its step disappeared")
    }

    /// The next step popped: the countdown runs again, from the time left.
    @Test func aStepThatComesBackCountsDownAgain() throws {
        let step = VerificationCodeViewController(destination: "ada@example.com", resendAfter: 60)
        step.loadViewIfNeeded()
        appear(step)
        let first = try #require(step.resendTimer, "guard: the step shows no countdown")
        disappear(step)
        try #require(!first.isValid, "guard: the countdown did not stop when the step left")

        appear(step)

        let resumed = try #require(step.resendTimer, "the countdown did not come back with its step")
        #expect(resumed.isValid, "the countdown came back stopped")
        disappear(step)
    }

    /// The appearance callbacks a navigation stack sends, without a window.
    private func appear(_ step: UIViewController) {
        step.beginAppearanceTransition(true, animated: false)
        step.endAppearanceTransition()
    }

    private func disappear(_ step: UIViewController) {
        step.beginAppearanceTransition(false, animated: false)
        step.endAppearanceTransition()
    }
}
