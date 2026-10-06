import DesignSystem
import UIKit

/// Two-step sign-in's second step (#383): the six digits from the holder's
/// authenticator app, or one of their backup codes. The credential before it
/// (password, emailed code, Apple) is already proven; this code finishes the
/// sign-in (`auth.v1.CompleteLogin`).
///
/// Six digits submit on the last one, like the emailed code. A backup code
/// (`xxxxx-xxxxx`) is typed in its own mode, behind "Use a Backup Code".
final class SecondStepViewController: SignUpStepViewController {
    enum Mode: Equatable {
        case authenticator, backupCode
    }

    var onSubmit: ((String) -> Void)?
    private(set) var mode: Mode = .authenticator
    private let codeCell = TextFieldCell()
    private lazy var switchCell = makeLinkCell(title: Self.switchTitle(for: .authenticator))

    init() {
        super.init(
            emoji: "\u{1F510}", title: "Two-Step Sign-In",
            subtitle: Self.subtitle, buttonTitle: "Continue"
        )
    }

    override func viewDidLoad() {
        let field = codeCell.textField
        field.textAlignment = .center
        field.autocorrectionType = .no
        field.accessibilityIdentifier = "signin.secondStep"
        field.addAction(UIAction { [weak self] _ in self?.codeChanged() }, for: .editingChanged)
        configureField(for: mode)
        rows = [codeCell]
        trailingRows = [switchCell]
        onTrailingRowSelected = { [weak self] _ in self?.toggleMode() }
        super.viewDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        codeCell.textField.becomeFirstResponder()
    }

    static let subtitle = "Enter the 6-digit code from your authenticator app, or one of your backup codes. A backup code works once."

    static func switchTitle(for mode: Mode) -> String {
        mode == .authenticator ? "Use a Backup Code" : "Use Your Authenticator App"
    }

    /// What the field holds, cleaned for its mode: digits for the app's code,
    /// letters and digits (with the dash put back) for a backup code.
    static func cleaned(_ text: String, mode: Mode) -> String {
        switch mode {
        case .authenticator:
            return String(text.filter(\.isNumber).prefix(6))
        case .backupCode:
            let characters = String(text.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(10))
            guard characters.count > 5 else { return characters }
            return String(characters.prefix(5)) + "-" + String(characters.dropFirst(5))
        }
    }

    static func isComplete(_ code: String, mode: Mode) -> Bool {
        switch mode {
        case .authenticator: code.count == 6
        case .backupCode: code.filter { $0 != "-" }.count == 10
        }
    }

    private var code: String { Self.cleaned(codeCell.textField.text ?? "", mode: mode) }

    override var canContinue: Bool { Self.isComplete(code, mode: mode) }

    private func codeChanged() {
        codeCell.textField.text = code
        refreshButton()
        // The app's six digits go on their own; a backup code waits for
        // Continue, so a typo can still be fixed.
        if mode == .authenticator, canContinue { primaryTapped() }
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

    private func toggleMode() {
        mode = mode == .authenticator ? .backupCode : .authenticator
        configureField(for: mode)
        codeCell.textField.text = ""
        if var content = switchCell.contentConfiguration as? UIListContentConfiguration {
            content.text = Self.switchTitle(for: mode)
            switchCell.contentConfiguration = content
        }
        refreshButton()
        codeCell.textField.reloadInputViews()
        codeCell.textField.becomeFirstResponder()
    }

    private func configureField(for mode: Mode) {
        let field = codeCell.textField
        switch mode {
        case .authenticator:
            field.placeholder = "6-digit code"
            field.keyboardType = .numberPad
            field.textContentType = .oneTimeCode
            field.autocapitalizationType = .none
        case .backupCode:
            field.placeholder = "xxxxx-xxxxx"
            field.keyboardType = .asciiCapable
            field.textContentType = nil
            field.autocapitalizationType = .none
        }
    }
}
