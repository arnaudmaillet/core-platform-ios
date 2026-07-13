import DesignSystem
import UIKit

/// Password reset, in the flow's house anatomy: a 🔑 hero header, one card
/// with the account email, and a full-width send button. Reached from the
/// email screen's Forgot Password link. Dumb view: reports the normalized
/// identifier upward; the coordinator owns the (future) dispatch.
final class PasswordResetViewController: BottomAnchoredTableViewController {
    /// Fired with the normalized identifier when the user requests a link.
    var onSubmit: ((String) -> Void)?

    private let emailCell = TextFieldCell()
    private var hasAutofocused = false

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.title = "Send Reset Link"
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.submitTapped() }, for: .primaryActionTriggered)
        return button
    }()

    private lazy var sendCell: UITableViewCell = {
        let cell = UITableViewCell()
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        sendButton.constrain(in: cell.contentView) { parent in
            sendButton.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            sendButton.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            sendButton.topAnchor.constraint(equalTo: parent.topAnchor)
            sendButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        return cell
    }()

    #if DEBUG
    /// Sim QA hook: the identifier typed on appear, submitted ~1s later.
    var qaAutoSubmit: String?
    #endif

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let field = emailCell.textField
        field.placeholder = "Email"
        field.keyboardType = .emailAddress
        field.textContentType = .username
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.enablesReturnKeyAutomatically = true
        field.addAction(UIAction { [weak self] _ in self?.inputChanged() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.submitTapped() }, for: .editingDidEndOnExit)

        inputChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasAutofocused {
            hasAutofocused = true
            emailCell.textField.becomeFirstResponder()
        }
        #if DEBUG
        if let identifier = qaAutoSubmit {
            qaAutoSubmit = nil
            emailCell.textField.text = identifier
            inputChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.submitTapped()
            }
        }
        #endif
    }

    private var normalizedIdentifier: String? {
        EmailAddress.normalize(emailCell.textField.text ?? "")
    }

    private func inputChanged() {
        sendButton.isEnabled = normalizedIdentifier != nil
    }

    private func submitTapped() {
        guard let identifier = normalizedIdentifier else { return }
        onSubmit?(identifier)
    }

    // MARK: - Table

    private enum Section: Int, CaseIterable {
        case form
        case action
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .form: emailCell
        case .action: sendCell
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard Section(rawValue: section) == .form else { return nil }
        return makeHeroHeader(
            emoji: "\u{1F511}",
            title: "Password Reset",
            subtitle: "Enter your email and we\u{2019}ll send you a link to reset your password."
        )
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch Section(rawValue: section)! {
        case .form: UITableView.automaticDimension // the hero block
        case .action: Spacing.lg - Self.collapsedFooterHeight
        }
    }
}
