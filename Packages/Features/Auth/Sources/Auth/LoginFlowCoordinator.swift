import AuthInterface
import DesignSystem
import SafariServices
import UIKit

/// Orchestrates the sign-in flow on its own navigation stack: an explicit
/// method-selection menu branching to a code sent by email or SMS, or to
/// Sign in with Apple. There is no password any more (#840): a code proves
/// the address, and an address with an account signs in. The screens stay
/// dumb and report upward through closures.
///
/// Lifetime: the root screen's closures strongly capture the coordinator, so
/// it lives exactly as long as the navigation stack the shell installs.
@MainActor
final class LoginFlowCoordinator {
    /// Registration hand-off seam: when a registration module exists, the
    /// composition root injects its entry point here and Create Account
    /// pushes it; until then the flow lands on a native placeholder.
    var makeRegistrationViewController: (@MainActor () -> UIViewController)?

    private weak var navigationController: UINavigationController?

    /// Sign-up and sign-in by code (guest mode B4, #449) — the only way in
    /// since passwords went (#840). Nil (tests of the shell alone): the
    /// methods say they are unavailable.
    private let signUp: (any SignUpPerforming)?
    /// Native Sign in with Apple. Nil keeps the provider rows unavailable.
    private let federated: (any FederatedSignInProviding)?
    /// The device's passkeys (#551). Nil: no passkey row.
    private let passkeys: (any PasskeyAuthorizing)?
    /// The new account's profile. Nil completes a sign-up without one.
    private let profileSetup: (any AccountProfileSetup)?
    /// The account's home country: the current one, else the storefront's.
    private let homeCountry: @Sendable () async -> String
    /// The pages the legal line and the consent step open (#1811).
    private let legalLinks: AuthLegalLinks
    /// What the steps have collected so far.
    private var challenge: VerificationChallenge?
    /// What proved the identity: the code, or the provider's id_token. It
    /// signs the account up once the steps are done.
    private var credential: SignInCredential?
    /// The name a provider shared, for the profile step.
    private var suggestedName: String?
    private var dateOfBirth: DateComponents?

    /// A call the flow never has out twice (#827): a second tap while one is
    /// out does nothing, rather than sending a second SMS or opening a second
    /// Apple sheet.
    enum Call: Hashable {
        case sendCode, resendCode, federatedSignIn, passkeySignIn
    }

    /// The calls out right now.
    private(set) var callsInFlight: Set<Call> = []

    init(
        signUp: (any SignUpPerforming)? = nil,
        federated: (any FederatedSignInProviding)? = nil,
        passkeys: (any PasskeyAuthorizing)? = nil,
        profileSetup: (any AccountProfileSetup)? = nil,
        homeCountry: @escaping @Sendable () async -> String = { Locale.current.region?.identifier ?? "" },
        legalLinks: AuthLegalLinks = AuthLegalLinks()
    ) {
        self.legalLinks = legalLinks
        self.signUp = signUp
        self.federated = federated
        self.passkeys = passkeys
        self.profileSetup = profileSetup
        self.homeCountry = homeCountry
    }

    /// The flow's stack, with the method list on it. Presented as a sheet
    /// over the app (`ContentFittingNavigationController.fit`) it has no close
    /// button (#1811): the swipe is the way out, protected once a code was
    /// sent. `prompt` is the gated action's headline; nil says "Log in or sign
    /// up".
    func start(prompt: String? = nil) -> UIViewController {
        let methodSelection = MethodSelectionViewController(
            methods: SignInMethod.offered(passkeys: passkeys != nil && signUp != nil)
        )
        methodSelection.prompt = prompt ?? MethodSelectionViewController.defaultPrompt
        methodSelection.legalLinks = legalLinks
        methodSelection.onOpenLink = { [weak self] url in self?.openPage(url) }
        methodSelection.onMethodSelected = { [self] method in
            select(method)
        }

        // A short sheet for the list, a full-height one for the form (#563,
        // #1811).
        let navigation = ContentFittingNavigationController(rootViewController: methodSelection)
        navigation.protectsInput = Self.protectsInput(at:)
        navigationController = navigation
        #if DEBUG
        runQAHooksIfNeeded()
        #endif
        return navigation
    }

