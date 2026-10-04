import UIKit

/// Asks for the password before a destructive action, and runs the step-up
/// (`CredentialStepUp`, #648) with it: the server re-proves the holder and the
/// gated call that follows carries the fresh token.
///
/// One alert, a secure field typed as the account's password (so the
/// Passwords app can fill it), and the action's own verb on the button. A
/// wrong password asks again, saying so; Cancel ends the flow quietly.
@MainActor
enum StepUpPrompt {
    static func present(
        on host: UIViewController,
        title: String = "Enter Your Password",
        message: String,
        actionTitle: String,
        stepUp: any CredentialStepUp,
        retryMessage: String? = nil,
        onVerified: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        let alert = UIAlertController(title: title, message: retryMessage ?? message, preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.placeholder = "Password"
            field.accessibilityLabel = "Password"
        }
        let confirm = UIAlertAction(title: actionTitle, style: .destructive) { [weak alert] _ in
            let password = alert?.textFields?.first?.text ?? ""
            Task { @MainActor in
                do {
                    try await stepUp.stepUp(password: password)
                    onVerified()
                } catch StepUpError.wrongPassword {
                    present(
                        on: host, title: title, message: message, actionTitle: actionTitle, stepUp: stepUp,
                        retryMessage: "That password is incorrect. Try again.",
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
