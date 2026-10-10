import DesignSystem
import UIKit

// The steps of signing up or in with a code (guest mode B4, #449). Each is a
// screen of the flow's navigation stack; `LoginFlowCoordinator` decides what
// follows what and makes the calls.

// MARK: - Email

/// "Continue with email": the address a code goes to. No password — the code
/// proves the address, for an account that exists and one that doesn't yet.
final class EmailEntryViewController: SignUpStepViewController {
    var onContinue: ((String) -> Void)?
    private let emailCell = TextFieldCell()

    init() {
        super.init(
            emoji: "\u{2709}\u{FE0F}", title: "Your Email",
            subtitle: "We\u{2019}ll send you a code to sign in or create your account.",
            buttonTitle: "Send Code"
        )
    }

    override func viewDidLoad() {
        let field = emailCell.textField
        field.placeholder = "Email"
        field.keyboardType = .emailAddress
        field.textContentType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.accessibilityIdentifier = "signup.email"
        field.addAction(UIAction { [weak self] _ in self?.refreshButton() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .editingDidEndOnExit)
        rows = [emailCell]
        super.viewDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        emailCell.textField.becomeFirstResponder()
    }

    private var address: String? {
        let raw = (emailCell.textField.text ?? "").trimmingCharacters(in: .whitespaces)
        // An address, not a bare username: the code goes to a mailbox.
        guard raw.contains("@"), let normalized = EmailAddress.normalize(raw) else { return nil }
        return normalized
    }

    override var canContinue: Bool { address != nil }

    override func primaryTapped() {
        guard let address else { return }
        onContinue?(address)
    }
}

// MARK: - Code

/// The six digits sent by email or SMS. Submits on the sixth digit; a new
/// code can be asked for once the server's resend delay has passed.
final class VerificationCodeViewController: SignUpStepViewController {
    var onSubmit: ((String) -> Void)?
    var onResend: (() -> Void)?
    private static let length = 6
    private let codeCell = TextFieldCell()
    private lazy var resendCell = makeLinkCell(title: "Resend Code")
    /// When a new code may be asked for. Readable inside the module so a test
    /// can check that a step coming back keeps its deadline (#784).
    private(set) var resendAvailableAt = Date()
    /// Readable inside the module so a test can watch the countdown end with
    /// its screen (#784); only this screen starts or stops it.
    private(set) var resendTimer: Timer?

    init(destination: String, resendAfter: TimeInterval) {
        super.init(
            emoji: "\u{1F511}", title: "Enter the Code",
            subtitle: "Sent to \(destination).", buttonTitle: "Continue"
        )
        resendAvailableAt = Date().addingTimeInterval(resendAfter)
    }

    override func viewDidLoad() {
        let field = codeCell.textField
        field.placeholder = "6-digit code"
        field.keyboardType = .numberPad
        field.textContentType = .oneTimeCode
        field.textAlignment = .center
        field.accessibilityIdentifier = "signup.code"
        field.addAction(UIAction { [weak self] _ in self?.codeChanged() }, for: .editingChanged)
        rows = [codeCell]
        trailingRows = [resendCell]
        onTrailingRowSelected = { [weak self] _ in self?.resendTapped() }
        super.viewDidLoad()
        startResendCountdown()
    }

    /// Back on screen, a later step popped: the countdown picks up from the
    /// time still left, which the stop below never touched.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard resendTimer?.isValid != true else { return }
        if resendAvailableAt > Date() {
            startResendCountdown()
        } else {
            updateResendRow()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        codeCell.textField.becomeFirstResponder()
    }

    /// ⚠️ THE COUNTDOWN STOPS WHEN THE STEP LEAVES THE SCREEN (#784), popped
    /// or covered by the next step. The release check in the timer only
    /// catches a step that is freed; a step kept on the stack under the next
    /// one ticked away unseen.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private var code: String {
        String((codeCell.textField.text ?? "").filter(\.isNumber).prefix(Self.length))
    }

    override var canContinue: Bool { code.count == Self.length }

    private func codeChanged() {
        codeCell.textField.text = code
        refreshButton()
        if canContinue { primaryTapped() }
    }

    override func primaryTapped() {
        guard canContinue else { return }
        onSubmit?(code)
    }

