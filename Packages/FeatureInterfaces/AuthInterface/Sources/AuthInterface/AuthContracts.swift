import CoreModels
import UIKit

/// The app-visible authentication state. Everything the shell needs to route;
/// nothing more (tokens never leave the auth feature).
public enum AuthState: Equatable, Sendable {
    case unauthenticated
    case authenticated(AccountID)
}

/// Read/observe/end the session. Implemented by the auth feature's
/// SessionManager; consumed by the app coordinator and, later, by features
/// that need to know who is signed in.
public protocol AuthSessionProviding: Sendable {
    func currentState() async -> AuthState
    /// Emits on every state transition, starting with the current state.
    func stateUpdates() async -> AsyncStream<AuthState>
    func logout() async
}

/// Entry point contract for the auth feature's UI.
@MainActor
public protocol AuthFeatureBuilding {
    /// The login screen. Authentication success is observed via
    /// `AuthSessionProviding.stateUpdates()`, not a callback, so every
    /// observer sees the same transition.
    func makeLoginViewController() -> UIViewController
    /// The same flow, presented over the app by a guest who chose to sign in,
    /// with `prompt` — the reason a gated action opened it — in its headline.
    /// It has no close button (#1811): the sheet's swipe is the way out, and
    /// the presenter hears it from the sheet's own disappearance. Success is
    /// still observed via `stateUpdates()`, and the presenter dismisses it then.
    func makeSignInViewController(prompt: String?) -> UIViewController
}

/// When the shell offers to create a passkey (#840).
public enum PasskeyOfferMoment: Equatable, Sendable {
    /// Right after a sign-up: the new token's `auth_time` is fresh, so
    /// registering needs no step-up.
    case signUp
    /// After a sign-in by code or Apple / Google: offered when the account
    /// has none, at most once in a while.
    case signIn
}

/// What a session tells the shell once, after it lands: each answer is
/// consumed by reading it. Implemented by the auth feature's SessionManager;
/// consumed by the app coordinator (#2375).
public protocol AuthSessionNotices: Sendable {
    /// True once after a login that reactivated a self-deactivated account
    /// (#385), so the shell welcomes the holder back exactly once.
    func consumeReactivationNotice() async -> Bool
    /// True once after a sign-up, so the shell asks the new member about
    /// notifications exactly once (#666). A sign-in never sets it.
    func consumeSignUpNotice() async -> Bool
    /// Once after a session landed, when to offer a passkey (#840); nil after
    /// a passkey sign-in, and from then on.
    func consumePasskeyOffer() async -> PasskeyOfferMoment?
}

/// A sign-in flow that sizes the sheet it is presented in (#563, #1811): the
/// method list as tall as its content, the form at full height. The auth
/// feature's navigation controller answers it; the shell asks it of the
/// controller `AuthFeatureBuilding` vends (#2375).
@MainActor
public protocol SheetContentFitting: AnyObject {
    /// Presents the flow in `sheet`; `fallback` serves while the flow has
    /// no height to give.
    func fit(_ sheet: UISheetPresentationController, fallback: CGFloat)
}
