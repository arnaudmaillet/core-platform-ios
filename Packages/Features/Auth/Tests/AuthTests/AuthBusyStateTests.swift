import CoreModels
import Testing
import UIKit
@testable import Auth

private struct NoLogin: LoginPerforming {
    func login(username: String, password: String) async throws -> LoginOutcome { .signedIn }
    func completeLogin(_ challenge: SecondStepChallenge, code: String) async throws {}
}

private struct Refused: Error {}

/// A session whose code and nonce requests wait at a gate the test opens, so
/// a test can tap again while one is out. Counts what reached it.
private actor GatedSignUp: SignUpPerforming {
    private(set) var verifications = 0
    private(set) var nonces = 0
    private(set) var signedInAccount: PendingAccount?
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    /// Requests held at the gate right now.
    var held: Int { waiting.count }

    /// Lets every held request through: answered, or refused when `failing`.
    func open(failing: Bool = false) {
        waiting.forEach { $0.resume(returning: failing) }
        waiting = []
    }

    private func gate() async throws {
        let fails = await withCheckedContinuation { waiting.append($0) }
        if fails { throw Refused() }
    }

    func startVerification(_ channel: VerificationChannel, to destination: String, locale: String) async throws -> VerificationChallenge {
        verifications += 1
        try await gate()
        return VerificationChallenge(id: "ch-\(verifications)", channel: channel, destination: destination, expiresIn: 600, resendAfter: 30)
    }

    func startFederatedSignIn() async throws -> String {
        nonces += 1
        try await gate()
        return "nonce-\(nonces)"
    }

    func signIn(_ credential: SignInCredential) async throws -> CodeSignIn { .existing(account) }
    func signUp(_ credential: SignInCredential, details: SignUpDetails) async throws -> SignUpOutcome { .created(account) }
    func completeSignIn(_ account: PendingAccount) async { signedInAccount = account }
    func completeSecondStep(_ challenge: SecondStepChallenge, code: String) async throws -> PendingAccount { account }
    func completeSignUp(_ pending: PendingAccount) async throws {}

    private let account: PendingAccount = {
        let session = AuthSession(
            accountID: AccountID("acct-busy"), sessionID: SessionID("sess-busy"),
            accessToken: "at", accessTokenExpiry: .distantFuture, refreshToken: "rt"
        )
        return PendingAccount(accountID: session.accountID, accessToken: session.accessToken, session: session)
    }()
}

@MainActor
private final class InstantApple: FederatedSignInProviding {
    func signIn(with provider: FederatedProvider, nonce: String) async throws -> FederatedSignInResult {
        FederatedSignInResult(idToken: "apple-token", displayName: nil)
    }
}

/// #827: a sign-in call is out at most once, and the control that started it
/// says so until it ends — success or failure.
@MainActor
struct AuthBusyStateTests {
    private func start(_ signUp: GatedSignUp, picking method: SignInMethod) throws -> UINavigationController {
        let flow = LoginFlowCoordinator(
            loginService: NoLogin(), signUp: signUp, federated: InstantApple(), homeCountry: { "FR" }
        ).start()
        let navigation = try #require(flow as? UINavigationController)
        let methods = try #require(navigation.viewControllers.first as? MethodSelectionViewController)
        methods.onMethodSelected?(method)
        return navigation
    }

    /// Gives a second, wrongly sent request every chance to reach the gate
    /// before the count is read. A miss would be a false pass, never a flake.
    private func letStrayCallsLand() async {
        await settle(looks: 40) { false }
    }

    // MARK: Sending the code from the phone screen

    @Test func aSecondContinueWhileTheSMSIsOutSendsNothingMore() async throws {
        let signUp = GatedSignUp()
        let navigation = try start(signUp, picking: .phone)
        let phone = try #require(navigation.topViewController as? PhoneAuthViewController)

        phone.onSendCode?("+33612345678", "+33 6 12 34 56 78")
        phone.onSendCode?("+33612345678", "+33 6 12 34 56 78")
        try #require(await settle { await signUp.held == 1 })
        await letStrayCallsLand()

        #expect(await signUp.verifications == 1)
        #expect(phone.isWorking, "Continue shows the code is being sent")

        await signUp.open()
        try #require(await settle { navigation.topViewController is VerificationCodeViewController })
        #expect(!phone.isWorking, "the busy state clears once the code is sent")
    }

