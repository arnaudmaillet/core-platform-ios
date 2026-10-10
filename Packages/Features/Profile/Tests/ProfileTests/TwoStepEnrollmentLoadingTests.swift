import Foundation
import Testing
import UIKit
@testable import Profile

/// Two-step setup pushes at once and loads its secret itself (#800): the
/// setup screen arrives on its loading state while `StartMfaEnrollment` is
/// still out, shows the secret when it answers, and keeps a failure inside
/// it with Try Again.
///
/// Every answer is handed over by the test (`GatedTwoStep`), so "still
/// loading" is a state the test holds open, not a race it hopes to win.
@MainActor
@Suite(.timeLimit(.minutes(10)))
struct TwoStepEnrollmentLoadingTests {
    /// A two-step backend whose start waits until the test answers it.
    private actor GatedTwoStep: TwoStepManaging {
        private(set) var startCalls = 0
        private var pending: [CheckedContinuation<TwoStepEnrollment, Error>] = []

        var waiting: Int { pending.count }

        func startTwoStepEnrollment() async throws -> TwoStepEnrollment {
            startCalls += 1
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }

        /// Answers the oldest start still out.
        func answer(_ result: Result<TwoStepEnrollment, Error>) {
            pending.removeFirst().resume(with: result)
        }

        func confirmTwoStepEnrollment(code: String) async throws -> BackupCodes { throw TwoStepError.wrongCode }
        func disableTwoStep() async throws {}
        func regenerateBackupCodes() async throws -> BackupCodes { BackupCodes(codes: [], sessionsSignedOut: 0) }
    }

    private struct NoAccount: AccountProviding {
        func currentAccount() async throws -> AccountDetails { throw TwoStepError.transport(message: "offline") }
    }

    private struct NoStepUp: CredentialStepUp {
        func stepUp(password: String) async throws {}
        func stepUp(code: String) async throws {}
    }

    private static let enrollment = TwoStepEnrollment(
        secret: "JBSWY3DPEHPK3PXP", otpauthURI: "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP", expiresIn: 600
    )

    /// Yields and looks again (main actor).
    ///
    /// ⚠️ LOOKS, NOT A WALL-CLOCK DEADLINE: a frozen CI process costs no
    /// budget, and the waits that matter are `#require`d.
    @discardableResult
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test func theSetupStartsLoadingAndShowsTheSecretWhenTheStartAnswers() async throws {
        let gate = GatedTwoStep()
        let model = TwoStepEnrollmentModel(manager: gate)
        #expect(model.state == .loading)

        model.start()
        try #require(await settle { await gate.waiting == 1 })
        #expect(model.state == .loading)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { model.state != .loading })
        #expect(model.state == .ready(Self.enrollment))
    }

    @Test func aStartThatThrowsShowsTheFailureAndTryAgainStartsOver() async throws {
        let gate = GatedTwoStep()
        let model = TwoStepEnrollmentModel(manager: gate)
        var failures: [Error] = []
        model.onFailure = { failures.append($0) }

        model.start()
        try #require(await settle { await gate.waiting == 1 })
        await gate.answer(.failure(TwoStepError.transport(message: "offline")))
        try #require(await settle { model.state != .loading })
        #expect(model.state == .failed(message: TwoStepViewController.failureMessage(TwoStepError.transport(message: "offline"))))
        #expect(failures.count == 1)

        model.start()
        #expect(model.state == .loading)
        try #require(await settle { await gate.waiting == 1 })
        #expect(await gate.startCalls == 2)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { model.state != .loading })
        #expect(model.state == .ready(Self.enrollment))
    }

    /// Each start mints a new secret: a second start while one is out, or
    /// once the secret is here, would put a stale QR code on screen.
    @Test func oneStartAtATimeAndNoneOnceTheSecretIsHere() async throws {
        let gate = GatedTwoStep()
        let model = TwoStepEnrollmentModel(manager: gate)

        model.start()
        model.start()
        try #require(await settle { await gate.waiting == 1 })
        await gate.answer(.success(Self.enrollment))
        try #require(await settle { model.state != .loading })

        model.start()
        await Task.yield()
        #expect(await gate.startCalls == 1)
        #expect(model.state == .ready(Self.enrollment))
    }

    /// The screen draws the model: bones while loading, the failed state
    /// (with Try Again) instead of the content when the start throws, and
    /// loading again on retry.
    @Test func theScreenShowsLoadingThenTheFailureThenLoadingOnRetry() async throws {
        let gate = GatedTwoStep()
        var startFailures: [Error] = []
        let setup = TwoStepEnrollmentViewController(manager: gate, onEnabled: { _ in }, onStartFailed: { startFailures.append($0) })

        setup.loadViewIfNeeded()
        try #require(await settle { await gate.waiting == 1 })
        #expect(setup.model.state == .loading)
        #expect(!setup.scroll.isHidden)
        #expect(setup.failureView.isHidden)

        await gate.answer(.failure(TwoStepError.alreadyChanged))
        try #require(await settle { !setup.failureView.isHidden })
        #expect(setup.scroll.isHidden)
        #expect(startFailures.map { $0 as? TwoStepError } == [.alreadyChanged])

        setup.retry()
        #expect(setup.failureView.isHidden)
        #expect(!setup.scroll.isHidden)
        try #require(await settle { await gate.waiting == 1 })
        #expect(await gate.startCalls == 2)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { setup.model.state == .ready(Self.enrollment) })
        #expect(setup.failureView.isHidden)
    }

    /// ⚠️ The push is the point (#800): it happens while the start is still
    /// out — held open by the gate — and a second tap doesn't push again.
    @Test func settingUpPushesBeforeTheSecretArrivesAndOnlyOnce() async throws {
        let gate = GatedTwoStep()
        let screen = TwoStepViewController(account: NoAccount(), manager: gate, stepUp: NoStepUp())
        let navigation = UINavigationController(rootViewController: screen)

        screen.startEnrollment()
        screen.startEnrollment()
        #expect(navigation.viewControllers.count == 2)
        let setup = try #require(navigation.viewControllers.last as? TwoStepEnrollmentViewController)
        #expect(setup.model.state == .loading)

        setup.loadViewIfNeeded()
        try #require(await settle { await gate.waiting == 1 })
        #expect(await gate.startCalls == 1)
        #expect(navigation.viewControllers.last === setup)
        #expect(setup.model.state == .loading)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { setup.model.state == .ready(Self.enrollment) })
    }
}
