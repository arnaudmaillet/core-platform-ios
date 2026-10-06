import UIKit
#if DEBUG
import DesignSystem
#endif

/// Destinations of the flow-wide toolbar legal links.
enum AuthLegalLink: CaseIterable {
    case privacy
    case contact

    var displayName: String {
        switch self {
        case .privacy: "Privacy & Legal"
        case .contact: "Contact"
        }
    }
}

/// Orchestrates the sign-in flow on its own navigation stack: an explicit
/// method-selection menu branching to the email or phone credentials screen
/// (or a federated placeholder). Owns the shared `LoginViewModel` — the auth
/// core stays a single seam over `LoginPerforming` — while the screens stay
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

    private let viewModel: LoginViewModel
    private weak var navigationController: UINavigationController?

    /// Sign-up and sign-in by code (guest mode B4, #449). Nil keeps the
    /// password screen behind "email" and the unavailable phone path.
    private let signUp: (any SignUpPerforming)?
    /// Native Sign in with Apple. Nil keeps the provider rows unavailable.
    private let federated: (any FederatedSignInProviding)?
    /// The new account's profile. Nil completes a sign-up without one.
    private let profileSetup: (any AccountProfileSetup)?
    /// The account's home country: the current one, else the storefront's.
    private let homeCountry: @Sendable () async -> String
    /// What the steps have collected so far.
    private var challenge: VerificationChallenge?
    /// What proved the identity: the code, or the provider's id_token. It
    /// signs the account up once the steps are done.
    private var credential: SignInCredential?
    /// The name a provider shared, for the profile step.
    private var suggestedName: String?
    private var dateOfBirth: DateComponents?

    /// One toolbar item set for the WHOLE flow, shared by every step (see
    /// `flowToolbarItems` on the base controller for why identical instances
    /// matter): Privacy & Legal pinned leading, Contact pinned trailing, one
    /// flexible space stretching between. The language selector lives in the
    /// credential screens' navigation bars, not here.
    private lazy var flowToolbarItems: [UIBarButtonItem] = {
        let privacyItem = makeCapsuleItem(title: AuthLegalLink.privacy.displayName) { [weak self] in
            self?.showLegalPlaceholder(.privacy)
        }
        let contactItem = makeCapsuleItem(title: AuthLegalLink.contact.displayName) { [weak self] in
            self?.showLegalPlaceholder(.contact)
        }
        return [
            privacyItem,
            .flexibleSpace(),
            contactItem
        ]
    }()

    /// The language selector as a top-right navigation bar item — globe +
    /// locale code in ONE glass capsule (a standard item shows only its
    /// image when given both, so the content is a configured `UIButton`).
    /// Minted fresh per screen: a `UIBarButtonItem` can't be installed in
    /// two `navigationItem`s, and nav bar items ride push transitions
    /// natively, so no instance sharing is needed here.
    private func makeLanguageNavItem() -> UIBarButtonItem {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "globe")
        configuration.title = Locale.current.identifier(.bcp47)
        configuration.imagePadding = 4
        configuration.baseForegroundColor = .secondaryLabel
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.appFont(forTextStyle: .footnote)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = String(localized: "Change language")
        let item = UIBarButtonItem(customView: button)
        button.addAction(
            UIAction { [weak self, weak item] _ in
                guard let self, let item else { return }
                presentLanguageSheet(from: item)
            },
            for: .primaryActionTriggered
        )
        button.sizeToFit()
        return item
    }

    /// Standard titled bar item in the system's own capsule.
    private func makeCapsuleItem(title: String, handler: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(primaryAction: UIAction(title: title) { _ in handler() })
        item.tintColor = .secondaryLabel
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.appFont(forTextStyle: .footnote)
        ]
        item.setTitleTextAttributes(attributes, for: .normal)
        item.setTitleTextAttributes(attributes, for: .highlighted)
        return item
    }

    init(
        loginService: any LoginPerforming,
        signUp: (any SignUpPerforming)? = nil,
        federated: (any FederatedSignInProviding)? = nil,
        profileSetup: (any AccountProfileSetup)? = nil,
        homeCountry: @escaping @Sendable () async -> String = { Locale.current.region?.identifier ?? "" }
    ) {
        viewModel = LoginViewModel(loginService: loginService)
        self.signUp = signUp
        self.federated = federated
        self.profileSetup = profileSetup
        self.homeCountry = homeCountry
    }

    /// `onClose` non-nil = presented over the app rather than installed as the
    /// window's root: the first screen gets a close button, because a guest
    /// who opened it must be able to go back to browsing.
    func start(prompt: String? = nil, onClose: (() -> Void)? = nil) -> UIViewController {
        let methodSelection = MethodSelectionViewController()
        methodSelection.prompt = prompt
        if let onClose {
            methodSelection.navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close,
                primaryAction: UIAction { _ in onClose() }
            )
        }
        methodSelection.onMethodSelected = { [self] method in
            select(method)
        }
        methodSelection.onLogIn = { [self] in
            showEmailAuth()
        }
        methodSelection.flowToolbarItems = flowToolbarItems

        let navigation = UINavigationController(rootViewController: methodSelection)
        // The language toolbar blends with the canvas instead of drawing bar
        // chrome of its own.
        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithTransparentBackground()
        navigation.toolbar.standardAppearance = toolbarAppearance
        navigation.toolbar.scrollEdgeAppearance = toolbarAppearance
        navigation.toolbar.compactAppearance = toolbarAppearance
        navigationController = navigation
        #if DEBUG
        runQAHooksIfNeeded()
        #endif
        return navigation
    }

    private func select(_ method: SignInMethod) {
        switch method {
        case .provider(.apple) where signUp != nil && federated != nil:
            signIn(with: .apple)
        case .provider(let provider):
            presentFederatedUnavailable(provider)
        case .email:
            if signUp != nil { showEmailCode() } else { showEmailAuth() }
        case .phone:
            showPhoneAuth()
        }
    }

    private func showPhoneAuth() {
        let phone = PhoneAuthViewController()
        phone.onSendCode = { [self] e164, display in
            if signUp != nil {
                sendCode(.sms, to: e164, display: display, from: nil)
            } else {
                beginOTPVerification(e164: e164, display: display)
            }
        }
        phone.flowToolbarItems = flowToolbarItems
        phone.navigationItem.rightBarButtonItem = makeLanguageNavItem()
        push(phone)
    }

    /// The OTP seam. There is no SMS/OTP plane on the BFF yet (see
    /// `dev/BACKEND_GAPS.md` §6): when it exists, the dispatch call goes
    /// here before presenting, and `onVerify` exchanges the code for a
    /// session (the app's session observer then swaps the root). Until
    /// then verification lands on an honest unavailable alert.
    private func beginOTPVerification(e164: String, display: String) {
        _ = e164 // The dispatch payload, unused until the backend exists.
        let verification = OTPVerificationViewController(phoneDisplay: display)
        verification.onVerify = { [self] _ in
            navigationController?.presentedViewController?.dismiss(animated: true) { [self] in
                presentPhoneSignInUnavailable()
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-login-demo-phone") {
            verification.qaAutoVerify = "123456"
        }
        #endif
        let sheet = UINavigationController(rootViewController: verification)
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        navigationController?.present(sheet, animated: true)
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
        prepare(step)
        push(step)
    }

    private func prepare(_ step: UIViewController) {
        (step as? BottomAnchoredTableViewController)?.flowToolbarItems = flowToolbarItems
        step.navigationItem.rightBarButtonItem = makeLanguageNavItem()
    }

    private func sendCode(
        _ channel: VerificationChannel, to destination: String, display: String, from step: SignUpStepViewController?
    ) {
        guard let signUp else { return }
        step?.setWorking(true)
        Task { [weak self] in
            do {
                let challenge = try await signUp.startVerification(
                    channel, to: destination, locale: Locale.current.identifier(.bcp47)
                )
                step?.setWorking(false)
                self?.showCode(challenge, display: display)
            } catch {
                step?.setWorking(false)
                self?.presentFlowError(error, on: step)
            }
        }
    }

    private func showCode(_ challenge: VerificationChallenge, display: String) {
        self.challenge = challenge
        let step = VerificationCodeViewController(destination: display, resendAfter: challenge.resendAfter)
        step.onSubmit = { [weak self, weak step] code in self?.verify(code, from: step) }
        step.onResend = { [weak self, weak step] in self?.resendCode(from: step) }
        prepare(step)
        push(step)
    }

    private func resendCode(from step: VerificationCodeViewController?) {
        guard let signUp, let current = challenge else { return }
        Task { [weak self] in
            do {
                let fresh = try await signUp.startVerification(
                    current.channel, to: current.destination, locale: Locale.current.identifier(.bcp47)
                )
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
                case .signedIn:
                    break // the presenter dismisses on the new session
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
    private func signIn(with provider: FederatedProvider) {
        guard let signUp, let federated, let screen = navigationController?.topViewController else { return }
        screen.view.isUserInteractionEnabled = false
        Task { [weak self] in
            defer { screen.view.isUserInteractionEnabled = true }
            do {
                let nonce = try await signUp.startFederatedSignIn()
                let result = try await federated.signIn(with: provider, nonce: nonce)
                let credential = SignInCredential.idToken(provider, token: result.idToken, nonce: nonce)
                switch try await signUp.signIn(credential) {
                case .signedIn:
                    break // the presenter dismisses on the new session
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

    private func showBirthday() {
        let step = BirthdayViewController()
        step.onContinue = { [weak self] birthday in
            self?.dateOfBirth = birthday
            self?.showConsent()
        }
        prepare(step)
        push(step)
    }

    private func showConsent() {
        let step = ConsentViewController()
        step.onAgree = { [weak self, weak step] marketing, analytics in
            self?.createAccount(marketing: marketing, analytics: analytics, from: step)
        }
        step.onOpenPolicy = { [weak self] in self?.showLegalPlaceholder(.privacy) }
        prepare(step)
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

    private func showProfileSetup(for pending: PendingAccount, setup: any AccountProfileSetup) {
        let step = ProfileSetupViewController(setup: setup, suggestedName: suggestedName)
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
        prepare(step)
        // No way back past an account that now exists: the step replaces the
        // flow behind it.
        step.navigationItem.hidesBackButton = true
        push(step)
    }

    private func presentExistingAccount(_ method: ExistingSignInMethod) {
        let how = switch method {
        case .apple: "Sign in with Apple"
        case .google: "Sign in with Google"
        case .password: "Log in with your password"
        case .emailCode: "Continue with email"
        case .phoneCode: "Continue with your phone"
        case .unknown: "Sign in"
        }
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
        if let step {
            step.present(error: error)
            return
        }
        let message = (error as? AuthError).map(LoginViewModel.message(for:)) ?? "Something went wrong. Try again."
        let alert = UIAlertController(title: "Couldn\u{2019}t Continue", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController?.topViewController?.present(alert, animated: true)
    }

    private func showEmailAuth() {
        let credentials = CredentialsAuthViewController(viewModel: viewModel)
        credentials.onForgotPassword = { [self] in
            showPasswordReset()
        }
        credentials.flowToolbarItems = flowToolbarItems
        credentials.navigationItem.rightBarButtonItem = makeLanguageNavItem()
        push(credentials)
    }

    /// The reset-dispatch seam: there is no reset plane on the BFF yet —
    /// when it exists, the request call goes here and the alert becomes the
    /// "check your inbox" confirmation. The screen never changes.
    private func showPasswordReset() {
        let reset = PasswordResetViewController()
        reset.onSubmit = { [self] identifier in
            _ = identifier // The dispatch payload, unused until the backend exists.
            presentPasswordResetUnavailable()
        }
        reset.flowToolbarItems = flowToolbarItems
        reset.navigationItem.rightBarButtonItem = makeLanguageNavItem()
        push(reset)
    }

    private func presentPasswordResetUnavailable() {
        let alert = UIAlertController(
            title: "Password Reset Isn\u{2019}t Available Yet",
            message: "Sending reset links requires backend support that isn\u{2019}t live.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController?.topViewController?.present(alert, animated: true)
    }

    /// The legal/contact destinations don't exist yet either.
    private func showLegalPlaceholder(_ link: AuthLegalLink) {
        switch link {
        case .privacy:
            pushPlaceholder(
                title: link.displayName,
                symbolName: "hand.raised.fill",
                text: "Privacy & Legal",
                secondaryText: "Policies aren\u{2019}t available here yet."
            )
        case .contact:
            pushPlaceholder(
                title: link.displayName,
                symbolName: "envelope.fill",
                text: "Contact",
                secondaryText: "Contact options aren\u{2019}t available yet."
            )
        }
    }

    /// Pushes a step of the flow. A credential step needs the keyboard and
    /// the whole height, so a sheet resting at its shorter detent grows first.
    private func push(_ screen: UIViewController) {
        guard let navigationController else { return }
        if let sheet = navigationController.sheetPresentationController,
           sheet.selectedDetentIdentifier != .large {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
        navigationController.pushViewController(screen, animated: true)
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

    /// Language selection has no screen yet; the switcher opens an empty
    /// action sheet until it does.
    private func presentLanguageSheet(from item: UIBarButtonItem) {
        let sheet = UIAlertController(
            title: "Language",
            message: "Language selection isn\u{2019}t available yet.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "OK", style: .cancel))
        sheet.popoverPresentationController?.sourceItem = item
        navigationController?.topViewController?.present(sheet, animated: true)
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
            message: "Sign in with your email and password instead.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController?.topViewController?.present(alert, animated: true)
    }

    #if DEBUG
    /// Sim QA scripts (no tap injection available):
    /// `-login-demo-error` — email screen, demo/wrong-password, submits into
    /// the failure alert. `-login-demo-phone` — phone screen, types a French
    /// number (live formatting), Send Code into the verification sheet,
    /// auto-verifies into the unavailable alert. `-login-demo-signup` /
    /// `-login-demo-forgot` — land on the respective placeholders.
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
        if arguments.contains("-login-demo-error") {
            qaWhenSettled("login-demo-error", on: MethodSelectionViewController.self) { [self] in
                showEmailAuth()
                guard let top = navigationController?.topViewController as? CredentialsAuthViewController else {
                    QAWait.fail("login-demo-error", "the email screen is not on top after the push")
                    return
                }
                top.qaAutoSubmit = (identifier: "demo", password: "wrong-password")
            }
        } else if arguments.contains("-login-demo-phone") {
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
        } else if arguments.contains("-login-demo-forgot") {
            qaWhenSettled("login-demo-forgot email", on: MethodSelectionViewController.self) { [self] in
                showEmailAuth()
                // The second push waits for the first to LAND, not for 1s.
                QAWait.until("login-demo-forgot reset", { [self] in
                    qaStackIsAtRest(on: CredentialsAuthViewController.self)
                }) { [self] in
                    showPasswordReset()
                    guard let top = navigationController?.topViewController as? PasswordResetViewController else {
                        QAWait.fail("login-demo-forgot", "the reset screen is not on top after the push")
                        return
                    }
                    top.qaAutoSubmit = "demo"
                }
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

/// Pushed stand-in screens drop the flow's language toolbar; the step
/// controllers restore it on re-appear.
private final class PlaceholderViewController: UIViewController {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }
}
