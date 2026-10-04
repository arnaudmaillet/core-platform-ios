import DesignSystem
import UIKit

/// Settings → Security and Login → Change Password (#382).
///
/// The current password, the new one twice, and whether to log the other
/// devices out (on by default: changing a password is often what someone does
/// when they think another person knows it). The fields are typed as iOS
/// password fields, so the Passwords app can offer a strong one and save it.
final class ChangePasswordViewController: UIViewController {
    /// What the form says about what was typed, before anything is sent.
    enum Check: Equatable {
        case incomplete
        case tooShort
        case tooLong
        case mismatch
        case unchanged
        case ready

        static let minimumLength = 8
        static let maximumLength = 128

        init(current: String, new: String, confirmation: String) {
            if current.isEmpty || new.isEmpty {
                self = .incomplete
            } else if new.count < Self.minimumLength {
                self = .tooShort
            } else if new.count > Self.maximumLength {
                self = .tooLong
            } else if new == current {
                self = .unchanged
            } else if confirmation != new {
                self = confirmation.isEmpty ? .incomplete : .mismatch
            } else {
                self = .ready
            }
        }

        /// The line under the new password; nil while there is nothing to say.
        var message: String? {
            switch self {
            case .incomplete, .ready: nil
            case .tooShort: "Use at least \(Self.minimumLength) characters."
            case .tooLong: "Use at most \(Self.maximumLength) characters."
            case .mismatch: "The two new passwords don't match."
            case .unchanged: "The new password must be different from the current one."
            }
        }
    }

    private enum Row: Int, CaseIterable {
        case current, new, confirmation, signOutOthers
    }

    private let changer: any AccountPasswordChanging
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let currentField = ChangePasswordViewController.makeField(placeholder: "Current password", content: .password)
    private let newField = ChangePasswordViewController.makeField(placeholder: "New password", content: .newPassword)
    private let confirmationField = ChangePasswordViewController.makeField(placeholder: "Confirm new password", content: .newPassword)
    private let signOutSwitch = UISwitch()
    private var isSaving = false

    init(changer: any AccountPasswordChanging) {
        self.changer = changer
        super.init(nibName: nil, bundle: nil)
        title = "Change Password"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .prominent, target: self, action: #selector(save)
        )
        signOutSwitch.isOn = true

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .interactive
        tableView.prefersSoftTopEdge()
        view.addSubview(tableView)

        for field in [currentField, newField, confirmationField] {
            field.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .editingChanged)
            field.delegate = self
        }
        // The IdP's floor, said to the Passwords app so a suggestion passes.
        newField.passwordRules = UITextInputPasswordRules(descriptor: "minlength: 8; maxlength: 128;")
        confirmationField.passwordRules = newField.passwordRules
        currentField.returnKeyType = .next
        newField.returnKeyType = .next
        confirmationField.returnKeyType = .done
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if currentField.text?.isEmpty != false { currentField.becomeFirstResponder() }
    }

    private var check: Check {
        Check(current: currentField.text ?? "", new: newField.text ?? "", confirmation: confirmationField.text ?? "")
    }

    private func refresh() {
        navigationItem.rightBarButtonItem?.isEnabled = check == .ready && !isSaving
        // Only the new-password section's footer depends on the typing.
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            if let footer = tableView.footerView(forSection: 1) {
                var content = UIListContentConfiguration.groupedFooter()
                content.text = footerText(section: 1)
                content.textProperties.color = check.message == nil ? .secondaryLabel : .systemRed
                footer.contentConfiguration = content
            }
            tableView.endUpdates()
        }
    }

    // MARK: - Save

    @objc private func save() {
        guard check == .ready, !isSaving else { return }
        isSaving = true
        view.endEditing(true)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        let current = currentField.text ?? ""
        let new = newField.text ?? ""
        let signOutOthers = signOutSwitch.isOn
        Task { [weak self] in
            guard let self else { return }
            do {
                let revoked = try await changer.changePassword(
                    current: current, new: new, signOutOtherSessions: signOutOthers
                )
                HapticNotification().notificationOccurred(.success)
                finishSaving()
                presentDone(revokedSessions: revoked)
            } catch {
                HapticNotification().notificationOccurred(.error)
                finishSaving()
                presentFailure(error)
            }
        }
    }

    private func finishSaving() {
        isSaving = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .prominent, target: self, action: #selector(save)
        )
        refresh()
    }

    static func doneMessage(revokedSessions: Int) -> String {
        switch revokedSessions {
        case 0: "Use your new password the next time you log in."
        case 1: "1 other device was logged out. Use your new password the next time you log in."
        default: "\(revokedSessions) other devices were logged out. Use your new password the next time you log in."
        }
    }

    private func presentDone(revokedSessions: Int) {
        let alert = UIAlertController(
            title: "Password Changed", message: Self.doneMessage(revokedSessions: revokedSessions), preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    private func presentFailure(_ error: Error) {
        let title: String
        let message: String?
        var focus: UITextField?
        switch error as? PasswordChangeError {
        case .wrongCurrentPassword:
            title = "Current Password Is Incorrect"
            message = "Check it and try again."
            currentField.text = ""
            focus = currentField
        case .rejected(let reason):
            title = "Choose Another Password"
            message = reason
            focus = newField
        default:
            title = "Couldn't Change Your Password"
            message = "Check your connection and try again."
        }
        refresh()
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in focus?.becomeFirstResponder() })
        present(alert, animated: true)
    }

    // MARK: - Fields

    private static func makeField(placeholder: String, content: UITextContentType) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.isSecureTextEntry = true
        field.textContentType = content
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.font = .appFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = placeholder
        return field
    }

    fileprivate func footerText(section: Int) -> String? {
        switch section {
        case 1: check.message ?? "At least 8 characters. A long phrase is easier to remember and harder to guess."
        case 2: "Recommended if you think someone else knows your password. This device stays logged in."
        default: nil
        }
    }
}

// MARK: - Table

extension ChangePasswordViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 3 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 1 ? 2 : 1
    }

    private func row(at indexPath: IndexPath) -> Row {
        switch (indexPath.section, indexPath.row) {
        case (0, _): .current
        case (1, 0): .new
        case (1, _): .confirmation
        default: .signOutOthers
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch row(at: indexPath) {
        case .current: install(currentField, in: cell)
        case .new: install(newField, in: cell)
        case .confirmation: install(confirmationField, in: cell)
        case .signOutOthers:
            var content = cell.defaultContentConfiguration()
            content.text = "Log Out of Other Devices"
            cell.contentConfiguration = content
            cell.accessoryView = signOutSwitch
        }
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Current Password" : section == 1 ? "New Password" : nil
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let text = footerText(section: section) else { return nil }
        let footer = UITableViewHeaderFooterView()
        var content = UIListContentConfiguration.groupedFooter()
        content.text = text
        content.textProperties.color = section == 1 && check.message != nil ? .systemRed : .secondaryLabel
        footer.contentConfiguration = content
        return footer
    }

    private func install(_ field: UITextField, in cell: UITableViewCell) {
        field.removeFromSuperview()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }
}

extension ChangePasswordViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case currentField: newField.becomeFirstResponder()
        case newField: confirmationField.becomeFirstResponder()
        default:
            if check == .ready { save() } else { textField.resignFirstResponder() }
        }
        return true
    }
}