    private func select(_ method: SignInMethod) {
        switch method {
        case .provider(.apple) where signUp != nil && federated != nil:
            signIn(with: .apple, from: method)
        case .provider(let provider):
            presentFederatedUnavailable(provider)
        case .email:
            if signUp != nil { showEmailCode() } else { presentCodesUnavailable() }
        case .phone:
            showPhoneAuth()
        case .passkey:
            signInWithPasskey(from: method)
        }
    }

    private func showPhoneAuth() {
        let phone = PhoneAuthViewController()
        phone.onSendCode = { [self, weak phone] e164, display in
            if signUp != nil {
                sendCode(.sms, to: e164, display: display, from: phone)
            } else {
                beginOTPVerification(e164: e164, display: display)
            }
        }
        push(phone)
    }

    /// The OTP seam, reached only without sign-up services. There is no
    /// SMS/OTP plane on the BFF yet (see `dev/BACKEND_GAPS.md` §6): when it
    /// exists, the dispatch call goes here, and `onVerify` exchanges the code
    /// for a session (the app's session observer then swaps the root). Until
    /// then verification lands on an honest unavailable alert. PUSHED like
    /// every other step (#1811): never a second sheet over the sign-in sheet.
    private func beginOTPVerification(e164: String, display: String) {
        _ = e164 // The dispatch payload, unused until the backend exists.
        let verification = OTPVerificationViewController(phoneDisplay: display)
        verification.onVerify = { [self] _ in
            presentPhoneSignInUnavailable()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-login-demo-phone") {
            verification.qaAutoVerify = "123456"
        }
        #endif
        push(verification)
    }

