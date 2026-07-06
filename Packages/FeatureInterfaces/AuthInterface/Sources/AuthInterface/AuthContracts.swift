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
}
