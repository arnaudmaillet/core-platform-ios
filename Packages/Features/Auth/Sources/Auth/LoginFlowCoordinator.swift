import UIKit

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
            attributes.font = UIFont.preferredFont(forTextStyle: .footnote)
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
            .font: UIFont.preferredFont(forTextStyle: .footnote)
        ]
        item.setTitleTextAttributes(attributes, for: .normal)
        item.setTitleTextAttributes(attributes, for: .highlighted)
        return item
    }

    init(loginService: any LoginPerforming) {
        viewModel = LoginViewModel(loginService: loginService)
    }

    func start() -> UIViewController {
        let methodSelection = MethodSelectionViewController()
        methodSelection.onMethodSelected = { [self] method in
            select(method)
        }
        methodSelection.onCreateAccount = { [self] in
            showRegistration()
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
        case .provider(let provider):
            presentFederatedUnavailable(provider)
        case .email:
            showEmailAuth()
        case .phone:
            showPhoneAuth()
        }
    }

    private func showPhoneAuth() {
        let phone = PhoneAuthViewController()
        phone.onSendCode = { [self] e164, display in
            beginOTPVerification(e164: e164, display: display)
        }
        phone.flowToolbarItems = flowToolbarItems
        phone.navigationItem.rightBarButtonItem = makeLanguageNavItem()
        navigationController?.pushViewController(phone, animated: true)
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

    private func showEmailAuth() {
        let credentials = CredentialsAuthViewController(viewModel: viewModel)
        credentials.onForgotPassword = { [self] in
            showPasswordReset()
        }
        credentials.flowToolbarItems = flowToolbarItems
        credentials.navigationItem.rightBarButtonItem = makeLanguageNavItem()
        navigationController?.pushViewController(credentials, animated: true)
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
        navigationController?.pushViewController(reset, animated: true)
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

    private func showRegistration() {
        if let makeRegistrationViewController {
            navigationController?.pushViewController(makeRegistrationViewController(), animated: true)
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
        navigationController?.pushViewController(placeholder, animated: true)
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
    private func runQAHooksIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-login-demo-error") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                showEmailAuth()
                if let top = navigationController?.topViewController as? CredentialsAuthViewController {
                    top.qaAutoSubmit = (identifier: "demo", password: "wrong-password")
                }
            }
        } else if arguments.contains("-login-demo-phone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                showPhoneAuth()
                if let top = navigationController?.topViewController as? PhoneAuthViewController {
                    top.qaAutoSend = "612345678"
                }
            }
        } else if arguments.contains("-login-demo-signup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                showRegistration()
            }
        } else if arguments.contains("-login-demo-forgot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                showEmailAuth()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                    showPasswordReset()
                    if let top = navigationController?.topViewController as? PasswordResetViewController {
                        top.qaAutoSubmit = "demo"
                    }
                }
            }
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
