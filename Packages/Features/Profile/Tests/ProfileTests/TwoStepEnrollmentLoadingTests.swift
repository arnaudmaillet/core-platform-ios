import Foundation
import Testing
import UIKit
@testable import Profile

/// Two-step setup pushes at once and loads its secret itself (#800): the
/// setup screen arrives on its loading state while `StartMfaEnrollment` is
/// still out, shows the secret when it answers, and keeps a failure inside
/// it with the way out that can actually get past it.
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

    /// Counts the Two-Step screen's loads (each one fails: offline).
    private actor CountingAccount: AccountProviding {
        private(set) var loads = 0
        func currentAccount() async throws -> AccountDetails {
            loads += 1
            throw TwoStepError.transport(message: "offline")
        }
    }

    private struct NoStepUp: CredentialStepUp {
        func stepUp(password: String) async throws {}
        func stepUp(code: String) async throws {}
    }

    private static let enrollment = TwoStepEnrollment(
        secret: "JBSWY3DPEHPK3PXP", otpauthURI: "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP", expiresIn: 600
    )

    private func setupScreen(_ gate: GatedTwoStep, model: TwoStepEnrollmentModel? = nil) -> TwoStepEnrollmentViewController {
        TwoStepEnrollmentViewController(
            model: model ?? TwoStepEnrollmentModel(manager: gate), manager: gate, stepUp: NoStepUp(), onEnabled: { _ in }
        )
    }

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
        #expect(model.isStarting)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { model.state != .loading })
        #expect(model.state == .ready(Self.enrollment))
        #expect(!model.isStarting)
    }

    @Test func aStartThatThrowsShowsTheFailureAndTryAgainStartsOver() async throws {
        let gate = GatedTwoStep()
        let model = TwoStepEnrollmentModel(manager: gate)
        var failures: [Error] = []
        model.onFailure = { failures.append($0) }

        model.start()
        try #require(await settle { await gate.waiting == 1 })
        let offline = TwoStepError.transport(message: "offline")
        await gate.answer(.failure(offline))
        try #require(await settle { model.state != .loading })
        #expect(model.state == .failed(message: TwoStepViewController.failureMessage(offline), recovery: .retry))
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
    /// loading again on Try Again.
    @Test func theScreenShowsLoadingThenTheFailureThenLoadingOnTryAgain() async throws {
        let gate = GatedTwoStep()
        let setup = setupScreen(gate)

        setup.loadViewIfNeeded()
        try #require(await settle { await gate.waiting == 1 })
        #expect(setup.model.state == .loading)
        #expect(!setup.scroll.isHidden)
        #expect(setup.failureView.isHidden)

        await gate.answer(.failure(TwoStepError.transport(message: "offline")))
        try #require(await settle { !setup.failureView.isHidden })
        #expect(setup.scroll.isHidden)
        #expect(TwoStepEnrollmentViewController.actionTitle(for: .retry) == "Try Again")

        setup.recover()
        #expect(setup.failureView.isHidden)
        #expect(!setup.scroll.isHidden)
        try #require(await settle { await gate.waiting == 1 })
        #expect(await gate.startCalls == 2)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { setup.model.state == .ready(Self.enrollment) })
        #expect(setup.failureView.isHidden)
    }

    /// A stale step-up fails every start: Try Again asks for the password
    /// first, and only then starts.
    @Test func aStaleStepUpAsksForThePasswordBeforeStartingAgain() async throws {
        let gate = GatedTwoStep()
        let setup = setupScreen(gate)
        var prompts = 0
        setup.presentStepUp = { verified in
            prompts += 1
            verified()
        }

        setup.loadViewIfNeeded()
        try #require(await settle { await gate.waiting == 1 })
        await gate.answer(.failure(TwoStepError.stepUpRequired))
        try #require(await settle { setup.model.state != .loading })
        #expect(setup.model.state == .failed(
            message: TwoStepViewController.failureMessage(TwoStepError.stepUpRequired), recovery: .stepUp
        ))
        #expect(TwoStepEnrollmentViewController.actionTitle(for: .stepUp) == "Try Again")
        #expect(await gate.startCalls == 1)

        setup.recover()
        #expect(prompts == 1)
        try #require(await settle { await gate.waiting == 1 })
        #expect(await gate.startCalls == 2)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { setup.model.state == .ready(Self.enrollment) })
    }

    /// Two-step changed elsewhere: no start can work, so the way out is
    /// Back — to the Two-Step screen, which has reloaded underneath.
    @Test func twoStepChangedElsewhereGoesBackToAReloadedScreen() async throws {
        let gate = GatedTwoStep()
        let account = CountingAccount()
        let screen = TwoStepViewController(account: account, manager: gate, stepUp: NoStepUp())
        let navigation = UINavigationController(rootViewController: screen)

        screen.startEnrollment()
        let setup = try #require(navigation.viewControllers.last as? TwoStepEnrollmentViewController)
        setup.loadViewIfNeeded()
        try #require(await settle { await gate.waiting == 1 })
        // Never on screen: its own first load hasn't run, so any load is the
        // failure's.
        #expect(!screen.isViewLoaded)
        let loadsBefore = await account.loads
        #expect(loadsBefore == 0)

        await gate.answer(.failure(TwoStepError.alreadyChanged))
        try #require(await settle { setup.model.state != .loading })
        #expect(setup.model.state == .failed(
            message: TwoStepViewController.failureMessage(TwoStepError.alreadyChanged), recovery: .back
        ))
        #expect(TwoStepEnrollmentViewController.actionTitle(for: .back) == "Back")
        try #require(await settle { await account.loads > loadsBefore })

        setup.recover()
        #expect(navigation.viewControllers.count == 1)
        #expect(navigation.viewControllers.last === screen)
        #expect(await gate.startCalls == 1)
    }

    /// ⚠️ The push is the point (#800): it happens while the start is still
    /// out — held open by the gate — and a second tap doesn't push again.
    @Test func settingUpPushesBeforeTheSecretArrivesAndOnlyOnce() async throws {
        let gate = GatedTwoStep()
        let screen = TwoStepViewController(account: CountingAccount(), manager: gate, stepUp: NoStepUp())
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

    /// Back out while the start is out, then set up again: the new setup
    /// screen picks up the SAME pending start — no second secret — and shows
    /// its answer. Once that start has answered, the next setup starts clean.
    @Test func aRePushDuringAPendingStartReusesItInsteadOfMintingASecondSecret() async throws {
        let gate = GatedTwoStep()
        let screen = TwoStepViewController(account: CountingAccount(), manager: gate, stepUp: NoStepUp())

        let first = screen.enrollmentModelForPush()
        setupScreen(gate, model: first).loadViewIfNeeded()
        try #require(await settle { await gate.waiting == 1 })

        let second = screen.enrollmentModelForPush()
        #expect(second === first)
        let again = setupScreen(gate, model: second)
        again.loadViewIfNeeded()
        await Task.yield()
        #expect(await gate.startCalls == 1)
        #expect(again.model.state == .loading)

        await gate.answer(.success(Self.enrollment))
        try #require(await settle { again.model.state == .ready(Self.enrollment) })
        #expect(screen.enrollmentModelForPush() !== first)
    }
}