    @Test func aRefusedSMSClearsTheBusyStateAndLetsTheNextTapSend() async throws {
        let signUp = GatedSignUp()
        let navigation = try start(signUp, picking: .phone)
        let phone = try #require(navigation.topViewController as? PhoneAuthViewController)

        phone.onSendCode?("+33612345678", "+33 6 12 34 56 78")
        try #require(await settle { await signUp.held == 1 })
        #expect(phone.isWorking)

        await signUp.open(failing: true)
        try #require(await settle { !phone.isWorking }, "the busy state never cleared after a failure")
        #expect(navigation.topViewController === phone)

        phone.onSendCode?("+33612345678", "+33 6 12 34 56 78")
        try #require(await settle { await signUp.held == 1 })
        #expect(await signUp.verifications == 2, "a failed send does not lock the button for good")
        await signUp.open()
    }

    // MARK: Resending

    /// The code step, reached by an email code the gate let through.
    private func codeStep(_ signUp: GatedSignUp) async throws -> VerificationCodeViewController {
        let navigation = try start(signUp, picking: .email)
        let email = try #require(navigation.topViewController as? EmailEntryViewController)
        email.onContinue?("nina@example.com")
        try #require(await settle { await signUp.held == 1 })
        await signUp.open()
        try #require(await settle { navigation.topViewController is VerificationCodeViewController })
        let code = try #require(navigation.topViewController as? VerificationCodeViewController)
        code.loadViewIfNeeded()
        return code
    }

    private func resendRowIsWorking(_ code: VerificationCodeViewController) -> Bool {
        code.trailingRows.first?.accessoryView is UIActivityIndicatorView
    }

    @Test func aSecondResendWhileOneIsOutSendsNothingMore() async throws {
        let signUp = GatedSignUp()
        let code = try await codeStep(signUp)

        code.onResend?()
        code.onResend?()
        try #require(await settle { await signUp.held == 1 })
        await letStrayCallsLand()

        #expect(await signUp.verifications == 2, "one first send, one resend")
        #expect(resendRowIsWorking(code), "the resend link shows the code is on its way")

        await signUp.open()
        try #require(await settle { !resendRowIsWorking(code) }, "the resend link never cleared")
    }

    @Test func aRefusedResendClearsTheLink() async throws {
        let signUp = GatedSignUp()
        let code = try await codeStep(signUp)

        code.onResend?()
        try #require(await settle { await signUp.held == 1 })
        #expect(resendRowIsWorking(code))

        await signUp.open(failing: true)
        try #require(await settle { !resendRowIsWorking(code) }, "the resend link never cleared after a failure")
        #expect(code.trailingRows.first?.isUserInteractionEnabled == true)
    }

    // MARK: Sign in with Apple

    @Test func aSecondAppleTapWhileOneIsOutAsksForNoSecondNonce() async throws {
        let signUp = GatedSignUp()
        let navigation = try start(signUp, picking: .provider(.apple))
        let methods = try #require(navigation.viewControllers.first as? MethodSelectionViewController)

        methods.onMethodSelected?(.provider(.apple))
        try #require(await settle { await signUp.held == 1 })
        await letStrayCallsLand()

        #expect(await signUp.nonces == 1)
        #expect(methods.workingMethod == .provider(.apple), "the Apple row shows the sign-in is running")

        await signUp.open()
        try #require(await settle { await signUp.signedInAccount != nil })
        try #require(await settle { methods.workingMethod == nil }, "the Apple row never cleared")
    }

    @Test func aRefusedAppleSignInClearsTheRowAndLetsTheNextTapTry() async throws {
        let signUp = GatedSignUp()
        let navigation = try start(signUp, picking: .provider(.apple))
        let methods = try #require(navigation.viewControllers.first as? MethodSelectionViewController)
        try #require(await settle { await signUp.held == 1 })
        #expect(methods.workingMethod == .provider(.apple))

        await signUp.open(failing: true)
        try #require(await settle { methods.workingMethod == nil }, "the Apple row never cleared after a failure")

        methods.onMethodSelected?(.provider(.apple))
        try #require(await settle { await signUp.held == 1 })
        #expect(await signUp.nonces == 2)
        await signUp.open()
    }
}