    private func presentPhoneSignInUnavailable() {
        let alert = UIAlertController(
            title: "Phone Sign-In Isn\u{2019}t Available Yet",
            message: "Code verification requires backend support that isn\u{2019}t live. Sign in with email instead.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController?.topViewController?.present(alert, animated: true)
    }

    // MARK: - Codes and sign-up (guest mode B4, #449)

    private func showEmailCode() {
        let step = EmailEntryViewController()
        step.onContinue = { [weak self, weak step] address in
            self?.sendCode(.email, to: address, display: address, from: step)
        }
        push(step)
    }

    /// `step` is the screen whose button sent it — the email step, or the
    /// phone screen — and shows the call until it ends.
    private func sendCode(
        _ channel: VerificationChannel, to destination: String, display: String, from step: (any WorkingIndicating)?
    ) {
        guard let signUp, callsInFlight.insert(.sendCode).inserted else { return }
        step?.setWorking(true)
        Task { [weak self] in
            defer { self?.callsInFlight.remove(.sendCode) }
            do {
                let challenge = try await signUp.startVerification(
                    channel, to: destination, locale: Locale.current.identifier(.bcp47)
                )
                step?.setWorking(false)
                self?.showCode(challenge, display: display)
            } catch {
                step?.setWorking(false)
                self?.presentFlowError(error, on: step as? SignUpStepViewController)
            }
        }
    }

    private func showCode(_ challenge: VerificationChallenge, display: String) {
        self.challenge = challenge
        let step = VerificationCodeViewController(destination: display, resendAfter: challenge.resendAfter)
        step.onSubmit = { [weak self, weak step] code in self?.verify(code, from: step) }
        step.onResend = { [weak self, weak step] in self?.resendCode(from: step) }
        push(step)
    }

    /// The spinner sits on the link that asked: the code step's one trailing
    /// row.
    private func resendCode(from step: VerificationCodeViewController?) {
        guard let signUp, let current = challenge, callsInFlight.insert(.resendCode).inserted else { return }
        step?.setTrailingRowWorking(true, at: 0)
        Task { [weak self] in
            defer {
                step?.setTrailingRowWorking(false, at: 0)
                self?.callsInFlight.remove(.resendCode)
            }
            do {
                let fresh = try await signUp.startVerification(
                    current.channel, to: current.destination, locale: Locale.current.identifier(.bcp47)
                )
                // ⚠️ ONLY OVER THE CHALLENGE IT WAS ASKED FOR. Going back and
                // sending a code to another address while this was out made a
                // newer challenge; a late resend must not put the old one back
                // under the code step now showing.
                guard self?.challenge?.id == current.id else { return }
                self?.challenge = fresh
                step?.codeResent(resendAfter: fresh.resendAfter)
            } catch {
                self?.presentFlowError(error, on: step)
            }
        }
    }

    /// The code signs an existing account in — the shell sees the session and
    /// puts the flow away — or, for an address with no account, the sign-up
    /// steps follow with the same code.
    private func verify(_ code: String, from step: VerificationCodeViewController?) {
        guard let signUp, let challenge else { return }
        step?.setWorking(true)
        Task { [weak self] in
            do {
                let credential = SignInCredential.code(challengeID: challenge.id, code: code)
                switch try await signUp.signIn(credential) {
                case .existing(let account):
                    await self?.finishSignIn(account, from: step)
                case .needsSecondStep(let challenge):
                    step?.setWorking(false)
                    self?.showSecondStep(challenge)
                case .needsSignUp:
                    step?.setWorking(false)
                    self?.credential = credential
                    self?.suggestedName = nil
                    self?.showBirthday()
                }
            } catch {
                step?.setWorking(false)
                self?.presentFlowError(error, on: step)
                step?.clearCode()
            }
        }
    }

    /// Sign in with Apple (#507): a nonce from the server, Apple's sheet,
    /// then the id_token signs in — or, for an Apple ID with no account,
    /// the sign-up steps follow with it. Closing Apple's sheet says nothing.
    /// `method`'s row shows the sign-in until it ends.
    private func signIn(with provider: FederatedProvider, from method: SignInMethod) {
        guard let signUp, let federated, let screen = navigationController?.topViewController,
              callsInFlight.insert(.federatedSignIn).inserted
        else { return }
        let methods = screen as? MethodSelectionViewController
        methods?.setWorking(method)
        screen.view.isUserInteractionEnabled = false
        Task { [weak self] in
            defer {
                screen.view.isUserInteractionEnabled = true
                methods?.setWorking(nil)
                self?.callsInFlight.remove(.federatedSignIn)
            }
            do {
                let nonce = try await signUp.startFederatedSignIn()
                let result = try await federated.signIn(with: provider, nonce: nonce)
                let credential = SignInCredential.idToken(provider, token: result.idToken, nonce: nonce)
                switch try await signUp.signIn(credential) {
                case .existing(let account):
                    self?.suggestedName = result.displayName
                    await self?.finishSignIn(account, from: nil)
                case .needsSecondStep(let challenge):
                    self?.suggestedName = result.displayName
                    self?.showSecondStep(challenge)
                case .needsSignUp:
                    self?.credential = credential
                    self?.suggestedName = result.displayName
                    self?.showBirthday()
                }
            } catch is FederatedSignInCancelled {
                return
            } catch {
                self?.presentFlowError(error, on: nil)
            }
        }
    }

    /// A passkey sign-in (#551): a challenge from the server, the system's
    /// passkey sheet, then `Login { passkey }` — no second step, a passkey
    /// is two factors. Closing the sheet (or having no passkey here) says
    /// nothing.
    private func signInWithPasskey(from method: SignInMethod) {
        guard let signUp, let passkeys, let screen = navigationController?.topViewController,
              callsInFlight.insert(.passkeySignIn).inserted
        else { return }
        let methods = screen as? MethodSelectionViewController
        methods?.setWorking(method)
        screen.view.isUserInteractionEnabled = false
        Task { [weak self] in
            defer {
                screen.view.isUserInteractionEnabled = true
                methods?.setWorking(nil)
                self?.callsInFlight.remove(.passkeySignIn)
            }
            do {
                let request = try await signUp.startPasskeySignIn()
                let assertion = try await passkeys.assertPasskey(request)
                switch try await signUp.signIn(.passkey(assertion)) {
                case .existing(let account):
                    await self?.finishSignIn(account, from: nil)
                case .needsSecondStep(let challenge):
                    // Not the contract's (a passkey has no second step),
                    // but a server that asks gets its code.
                    self?.showSecondStep(challenge)
                case .needsSignUp:
                    self?.presentFlowError(AuthError.passkeyRejected, on: nil)
                }
            } catch is PasskeyCancelled {
                return
            } catch {
                self?.presentFlowError(error, on: nil)
            }
        }
    }

    /// An account that has its profile becomes the session, and the shell
    /// puts the flow away. One a sign-up left before its profile — the app
    /// closed at the username step — picks up there ("Finish setting up").
    private func finishSignIn(_ account: PendingAccount, from step: SignUpStepViewController?) async {
        guard let signUp else { return }
        if let profileSetup, await !profileSetup.hasProfile(account) {
            step?.setWorking(false)
            showProfileSetup(for: account, setup: profileSetup, finishing: true)
            return
        }
        await signUp.completeSignIn(account)
    }

    // MARK: - Two-step sign-in (#383)

    /// A code or Apple sign-in's second step hands back its account, which
    /// goes through `finishSignIn` like any other (the profile check, #548).
    private func showSecondStep(_ challenge: SecondStepChallenge) {
        let step = SecondStepViewController()
        step.onSubmit = { [weak self, weak step] code in
            self?.completeSecondStep(challenge, code: code, from: step)
        }
        push(step)
    }

    private func completeSecondStep(_ challenge: SecondStepChallenge, code: String, from step: SecondStepViewController?) {
        step?.setWorking(true)
        Task { [weak self] in
            guard let self, let signUp else { return }
            do {
                let account = try await signUp.completeSecondStep(challenge, code: code)
                await finishSignIn(account, from: step)
            } catch AuthError.secondStepExpired {
                // The challenge is gone: back to where the sign-in began.
                step?.setWorking(false)
                presentSecondStepExpired()
            } catch {
                step?.setWorking(false)
                presentFlowError(error, on: step)
                step?.clearCode()
            }
        }
    }

    private func presentSecondStepExpired() {
        // An error the viewer's own attempt met, as its alert appears (#1886).
        Haptics.play(.error)
        let alert = UIAlertController(
            title: "Sign In Again", message: AuthMessages.message(for: .secondStepExpired), preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            guard let navigation = self?.navigationController,
                  let index = navigation.viewControllers.lastIndex(where: { $0 is SecondStepViewController }),
                  index > 0 else { return }
            navigation.popToViewController(navigation.viewControllers[index - 1], animated: true)
        })
        navigationController?.topViewController?.present(alert, animated: true)
    }

