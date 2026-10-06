import CoreModels
import Testing
import UIKit
@testable import Auth

private struct NoLogin: LoginPerforming {
    func login(username: String, password: String) async throws {}
}

@MainActor
struct LoginFlowCoordinatorTests {
    private func firstScreen(of flow: UIViewController) throws -> UIViewController {
        let navigation = try #require(flow as? UINavigationController)
        return try #require(navigation.viewControllers.first)
    }

    /// Presented over the app for a guest, the flow can be closed.
    @Test func presentedOverTheAppItCarriesAWorkingCloseButton() throws {
        var closed = false
        let flow = LoginFlowCoordinator(loginService: NoLogin()).start { closed = true }

        let close = try #require(try firstScreen(of: flow).navigationItem.leftBarButtonItem)
        close.primaryAction?.performWithSender(nil, target: nil)

        #expect(closed)
    }

    /// Installed without a way out, it offers none.
    @Test func withoutACloseHandlerItHasNoCloseButton() throws {
        let flow = LoginFlowCoordinator(loginService: NoLogin()).start()

        #expect(try firstScreen(of: flow).navigationItem.leftBarButtonItem == nil)
    }

    /// Opened by a gated action, the flow leads with the reason.
    @Test func aGatedActionsPromptIsTheHeadline() throws {
        let flow = LoginFlowCoordinator(loginService: NoLogin()).start(prompt: "Sign up to like this post") {}

        let methods = try #require(try firstScreen(of: flow) as? MethodSelectionViewController)
        #expect(methods.prompt == "Sign up to like this post")
    }
}

// MARK: - Codes and sign-up (guest mode B4, #449)

/// Scripted session: every code is good; whether it signs in or leads to
/// sign-up is the test's.
private actor FakeSignUp: SignUpPerforming {
    let signInAnswer: CodeSignIn
    let signUpAnswer: SignUpOutcome
    private(set) var sentTo: [String] = []
    private(set) var details: SignUpDetails?
    private(set) var completed: PendingAccount?
    private(set) var signedInAccount: PendingAccount?
    private(set) var signedInWith: SignInCredential?
    private(set) var signedUpWith: SignInCredential?
    private var nonces = 0

    init(signIn: CodeSignIn = .needsSignUp, signUp: SignUpOutcome = .created(pendingAccount)) {
        signInAnswer = signIn
        signUpAnswer = signUp
    }

    func startVerification(_ channel: VerificationChannel, to destination: String, locale: String) async throws -> VerificationChallenge {
        sentTo.append(destination)
        return VerificationChallenge(id: "ch-1", channel: channel, destination: destination, expiresIn: 600, resendAfter: 30)
    }

    func startFederatedSignIn() async throws -> String {
        nonces += 1
        return "nonce-\(nonces)"
    }

    func signIn(_ credential: SignInCredential) async throws -> CodeSignIn {
        signedInWith = credential
        return signInAnswer
    }

    func signUp(_ credential: SignInCredential, details: SignUpDetails) async throws -> SignUpOutcome {
        signedUpWith = credential
        self.details = details
        return signUpAnswer
    }

    func completeSignIn(_ account: PendingAccount) async { signedInAccount = account }

    func completeSignUp(_ pending: PendingAccount) async throws { completed = pending }
}

private let pendingAccount: PendingAccount = {
    let session = AuthSession(
        accountID: AccountID("acct-new"), sessionID: SessionID("sess-new"),
        accessToken: "at-pending", accessTokenExpiry: .distantFuture, refreshToken: "rt-pending"
    )
    return PendingAccount(accountID: session.accountID, accessToken: session.accessToken, session: session)
}()

private actor FakeProfileSetup: AccountProfileSetup {
    private(set) var created: (handle: String, name: String)?
    private let profiled: Bool
    init(hasProfile: Bool = true) { profiled = hasProfile }
    func hasProfile(_ account: PendingAccount) async -> Bool { profiled }
    func checkHandle(_ handle: String) async -> HandleCheck { .available(normalized: handle.lowercased()) }
    func createProfile(for account: PendingAccount, handle: String, displayName: String) async throws {
        created = (handle, displayName)
    }
}

