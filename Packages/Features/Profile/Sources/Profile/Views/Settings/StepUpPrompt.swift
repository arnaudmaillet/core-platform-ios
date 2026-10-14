import UIKit

/// Proves the holder again before a destructive action, and runs the step-up
/// (`CredentialStepUp`, #648) with it: the gated call that follows carries
/// the fresh proof.
///
/// There is no password any more (#840). The default, `.signInAgain`, sends
/// a code to the account's address, signs in again with it — a sign-in's
/// token is the proof the server accepts — and asks for the authenticator's
/// code too when two-step sign-in is on. `.code` (the two-step screens) asks
/// for the authenticator's code or a backup code alone.
///
/// Alerts with the action's own verb on the button. A wrong code asks again,
/// saying so; Cancel ends the flow quietly (`onCancel`, for a caller that
/// waits on the flow's end).
@MainActor
enum StepUpPrompt {
    enum Credential {
        case signInAgain, code

        var defaultTitle: String {
            self == .signInAgain ? "Confirm It\u{2019}s You" : "Enter a Code"
        }
    }

    static let wrongCodeMessage = "That code didn\u{2019}t work. Check it and try again."
    static let wrongSecondStepMessage = "That code didn\u{2019}t work. Check your authenticator app, or use a backup code."

    static func present(
        on host: UIViewController,
        title: String? = nil,
        message: String,
        actionTitle: String,
        stepUp: any CredentialStepUp,
        credential: Credential = .signInAgain,
        retryMessage: String? = nil,
        onVerified: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        switch credential {
        case .code:
            askForSecondStep(
                on: host, title: title ?? credential.defaultTitle, message: retryMessage ?? message,
                actionTitle: actionTitle, verify: { try await stepUp.stepUp(code: $0) },
                onVerified: onVerified, onFailure: onFailure, onCancel: onCancel
            )
        case .signInAgain:
            Task { @MainActor in
                do {
                    let reconfirmation = try await stepUp.sendReconfirmationCode()
                    askForSentCode(
                        reconfirmation, on: host, title: title ?? credential.defaultTitle, message: message,
                        actionTitle: actionTitle, stepUp: stepUp, onVerified: onVerified, onFailure: onFailure, onCancel: onCancel
                    )
                } catch {
                    onFailure(error)
                }
            }
        }
    }

    /// The code sent to the account's address.
    private static func askForSentCode(
        _ reconfirmation: Reconfirmation,
        on host: UIViewController,
        title: String,
        message: String,
        actionTitle: String,
        stepUp: any CredentialStepUp,
        retry: Bool = false,
        onVerified: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        let sentTo = "We sent a code to \(reconfirmation.destination)."
        let alert = codeAlert(
            title: title,
            message: retry ? "\(wrongCodeMessage)\n\(sentTo)" : "\(message)\n\(sentTo)",
            placeholder: "6-digit code", accessibilityLabel: "Code"
        )
        addActions(to: alert, actionTitle: actionTitle, onCancel: onCancel) { code in
            Task { @MainActor in
                do {
                    switch try await stepUp.reconfirm(reconfirmation, code: code) {
                    case .done:
                        onVerified()
                    case .needsSecondStep:
                        askForSecondStep(
                            on: host, title: Credential.code.defaultTitle,
                            message: "Two-step sign-in is on: enter the code from your authenticator app, or a backup code.",
                            actionTitle: actionTitle, verify: { try await stepUp.completeReconfirmation(secondStepCode: $0) },
                            onVerified: onVerified, onFailure: onFailure, onCancel: onCancel
                        )
                    }
                } catch StepUpError.wrongCode {
                    askForSentCode(
                        reconfirmation, on: host, title: title, message: message, actionTitle: actionTitle,
                        stepUp: stepUp, retry: true, onVerified: onVerified, onFailure: onFailure, onCancel: onCancel
                    )
                } catch {
                    onFailure(error)
                }
            }
        }
        host.present(alert, animated: true)
    }

    /// The authenticator's code or a backup code.
    private static func askForSecondStep(
        on host: UIViewController,
        title: String,
        message: String,
        actionTitle: String,
        verify: @escaping @MainActor (String) async throws -> Void,
        onVerified: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        let alert = codeAlert(
            title: title, message: message,
            placeholder: "6-digit code or backup code", accessibilityLabel: "Two-step code"
        )
        addActions(to: alert, actionTitle: actionTitle, onCancel: onCancel) { code in
            Task { @MainActor in
                do {
                    try await verify(code)
                    onVerified()
                } catch StepUpError.wrongCode {
                    askForSecondStep(
                        on: host, title: title, message: wrongSecondStepMessage, actionTitle: actionTitle,
                        verify: verify, onVerified: onVerified, onFailure: onFailure, onCancel: onCancel
                    )
                } catch {
                    onFailure(error)
                }
            }
        }
        host.present(alert, animated: true)
    }

    private static func codeAlert(title: String, message: String, placeholder: String, accessibilityLabel: String) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.textContentType = .oneTimeCode
            field.keyboardType = .asciiCapable
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.placeholder = placeholder
            field.accessibilityLabel = accessibilityLabel
        }
        return alert
    }

    private static func addActions(
        to alert: UIAlertController, actionTitle: String, onCancel: (() -> Void)?, submit: @escaping (String) -> Void
    ) {
        let confirm = UIAlertAction(title: actionTitle, style: .destructive) { [weak alert] _ in
            submit(alert?.textFields?.first?.text ?? "")
        }
        confirm.isEnabled = false
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in onCancel?() })
        alert.addAction(confirm)
        if let field = alert.textFields?.first {
            field.addAction(UIAction { [weak field, weak confirm] _ in
                confirm?.isEnabled = !(field?.text ?? "").isEmpty
            }, for: .editingChanged)
        }
    }
}
