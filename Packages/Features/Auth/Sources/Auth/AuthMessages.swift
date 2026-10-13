import Foundation

/// The words for an auth failure, shown by the sign-in and sign-up steps.
/// (The password screen's view model that held them went with passwords,
/// #840.)
enum AuthMessages {
    static func message(for error: AuthError) -> String {
        switch error {
        case .invalidCredentials:
            "We couldn\u{2019}t sign you in. Try again."
        case .notAuthenticated, .sessionExpired:
            "Your session has expired. Sign in again."
        case .transport:
            "Can't reach the server. Check your connection and try again."
        case .offline:
            "You\u{2019}re offline. Check your connection and try again."
        case .invalidCode:
            "That code didn\u{2019}t work. Check it, or ask for a new one."
        case .underMinimumAge:
            "You\u{2019}re not old enough to create an account."
        case .identityRejected:
            "We couldn\u{2019}t confirm it\u{2019}s you. Try signing in again."
        case .wrongSecondStepCode:
            "That code didn\u{2019}t work. Check your authenticator app, or use a backup code."
        case .secondStepLocked:
            "Too many wrong codes. Wait a few minutes, then try again."
        case .secondStepExpired:
            "This sign-in timed out. Sign in again."
        }
    }
}
