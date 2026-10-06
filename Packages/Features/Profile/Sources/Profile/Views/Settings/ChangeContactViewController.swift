import DesignSystem
import UIKit

/// Settings → Account → Email / Phone (#393, backend #651): the new address,
/// a code sent there, then the change.
///
/// The change is takeover-prone, so the server wants a recent proof of the
/// holder: when it asks (`stepUpRequired`), the password is asked for and the
/// same code is sent again — the viewer types nothing twice. The address on
/// file before is told by the server. Not optimistic: Account shows the new
/// address once the server has it, verified (the code proved it).
final class ChangeContactViewController: UIViewController {
    enum Phase: Equatable {
        case address
        case code(ContactChallenge)
    }

    private let kind: ContactKind
    private let current: String?
    private let changer: any ContactChanging
    private let stepUp: (any CredentialStepUp)?
    private let onChanged: (String) -> Void
    private(set) var phase: Phase = .address {
        didSet { render() }
    }
    private var isWorking = false {
        didSet { render() }
    }
    private var resendAvailableAt = Date()

    private let promptLabel = UILabel()
    private let addressField = UITextField()
    private let codeField = UITextField()
    private let footerLabel = UILabel()
    private lazy var resendButton = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in self?.resend() })
    private lazy var editAddressButton = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in
        self?.phase = .address
    })
    private var resendTimer: Timer?

    init(
        kind: ContactKind, current: String?, changer: any ContactChanging,
        stepUp: (any CredentialStepUp)?, onChanged: @escaping (String) -> Void
    ) {
        self.kind = kind
        self.current = current
        self.changer = changer
        self.stepUp = stepUp
        self.onChanged = onChanged
        super.init(nibName: nil, bundle: nil)
        title = kind == .email ? "Email" : "Phone"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Words

    static func addressPrompt(_ kind: ContactKind, current: String?) -> String {
        let noun = kind == .email ? "email address" : "phone number"
        guard let current, !current.isEmpty else { return "Enter your \(noun)." }
        return "Your \(noun) is \(current). Enter the new one."
    }

    static func addressFooter(_ kind: ContactKind) -> String {
        kind == .email
            ? "We'll send a code to the new address. You'll sign in with it, and your current address is told about the change."
            : "We'll text a code to the new number. Include the country code, like +33 or +1. Your current contact is told about the change."
    }

    static func codePrompt(_ challenge: ContactChallenge) -> String {
        "Enter the 6-digit code sent to \(challenge.destination)."
    }

    static func failureMessage(_ error: Error, kind: ContactKind) -> String {
        let noun = kind == .email ? "email address" : "phone number"
        switch error as? ContactChangeError {
        case .wrongCode: return "That code didn't work. Check it, or ask for a new one."
        case .addressTaken: return "This \(noun) belongs to another account."
        case .rateLimited: return "Too many codes for this \(noun). Wait a few minutes, then try again."
        case .unreachable: return kind == .email
            ? "We can't send a code to this address. Check it and try again."
            : "We can't text this number. Check it, including the country code."
        case .stepUpRequired: return "For your security, confirm it's you again, then try once more."
        default: return "Couldn't change your \(noun). Check your connection and try again."
        }
    }

    // MARK: - Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Send Code", style: .prominent, target: self, action: #selector(primaryTapped)
        )

        for label in [promptLabel, footerLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        promptLabel.font = .appFont(forTextStyle: .body)
        footerLabel.font = .appFont(forTextStyle: .footnote)
        footerLabel.textColor = .secondaryLabel

        configure(addressField)
        addressField.placeholder = kind == .email ? "you@example.com" : "+33 6 12 34 56 78"
        addressField.keyboardType = kind == .email ? .emailAddress : .phonePad
        addressField.textContentType = kind == .email ? .emailAddress : .telephoneNumber
        addressField.accessibilityLabel = kind == .email ? "New email address" : "New phone number"
        addressField.addAction(UIAction { [weak self] _ in self?.render() }, for: .editingChanged)

        configure(codeField)
        codeField.placeholder = "6-digit code"
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.textAlignment = .center
        codeField.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        codeField.accessibilityLabel = "Code"
        codeField.addAction(UIAction { [weak self] _ in self?.codeChanged() }, for: .editingChanged)

        editAddressButton.configuration?.title = kind == .email ? "Use a Different Address" : "Use a Different Number"

        let stack = UIStackView(arrangedSubviews: [promptLabel, addressField, codeField, footerLabel, resendButton, editAddressButton])
        stack.axis = .vertical
        stack.spacing = Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.lg),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            addressField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            codeField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activeField.becomeFirstResponder()
    }

    /// Leaving for good: the countdown has nothing left to update.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController == nil { resendTimer?.invalidate() }
    }

    private func configure(_ field: UITextField) {
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.font = .appFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
    }

    private var activeField: UITextField {
        if case .code = phase { return codeField }
        return addressField
    }

    private var address: String? {
        ContactAddress.normalized(addressField.text ?? "", kind: kind)
    }

    private var code: String {
        String((codeField.text ?? "").filter(\.isNumber).prefix(6))
    }

    private func render() {
        guard isViewLoaded else { return }
        switch phase {
        case .address:
            promptLabel.text = Self.addressPrompt(kind, current: current)
            footerLabel.text = Self.addressFooter(kind)
            addressField.isHidden = false
            codeField.isHidden = true
            resendButton.isHidden = true
            editAddressButton.isHidden = true
            navigationItem.rightBarButtonItem?.title = "Send Code"
            navigationItem.rightBarButtonItem?.isEnabled = address != nil && address != current && !isWorking
        case .code(let challenge):
            promptLabel.text = Self.codePrompt(challenge)
            footerLabel.text = nil
            addressField.isHidden = true
            codeField.isHidden = false
            resendButton.isHidden = false
            editAddressButton.isHidden = false
            navigationItem.rightBarButtonItem?.title = "Confirm"
            navigationItem.rightBarButtonItem?.isEnabled = code.count == 6 && !isWorking
            updateResend()
        }
        navigationItem.hidesBackButton = isWorking
        view.isUserInteractionEnabled = !isWorking
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch phase {
        case .address: sendCode()
        case .code(let challenge): confirm(challenge)
        }
    }

    private func codeChanged() {
        codeField.text = code
        render()
        if case .code(let challenge) = phase, code.count == 6 { confirm(challenge) }
    }

    private func sendCode() {
        guard let address, !isWorking else { return }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let challenge = try await changer.sendContactCode(kind, to: address)
                isWorking = false
                startResendCountdown(challenge.resendAfter)
                codeField.text = ""
                phase = .code(challenge)
                codeField.becomeFirstResponder()
            } catch {
                isWorking = false
                present(error)
            }
        }
    }

    private func resend() {
        guard case .code(let challenge) = phase, Date() >= resendAvailableAt, !isWorking else { return }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await changer.sendContactCode(kind, to: challenge.destination)
                isWorking = false
                startResendCountdown(fresh.resendAfter)
                phase = .code(fresh)
            } catch {
                isWorking = false
                present(error)
            }
        }
    }

    /// The change itself. A step-up the server asks for comes first, then the
    /// same code goes again.
    private func confirm(_ challenge: ContactChallenge) {
        guard code.count == 6, !isWorking else { return }
        let code = code
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let stored = try await changer.changeContact(challenge, code: code)
                isWorking = false
                onChanged(stored)
            } catch ContactChangeError.stepUpRequired {
                isWorking = false
                askForPassword(then: challenge)
            } catch {
                isWorking = false
                codeField.text = ""
                render()
                present(error)
            }
        }
    }

    private func askForPassword(then challenge: ContactChallenge) {
        guard let stepUp else { return present(ContactChangeError.stepUpRequired) }
        StepUpPrompt.present(
            on: self,
            message: kind == .email
                ? "To change your email address, enter your password."
                : "To change your phone number, enter your password.",
            actionTitle: "Continue",
            stepUp: stepUp,
            onVerified: { [weak self] in self?.confirm(challenge) },
            onFailure: { [weak self] error in self?.present(error) }
        )
    }

    private func startResendCountdown(_ delay: TimeInterval) {
        resendAvailableAt = Date().addingTimeInterval(delay)
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateResend() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    private func updateResend() {
        let remaining = Int(ceil(resendAvailableAt.timeIntervalSinceNow))
        resendButton.configuration?.title = remaining > 0 ? "Resend Code in \(remaining)s" : "Resend Code"
        resendButton.isEnabled = remaining <= 0
        if remaining <= 0 { resendTimer?.invalidate() }
    }

    private func present(_ error: Error) {
        let alert = UIAlertController(title: nil, message: Self.failureMessage(error, kind: kind), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