    private func showBirthday() {
        let step = BirthdayViewController()
        step.onContinue = { [weak self] birthday in
            self?.dateOfBirth = birthday
            self?.showConsent()
        }
        push(step)
    }

    private func showConsent() {
        let step = ConsentViewController()
        step.onAgree = { [weak self, weak step] marketing, analytics in
            self?.createAccount(marketing: marketing, analytics: analytics, from: step)
        }
        if let policy = legalLinks.privacyPolicy {
            step.onOpenPolicy = { [weak self] in self?.openPage(policy) }
        }
        push(step)
    }

    private func createAccount(marketing: Bool, analytics: Bool, from step: ConsentViewController?) {
        guard let signUp, let credential, let dateOfBirth else { return }
        step?.setWorking(true)
        let homeCountry = homeCountry
        Task { [weak self] in
            do {
                let details = SignUpDetails(
                    dateOfBirth: dateOfBirth, policyVersion: PrivacyPolicy.version,
                    marketing: marketing, analytics: analytics, homeCountry: await homeCountry()
                )
                switch try await signUp.signUp(credential, details: details) {
                case .created(let pending):
                    step?.setWorking(false)
                    if let self, let profileSetup {
                        showProfileSetup(for: pending, setup: profileSetup)
                    } else {
                        try await signUp.completeSignUp(pending)
                    }
                case .existingAccount(let method):
                    step?.setWorking(false)
                    self?.presentExistingAccount(method)
                }
            } catch AuthError.underMinimumAge {
                step?.setWorking(false)
                self?.presentUnderMinimumAge()
            } catch {
                step?.setWorking(false)
                self?.presentFlowError(error, on: step)
            }
        }
    }