/// Apple's sheet, answered at once — or closed.
@MainActor
private final class FakeApple: FederatedSignInProviding {
    var cancels = false
    private(set) var nonce: String?

    func signIn(with provider: FederatedProvider, nonce: String) async throws -> FederatedSignInResult {
        self.nonce = nonce
        if cancels { throw FederatedSignInCancelled() }
        return FederatedSignInResult(idToken: "apple-token", displayName: "Nina Apple")
    }
}

@MainActor
struct SignUpFlowTests {
    /// The flow's stack, with the email step on top.
    /// The flow's stack, with `method` picked on the first screen.
    private func pick(
        _ method: SignInMethod, _ signUp: FakeSignUp,
        apple: FakeApple? = nil, profileSetup: FakeProfileSetup? = nil
    ) throws -> UINavigationController {
        let flow = LoginFlowCoordinator(
            loginService: NoLogin(), signUp: signUp, federated: apple, profileSetup: profileSetup, homeCountry: { "FR" }
        ).start()
        let navigation = try #require(flow as? UINavigationController)
        let methods = try #require(navigation.viewControllers.first as? MethodSelectionViewController)
        methods.onMethodSelected?(method)
        return navigation
    }

    private func emailStep(
        _ signUp: FakeSignUp, profileSetup: FakeProfileSetup? = nil
    ) throws -> (UINavigationController, EmailEntryViewController) {
        let navigation = try pick(.email, signUp, profileSetup: profileSetup)
        return (navigation, try #require(navigation.topViewController as? EmailEntryViewController))
    }

    /// Waits (bounded) for a call to land a step of `type` on top.
    private func top<T: UIViewController>(
        _ navigation: UINavigationController, is type: T.Type
    ) async throws -> T {
        for _ in 0..<200 {
            if let step = navigation.topViewController as? T { return step }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("\(T.self) never reached the top")
        throw CancellationError()
    }

    /// With codes, "email" asks for an address rather than a password, and
    /// the code goes to it.
    @Test func emailSendsACodeToTheAddress() async throws {
        let signUp = FakeSignUp()
        let (navigation, email) = try emailStep(signUp)

        email.onContinue?("nina@example.com")
        _ = try await top(navigation, is: VerificationCodeViewController.self)

        #expect(await signUp.sentTo == ["nina@example.com"])
    }

    /// An address with no account carries on to the sign-up steps; one with
    /// an account stays put — the shell puts the flow away on the session.
    @Test func aCodeForANewAddressLeadsToTheBirthday() async throws {
        let (navigation, email) = try emailStep(FakeSignUp(signIn: .needsSignUp))
        email.onContinue?("nina@example.com")
        let code = try await top(navigation, is: VerificationCodeViewController.self)

        code.onSubmit?("123456")

        _ = try await top(navigation, is: BirthdayViewController.self)
    }

    @Test func aCodeForAnExistingAccountSignsInWithoutMoreSteps() async throws {
        let signUp = FakeSignUp(signIn: .existing(pendingAccount))
        let (navigation, email) = try emailStep(signUp)
        email.onContinue?("demo@example.com")
        let code = try await top(navigation, is: VerificationCodeViewController.self)

        code.onSubmit?("123456")
        try await Task.sleep(for: .milliseconds(200))

        #expect(navigation.topViewController === code)
        #expect(await signUp.signedInAccount == pendingAccount, "the account becomes the session")
    }

    /// An account a sign-up left before its profile picks up at the username
    /// step, and only becomes the session once it has one.
    @Test func anAccountWithNoProfileFinishesSettingUp() async throws {
        let signUp = FakeSignUp(signIn: .existing(pendingAccount))
        let setup = FakeProfileSetup(hasProfile: false)
        let (navigation, email) = try emailStep(signUp, profileSetup: setup)
        email.onContinue?("half.done@example.com")
        try await top(navigation, is: VerificationCodeViewController.self).onSubmit?("123456")

        let profile = try await top(navigation, is: ProfileSetupViewController.self)
        #expect(await signUp.signedInAccount == nil)
        #expect(profile.navigationItem.hidesBackButton)

        profile.onCreate?("half.done", "")
        for _ in 0..<200 {
            if await signUp.completed != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await setup.created?.handle == "half.done")
        #expect(await signUp.completed == pendingAccount)
    }

    /// Agreeing creates the account with what the steps collected, then the
    /// profile step follows with no way back; creating the profile completes
    /// the sign-up.
    @Test func agreeingCreatesTheAccountThenItsProfile() async throws {
        let signUp = FakeSignUp()
        let setup = FakeProfileSetup()
        let (navigation, email) = try emailStep(signUp, profileSetup: setup)
        email.onContinue?("nina@example.com")
        try await top(navigation, is: VerificationCodeViewController.self).onSubmit?("123456")
        try await top(navigation, is: BirthdayViewController.self)
            .onContinue?(DateComponents(year: 2000, month: 2, day: 29))
        try await top(navigation, is: ConsentViewController.self).onAgree?(true, false)

        let profile = try await top(navigation, is: ProfileSetupViewController.self)
        let details = try #require(await signUp.details)
        #expect(details.dateOfBirth == DateComponents(year: 2000, month: 2, day: 29))
        #expect(details.policyVersion == PrivacyPolicy.version)
        #expect(details.marketing && !details.analytics)
        #expect(details.homeCountry == "FR")
        #expect(profile.navigationItem.hidesBackButton)

        profile.onCreate?("nina", "Nina")
        for _ in 0..<200 {
            if await signUp.completed != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await setup.created?.handle == "nina")
        #expect(await signUp.completed == pendingAccount)
    }

    // MARK: Sign in with Apple (#507)

    /// Apple gets the server's nonce, and the id_token goes back with the
    /// same raw nonce; an Apple ID with an account needs nothing more.
    @Test func appleSignsInWithTheServersNonce() async throws {
        let signUp = FakeSignUp(signIn: .existing(pendingAccount))
        let apple = FakeApple()
        let navigation = try pick(.provider(.apple), signUp, apple: apple)

        for _ in 0..<200 {
            if await signUp.signedInWith != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(apple.nonce == "nonce-1")
        #expect(await signUp.signedInWith == .idToken(.apple, token: "apple-token", nonce: "nonce-1"))
        #expect(navigation.topViewController is MethodSelectionViewController)
    }

    /// A new Apple ID goes through the same steps, signs up with its token,
    /// and the name Apple shared fills the profile's.
    @Test func aNewAppleIDSignsUpWithItsTokenAndName() async throws {
        let signUp = FakeSignUp(signIn: .needsSignUp)
        let navigation = try pick(.provider(.apple), signUp, apple: FakeApple(), profileSetup: FakeProfileSetup())

        try await top(navigation, is: BirthdayViewController.self)
            .onContinue?(DateComponents(year: 2000, month: 1, day: 1))
        try await top(navigation, is: ConsentViewController.self).onAgree?(false, false)
        let profile = try await top(navigation, is: ProfileSetupViewController.self)
        profile.view.frame = CGRect(x: 0, y: 0, width: 400, height: 900)
        profile.view.layoutIfNeeded()

        #expect(await signUp.signedUpWith == .idToken(.apple, token: "apple-token", nonce: "nonce-1"))
        let name = profile.view.firstSubview(identifier: "signup.name") as? UITextField
        #expect(name?.text == "Nina Apple")
    }

    /// Closing Apple's sheet leaves the flow where it was, with nothing said.
    @Test func closingApplesSheetChangesNothing() async throws {
        let signUp = FakeSignUp()
        let apple = FakeApple()
        apple.cancels = true
        let navigation = try pick(.provider(.apple), signUp, apple: apple)

        try await Task.sleep(for: .milliseconds(200))

        #expect(await signUp.signedInWith == nil)
        #expect(navigation.topViewController is MethodSelectionViewController)
        #expect(navigation.presentedViewController == nil)
    }
}

private extension UIView {
    /// The first view under this one with `identifier`.
    func firstSubview(identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.firstSubview(identifier: identifier) { return match }
        }
        return nil
    }
}

/// Apple signs the nonce's SHA-256 as lowercase hex, which the server
/// compares with the raw nonce's.
@MainActor
@Test func appleGetsTheNoncesSHA256Hex() {
    #expect(AppleSignInProvider.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}
