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
private actor FakeSignUp: CodeSignUpPerforming {
    let signInAnswer: CodeSignIn
    let signUpAnswer: SignUpOutcome
    private(set) var sentTo: [String] = []
    private(set) var details: SignUpDetails?
    private(set) var completed: PendingAccount?

    init(signIn: CodeSignIn = .needsSignUp, signUp: SignUpOutcome = .created(pendingAccount)) {
        signInAnswer = signIn
        signUpAnswer = signUp
    }

    func startVerification(_ channel: VerificationChannel, to destination: String, locale: String) async throws -> VerificationChallenge {
        sentTo.append(destination)
        return VerificationChallenge(id: "ch-1", channel: channel, destination: destination, expiresIn: 600, resendAfter: 30)
    }

    func signIn(challengeID: String, code: String) async throws -> CodeSignIn { signInAnswer }

    func signUp(challengeID: String, code: String, details: SignUpDetails) async throws -> SignUpOutcome {
        self.details = details
        return signUpAnswer
    }

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
    func checkHandle(_ handle: String) async -> HandleCheck { .available(normalized: handle.lowercased()) }
    func createProfile(for account: PendingAccount, handle: String, displayName: String) async throws {
        created = (handle, displayName)
    }
}

@MainActor
struct SignUpFlowTests {
    /// The flow's stack, with the email step on top.
    private func emailStep(
        _ signUp: FakeSignUp, profileSetup: FakeProfileSetup? = nil
    ) throws -> (UINavigationController, EmailEntryViewController) {
        let flow = LoginFlowCoordinator(
            loginService: NoLogin(), signUp: signUp, profileSetup: profileSetup, homeCountry: { "FR" }
        ).start()
        let navigation = try #require(flow as? UINavigationController)
        let methods = try #require(navigation.viewControllers.first as? MethodSelectionViewController)
        methods.onMethodSelected?(.email)
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
        let (navigation, email) = try emailStep(FakeSignUp(signIn: .signedIn))
        email.onContinue?("demo@example.com")
        let code = try await top(navigation, is: VerificationCodeViewController.self)

        code.onSubmit?("123456")
        try await Task.sleep(for: .milliseconds(200))

        #expect(navigation.topViewController === code)
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
}
