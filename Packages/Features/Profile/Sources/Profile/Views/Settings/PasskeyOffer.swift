import AuthInterface
import DesignSystem
import UIKit

/// Offers a passkey once a session has landed (#840 — passkeys are
/// promoted, not required): right after a sign-up, and after a sign-in by
/// code or Apple / Google while the account has none — at most once every
/// `signInInterval`.
///
/// One alert, the action's own verb on the button; Not Now ends it. Accepted,
/// it runs Settings → Passkeys' own add (`PasskeysModel`), step-up included
/// when the server asks for one — after a sign-in it rarely does: the new
/// token's `auth_time` is fresh.
@MainActor
public enum PasskeyOffer {
    /// After a sign-in, an offer comes back no sooner than this.
    public static let signInInterval: TimeInterval = 30 * 86_400

    static let lastOfferedKey = "passkeyOffer.lastOffered"

    /// Whether a sign-in may offer again (a sign-up always does).
    static func isDue(afterSignUp: Bool, lastOffered: Date?, now: Date) -> Bool {
        guard !afterSignUp, let lastOffered else { return true }
        return now.timeIntervalSince(lastOffered) >= signInInterval
    }

    /// Offers a passkey over `host` when it is due. `afterSignUp` false: only
    /// when the account has none. Says nothing when the server has no
    /// passkeys. `completion` runs once the offer is settled (or skipped),
    /// so whatever comes next — the notifications question — waits for it.
    public static func presentIfDue(
        on host: @escaping () -> UIViewController?,
        afterSignUp: Bool,
        manager: any PasskeysManaging & CredentialStepUp,
        authorizer: any PasskeyAuthorizing,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        completion: @escaping () -> Void
    ) {
        let lastOffered = defaults.object(forKey: lastOfferedKey) as? Date
        guard isDue(afterSignUp: afterSignUp, lastOffered: lastOffered, now: now) else {
            completion()
            return
        }
        Task { @MainActor in
            let model = PasskeysModel(manager: manager, authorizer: authorizer)
            await model.load()
            guard case .loaded(let passkeys) = model.phase, afterSignUp || passkeys.isEmpty,
                  let screen = host()
            else {
                completion()
                return
            }
            defaults.set(now, forKey: lastOfferedKey)
            let alert = UIAlertController(
                title: "Sign In Faster With a Passkey",
                message: "Next time, confirm it\u{2019}s you with Face ID or Touch ID instead of waiting for a code. It\u{2019}s saved in your iCloud Keychain.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in completion() })
            alert.addAction(UIAlertAction(title: "Create Passkey", style: .default) { _ in
                create(model: model, stepUp: manager, on: host, completion: completion)
            })
            alert.preferredAction = alert.actions.last
            screen.present(alert, animated: true)
        }
    }

    private static func create(
        model: PasskeysModel,
        stepUp: any CredentialStepUp,
        on host: @escaping () -> UIViewController?,
        afterStepUp: Bool = false,
        completion: @escaping () -> Void
    ) {
        Task { @MainActor in
            let outcome = await model.add()
            guard let screen = host() else {
                completion()
                return
            }
            switch outcome {
            case .done:
                Feedback.success("Passkey created", from: screen)
                completion()
            case .cancelled:
                completion()
            case .needsStepUp where !afterStepUp:
                StepUpPrompt.present(
                    on: screen,
                    message: "To create a passkey, confirm it\u{2019}s you.",
                    actionTitle: "Continue",
                    stepUp: stepUp,
                    onVerified: { create(model: model, stepUp: stepUp, on: host, afterStepUp: true, completion: completion) },
                    onFailure: { _ in completion() },
                    onCancel: completion
                )
            case .needsStepUp:
                completion()
            case .failed(let message):
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
                screen.present(alert, animated: true)
            }
        }
    }
}
