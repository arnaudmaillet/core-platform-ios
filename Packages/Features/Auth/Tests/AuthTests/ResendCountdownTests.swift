import Foundation
import Testing
import UIKit
@testable import Auth

/// The code step's resend countdown ends with its screen (#784).
///
/// ⚠️ **ITS ONLY `invalidate()` WAS IN THE ROW'S UPDATE.** The 1 s timer holds
/// its screen weakly, so backing out mid-countdown released the screen and
/// left the timer repeating on the main run loop for the rest of the session,
/// with nothing left to stop it. It now invalidates itself on its first tick
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
}