    private func showProfileSetup(for pending: PendingAccount, setup: any AccountProfileSetup, finishing: Bool = false) {
        let step = ProfileSetupViewController(setup: setup, suggestedName: suggestedName, finishing: finishing)
        step.onCreate = { [weak self, weak step] handle, name in
            guard let signUp = self?.signUp else { return }
            step?.setWorking(true)
            Task { [weak self] in
                do {
                    try await setup.createProfile(for: pending, handle: handle, displayName: name)
                    try await signUp.completeSignUp(pending) // the presenter dismisses on the session
                } catch {
                    step?.setWorking(false)
                    self?.presentFlowError(error, on: step)
                }
            }
        }
        // No way back past an account that now exists: the step replaces the
        // flow behind it.
        step.navigationItem.hidesBackButton = true
        push(step)
    }

    private func presentExistingAccount(_ method: ExistingSignInMethod) {
        let how = switch method {
        case .apple: "Sign in with Apple"
        case .google: "Sign in with Google"
        case .emailCode: "Continue with email"
        case .phoneCode: "Continue with your phone"
        case .unknown: "Sign in"
        }
        Haptics.play(.error)
        let alert = UIAlertController(
            title: "You Already Have an Account",
            message: "This address is already used by an account. \(how) to get back to it.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popToRootViewController(animated: true)
        })
        navigationController?.topViewController?.present(alert, animated: true)
    }

    private func presentUnderMinimumAge() {
        Haptics.play(.error)
        let alert = UIAlertController(
            title: "You Can\u{2019}t Create an Account",
            message: "You need to be old enough to use this app. You can keep browsing without an account.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popToRootViewController(animated: true)
        })
        navigationController?.topViewController?.present(alert, animated: true)
    }

    private func presentFlowError(_ error: Error, on step: SignUpStepViewController?) {
        // The step plays it when one is up; here, the alert does.
        if let step {
            step.present(error: error)
            return
        }
        Haptics.play(.error)
        let message = (error as? AuthError).map(AuthMessages.message(for:)) ?? "Something went wrong. Try again."
        let alert = UIAlertController(title: "Couldn\u{2019}t Continue", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController?.topViewController?.present(alert, animated: true)
    }

    /// No signing-up seam (tests of the shell alone): nothing proves an
    /// address.
    private func presentCodesUnavailable() {
        let alert = UIAlertController(
            title: "Sign-In Isn\u{2019}t Available",
            message: "Sending sign-in codes isn\u{2019}t set up here.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController?.topViewController?.present(alert, animated: true)
    }

    /// Pushes a step of the flow. The sheet grows to full height with the
    /// first push off the method list, and stays there (#1811,
    /// `ContentFittingNavigationController.stage(for:)`).
    private func push(_ screen: UIViewController) {
        navigationController?.pushViewController(screen, animated: true)
    }

    /// Whether leaving at `step` would lose what was typed (#1811): the code
    /// has been sent there. The method list and the address or number entry
    /// lose nothing that a swipe should guard — every later step does.
    static func protectsInput(at step: UIViewController) -> Bool {
        !(step is MethodSelectionViewController || step is EmailEntryViewController
            || step is PhoneAuthViewController || step is PlaceholderViewController)
    }

    /// A legal page, in place over the sheet (#1811).
    private func openPage(_ url: URL) {
        let page = SFSafariViewController(url: url)
        navigationController?.topViewController?.present(page, animated: true)
    }

    /// The account-creation steps (code, date of birth, handle) land here once
    /// the backend has a sign-up contract (#449); nothing reaches it until then.
    private func showRegistration() {
        if let makeRegistrationViewController {
            push(makeRegistrationViewController())
            return
        }
        pushPlaceholder(
            title: "Create Account",
            symbolName: "person.crop.circle.badge.plus",
            text: "Create Account",
            secondaryText: "Registration isn\u{2019}t available yet."
        )
    }

    /// Native empty state for destinations that exist in the layout before
    /// they exist in the product.
    private func pushPlaceholder(title: String, symbolName: String, text: String, secondaryText: String) {
        let placeholder = PlaceholderViewController()
        placeholder.title = title
        placeholder.view.backgroundColor = .systemGroupedBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: symbolName)
        configuration.text = text
        configuration.secondaryText = secondaryText
        placeholder.contentUnavailableConfiguration = configuration
        push(placeholder)
    }

    /// Federated sign-in has no backend yet (no OAuth plane on the BFF);
    /// the row is the seam — this alert is its placeholder behavior.
    private func presentFederatedUnavailable(_ provider: IdentityProvider) {
        let alert = UIAlertController(
            title: "\u{201C}\(provider.displayName)\u{201D} Isn\u{2019}t Available Yet",
            message: "Continue with your email or phone instead.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController?.topViewController?.present(alert, animated: true)
    }

    #if DEBUG
    /// Sim QA scripts (no tap injection available): `-login-demo-phone` —
    /// phone screen, types a French number (live formatting), Send Code into
    /// the verification sheet. `-login-demo-signup` — lands on the
    /// registration placeholder.
    ///
    /// ⚠️ EVERY STEP WAITS FOR A STACK AT REST, not for a clock. The 1s used to
    /// start when `start()` BUILT the root — before the shell had installed it,
    /// let alone shown it — and `-login-demo-forgot` pushed its second screen a
    /// fixed 1s after the first, which under Slow Animations landed mid-push.
    /// Each push now waits for the stack to be in a window, with no transition
    /// in flight and the screen it expects on top, and says `[qa] GAVE UP`
    /// when that never happens. The 1s stays as a beat before the first push.
    private func runQAHooksIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-login-demo-phone") {
            qaWhenSettled("login-demo-phone", on: MethodSelectionViewController.self) { [self] in
                showPhoneAuth()
                guard let top = navigationController?.topViewController as? PhoneAuthViewController else {
                    QAWait.fail("login-demo-phone", "the phone screen is not on top after the push")
                    return
                }
                top.qaAutoSend = "612345678"
            }
        } else if arguments.contains("-login-demo-signup") {
            qaWhenSettled("login-demo-signup", on: MethodSelectionViewController.self) { [self] in
                showRegistration()
            }
        }
    }

    /// The flow's stack is on screen, not mid-transition, with `expected` on top.
    private func qaStackIsAtRest(on expected: UIViewController.Type) -> Bool {
        guard let navigation = navigationController,
              navigation.view.window != nil,
              navigation.transitionCoordinator == nil,
              let top = navigation.topViewController
        else { return false }
        return type(of: top) == expected
    }

    /// Waits the 1s beat, then for `qaStackIsAtRest(on:)`, then runs `action`.
    private func qaWhenSettled(
        _ label: String,
        on expected: UIViewController.Type,
        _ action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            QAWait.until(label, { [self] in qaStackIsAtRest(on: expected) }, then: action)
        }
    }
    #endif
}

/// A pushed stand-in screen, with its bar for the way back.
final class PlaceholderViewController: UIViewController {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
}

#if DEBUG
extension LoginFlowCoordinator {
    /// The alerts an attempt of the viewer's can meet, without the attempt.
    /// Tests.
    enum DebugAlert: CaseIterable { case secondStepExpired, existingAccount, underMinimumAge, flowError }

    func debugPresent(_ alert: DebugAlert) {
        switch alert {
        case .secondStepExpired: presentSecondStepExpired()
        case .existingAccount: presentExistingAccount(.emailCode)
        case .underMinimumAge: presentUnderMinimumAge()
        case .flowError: presentFlowError(AuthError.invalidCredentials, on: nil)
        }
    }
}
#endif
