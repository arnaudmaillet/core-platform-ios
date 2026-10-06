import UIKit

/// Asks for the password before a destructive action, and runs the step-up
/// (`CredentialStepUp`, #648) with it: the server re-proves the holder and the
/// gated call that follows carries the fresh token.
///
/// One alert, a secure field typed as the account's password (so the
/// Passwords app can fill it), and the action's own verb on the button. A
/// wrong password asks again, saying so; Cancel ends the flow quietly.
///
/// With two-step sign-in on (#383), `.code` asks for the authenticator's code
/// or a backup code instead: it proves the holder too, and it is the only
/// proof an account without a password has.
@MainActor
enum StepUpPrompt {
    enum Credential {
        case password, code

        var defaultTitle: String {
            self == .password ? "Enter Your Password" : "Enter a Code"
        }

        var retryMessage: String {
            self == .password
                ? "That password is incorrect. Try again."
                : "That code didn\u{2019}t work. Check your authenticator app, or use a backup code."
        }
    }

    static func present(
        on host: UIViewController,
        title: String? = nil,
        message: String,
        actionTitle: String,
        stepUp: any CredentialStepUp,
        credential: Credential = .password,
        retryMessage: String? = nil,
        onVerified: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        let alert = UIAlertController(title: title ?? credential.defaultTitle, message: retryMessage ?? message, preferredStyle: .alert)
        alert.addTextField { field in
            switch credential {
            case .password:
                field.isSecureTextEntry = true
                field.textContentType = .password
                field.placeholder = "Password"
                field.accessibilityLabel = "Password"
            case .code:
                field.textContentType = .oneTimeCode
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.placeholder = "6-digit code or backup code"
                field.accessibilityLabel = "Two-step code"
            }
        }
        let confirm = UIAlertAction(title: actionTitle, style: .destructive) { [weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            Task { @MainActor in
                do {
                    switch credential {
                    case .password: try await stepUp.stepUp(password: text)
                    case .code: try await stepUp.stepUp(code: text)
                    }
                    onVerified()
                } catch StepUpError.wrongPassword, StepUpError.wrongCode {
                    present(
                        on: host, title: title, message: message, actionTitle: actionTitle, stepUp: stepUp,
                        credential: credential, retryMessage: credential.retryMessage,
                        onVerified: onVerified, onFailure: onFailure
                    )
                } catch {
                    onFailure(error)
                }
            }
        }
        confirm.isEnabled = false
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(confirm)
        if let field = alert.textFields?.first {
            field.addAction(UIAction { [weak field, weak confirm] _ in
                confirm?.isEnabled = !(field?.text ?? "").isEmpty
            }, for: .editingChanged)
        }
        host.present(alert, animated: true)
    }
}
