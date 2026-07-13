import DesignSystem
import UIKit

/// Screen 2 of the sign-in flow: email + password, Telegram-style — a ✉️
/// hero header, one combined credentials card (email over password with its
/// secure toggle), a full-width Sign In button, and the Forgot Password
/// link. Renders `LoginViewModel` state: button spinner while submitting,
/// alert + error haptic on failure.
final class CredentialsAuthViewController: BottomAnchoredTableViewController {
    var onForgotPassword: (() -> Void)?

    private let viewModel: LoginViewModel
    private let emailCell = TextFieldCell()
    private let passwordCell = TextFieldCell()
    private let feedback = UINotificationFeedbackGenerator()
    private var hasAutofocused = false

    private lazy var signInButton: UIButton = {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.title = "Sign In"
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.signInTapped() }, for: .primaryActionTriggered)
        return button
    }()

    private lazy var signInCell: UITableViewCell = {
        let cell = UITableViewCell()
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        signInButton.constrain(in: cell.contentView) { parent in
            signInButton.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            signInButton.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            signInButton.topAnchor.constraint(equalTo: parent.topAnchor)
            signInButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        return cell
    }()

    private lazy var forgotPasswordCell = makeLinkCell(title: "Forgot Password?")

    #if DEBUG
    /// Sim QA hook: when set, both fields are typed on appear and the form
    /// submits ~1s later.
    var qaAutoSubmit: (identifier: String, password: String)?
    #endif

    init(viewModel: LoginViewModel) {
        self.viewModel = viewModel
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let email = emailCell.textField
        email.placeholder = "Email"
        email.keyboardType = .emailAddress
        email.textContentType = .username
        email.autocapitalizationType = .none
        email.autocorrectionType = .no
        email.returnKeyType = .next
        email.enablesReturnKeyAutomatically = true
        email.addAction(UIAction { [weak self] _ in self?.inputChanged() }, for: .editingChanged)
        email.addAction(
            UIAction { [weak self] _ in self?.passwordCell.textField.becomeFirstResponder() },
            for: .editingDidEndOnExit
        )

        let password = passwordCell.textField
        password.placeholder = "Password"
        password.textContentType = .password
        password.autocapitalizationType = .none
        password.autocorrectionType = .no
        password.returnKeyType = .go
        password.enablesReturnKeyAutomatically = true
        password.enableSecureEntryReveal()
        password.addAction(UIAction { [weak self] _ in self?.inputChanged() }, for: .editingChanged)
        password.addAction(UIAction { [weak self] _ in self?.signInTapped() }, for: .editingDidEndOnExit)

        inputChanged()
        viewModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasAutofocused {
            hasAutofocused = true
            emailCell.textField.becomeFirstResponder()
        }
        #if DEBUG
        if let qa = qaAutoSubmit {
            qaAutoSubmit = nil
            emailCell.textField.text = qa.identifier
            passwordCell.textField.text = qa.password
            inputChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.signInTapped()
            }
        }
        #endif
    }

    private var normalizedIdentifier: String? {
        EmailAddress.normalize(emailCell.textField.text ?? "")
    }

    private func inputChanged() {
        signInButton.isEnabled = normalizedIdentifier != nil
            && !(passwordCell.textField.text ?? "").isEmpty
    }

    private func signInTapped() {
        guard signInButton.isEnabled, let identifier = normalizedIdentifier else { return }
        feedback.prepare()
        viewModel.submit(username: identifier, password: passwordCell.textField.text ?? "")
    }

    private func render(_ state: LoginViewModel.State) {
        switch state {
        case .idle:
            setSubmitting(false)
        case .submitting:
            setSubmitting(true)
        case .failed(let message):
            setSubmitting(false)
            feedback.notificationOccurred(.error)
            presentError(message)
        }
    }

    private func setSubmitting(_ submitting: Bool) {
        signInButton.configuration?.showsActivityIndicator = submitting
        navigationItem.hidesBackButton = submitting
        emailCell.textField.isEnabled = !submitting
        passwordCell.textField.isEnabled = !submitting
        if submitting {
            signInButton.isEnabled = false
            view.endEditing(true)
        } else {
            inputChanged()
        }
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Cannot Sign In", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.passwordCell.textField.becomeFirstResponder()
        })
        present(alert, animated: true)
    }

    // MARK: - Table

    private enum Section: Int, CaseIterable {
        case credentials
        case action
        case forgotPassword
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .credentials: 2
        case .action, .forgotPassword: 1
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .credentials:
            return indexPath.row == 0 ? emailCell : passwordCell
        case .action:
            return signInCell
        case .forgotPassword:
            return forgotPasswordCell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .forgotPassword else { return }
        onForgotPassword?()
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard Section(rawValue: section) == .credentials else { return nil }
        return makeHeroHeader(
            emoji: "\u{2709}\u{FE0F}",
            title: "Your Email",
            subtitle: "Please enter your email and password."
        )
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch Section(rawValue: section)! {
        case .credentials: UITableView.automaticDimension // the hero block
        case .action: Spacing.lg - Self.collapsedFooterHeight
        case .forgotPassword: Spacing.md - Self.collapsedFooterHeight
        }
    }
}