    /// After a refusal: the field clears and takes the next attempt.
    func clearCode() {
        codeCell.textField.text = ""
        refreshButton()
        codeCell.textField.becomeFirstResponder()
    }

    /// A new code is on its way: the countdown starts over.
    func codeResent(resendAfter: TimeInterval) {
        resendAvailableAt = Date().addingTimeInterval(resendAfter)
        startResendCountdown()
    }

    private func resendTapped() {
        guard Date() >= resendAvailableAt else { return }
        onResend?()
    }

    private func startResendCountdown() {
        resendTimer?.invalidate()
        updateResendRow()
        // ⚠️ THE TIMER ENDS WITH ITS SCREEN (#784): its only `invalidate()` was
        // in `updateResendRow`, which never runs once the screen is gone, so
        // backing out mid-countdown left a 1 Hz timer for the session.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard self != nil else { return timer.invalidate() }
            MainActor.assumeIsolated { self?.updateResendRow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    private func updateResendRow() {
        let remaining = Int(ceil(resendAvailableAt.timeIntervalSinceNow))
        var content = resendCell.contentConfiguration as? UIListContentConfiguration
        if remaining > 0 {
            content?.text = "Resend Code in \(remaining)s"
            content?.textProperties.color = .secondaryLabel
        } else {
            content?.text = "Resend Code"
            content?.textProperties.color = .tintColor
            resendTimer?.invalidate()
        }
        resendCell.contentConfiguration = content
    }
}

// MARK: - Birthday

/// The date of birth the server checks the minimum age against (13; 16 in
/// some countries). Never shown on the profile.
final class BirthdayViewController: SignUpStepViewController {
    var onContinue: ((DateComponents) -> Void)?
    private let picker = UIDatePicker()

    init() {
        super.init(
            emoji: "\u{1F382}", title: "When\u{2019}s Your Birthday?",
            subtitle: "It won\u{2019}t be shown on your profile.", buttonTitle: "Continue"
        )
    }

    override func viewDidLoad() {
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .wheels
        picker.maximumDate = Date()
        picker.minimumDate = Calendar.current.date(byAdding: .year, value: -120, to: Date())
        // Opens on an adult's year rather than today, which no one was born on.
        picker.date = Calendar.current.date(byAdding: .year, value: -20, to: Date()) ?? Date()
        picker.accessibilityIdentifier = "signup.birthday"
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        picker.constrain(in: cell.contentView) { parent in
            picker.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            picker.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            picker.topAnchor.constraint(equalTo: parent.topAnchor)
            picker.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        rows = [cell]
        super.viewDidLoad()
    }

    override func primaryTapped() {
        onContinue?(Calendar.current.dateComponents([.year, .month, .day], from: picker.date))
    }
}

// MARK: - Consent

/// What agreeing means, in plain words, and the two choices that are the
/// person's (GDPR Art. 7): marketing and analytics, both off until turned on.
/// Processing the data the service needs is what "Agree" agrees to.
final class ConsentViewController: SignUpStepViewController {
    var onAgree: ((_ marketing: Bool, _ analytics: Bool) -> Void)?
    var onOpenPolicy: (() -> Void)?
    private let marketing = UISwitch()
    private let analytics = UISwitch()

    init() {
        super.init(
            emoji: "\u{1F6E1}\u{FE0F}", title: "Your Data",
            subtitle: "We use your data to run your account and show you posts. Choose what else you allow — you can change it in Settings.",
            buttonTitle: "Agree and Continue"
        )
    }

    override func viewDidLoad() {
        rows = [
            toggleRow("Marketing emails", detail: "News and offers from us.", toggle: marketing, id: "signup.marketing"),
            toggleRow("Analytics", detail: "Usage data that helps us improve the app.", toggle: analytics, id: "signup.analytics"),
        ]
        trailingRows = [makeLinkCell(title: "Read the Privacy Policy")]
        onTrailingRowSelected = { [weak self] _ in self?.onOpenPolicy?() }
        super.viewDidLoad()
    }

    private func toggleRow(_ title: String, detail: String, toggle: UISwitch, id: String) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.subtitleCell()
        content.text = title
        content.secondaryText = detail
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        toggle.isOn = false
        toggle.accessibilityIdentifier = id
        cell.accessoryView = toggle
        return cell
    }

    override func primaryTapped() {
        onAgree?(marketing.isOn, analytics.isOn)
    }
}

// MARK: - Profile

/// The new account's profile: a handle checked as it's typed, and a name.
final class ProfileSetupViewController: SignUpStepViewController {
    var onCreate: ((_ handle: String, _ displayName: String) -> Void)?
    private let setup: any AccountProfileSetup
    private let handleCell = TextFieldCell()
    private let nameCell = TextFieldCell()
    private let statusCell = UITableViewCell()
    private var check: HandleCheck?
    private var checking: Task<Void, Never>?

    private let suggestedName: String?

    /// `finishing`: the account exists already — a sign-up that stopped
    /// here is picked up at the next sign-in.
    init(setup: any AccountProfileSetup, suggestedName: String? = nil, finishing: Bool = false) {
        self.setup = setup
        self.suggestedName = suggestedName
        super.init(
            emoji: "\u{1F44B}", title: finishing ? "Finish Setting Up" : "Choose a Username",
            subtitle: finishing
                ? "Your account has no profile yet. Choose a username to finish."
                : "It\u{2019}s how people find you. You can change it later.",
            buttonTitle: finishing ? "Done" : "Create Account"
        )
    }

    override func viewDidLoad() {
        let handle = handleCell.textField
        handle.placeholder = "username"
        handle.autocapitalizationType = .none
        handle.autocorrectionType = .no
        handle.textContentType = .username
        handle.accessibilityIdentifier = "signup.handle"
        let at = UILabel()
        at.text = "@"
        at.textColor = .secondaryLabel
        handle.leftView = at
        handle.leftViewMode = .always
        handle.addAction(UIAction { [weak self] _ in self?.handleChanged() }, for: .editingChanged)

        let name = nameCell.textField
        name.placeholder = "Name (optional)"
        name.textContentType = .name
        name.accessibilityIdentifier = "signup.name"
        name.text = suggestedName

        statusCell.selectionStyle = .none
        statusCell.backgroundConfiguration = .clear()
        rows = [handleCell, nameCell]
        trailingRows = [statusCell]
        super.viewDidLoad()
        renderStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleCell.textField.becomeFirstResponder()
    }

    private var handle: String {
        (handleCell.textField.text ?? "").trimmingCharacters(in: .whitespaces)
    }

    override var canContinue: Bool {
        switch check {
        case .available, .unknown: true
        default: false
        }
    }

    /// Asked a beat after the last keystroke, never for every letter.
    private func handleChanged() {
        check = nil
        renderStatus()
        refreshButton()
        checking?.cancel()
        let typed = handle
        guard !typed.isEmpty else { return }
        checking = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            let answer = await setup.checkHandle(typed)
            guard !Task.isCancelled, handle == typed else { return }
            check = answer
            renderStatus()
            refreshButton()
        }
    }

    private func renderStatus() {
        var content = UIListContentConfiguration.cell()
        content.textProperties.font = .appFont(forTextStyle: .footnote)
        content.textProperties.alignment = .center
        switch check {
        case .available(let normalized):
            content.text = "@\(normalized) is available"
            content.textProperties.color = .systemGreen
        case .taken:
            content.text = "That username is taken"
            content.textProperties.color = .systemRed
        case .invalid(let reason):
            content.text = reason
            content.textProperties.color = .systemRed
        case .unknown:
            content.text = "Couldn\u{2019}t check this username right now"
            content.textProperties.color = .secondaryLabel
        case nil:
            content.text = "3–30 letters, numbers, dots or underscores"
            content.textProperties.color = .secondaryLabel
        }
        statusCell.contentConfiguration = content
    }

    override func primaryTapped() {
        guard canContinue else { return }
        let name = (nameCell.textField.text ?? "").trimmingCharacters(in: .whitespaces)
        onCreate?(handle, name)
    }

    /// The account already exists: there is no way back past it, working or
    /// not.
    override func setWorking(_ working: Bool) {
        super.setWorking(working)
        navigationItem.hidesBackButton = true
    }
}
