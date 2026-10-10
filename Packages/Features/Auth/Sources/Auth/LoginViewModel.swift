import Foundation

/// Narrow seam between the login screen and the session manager, so the
/// view model is testable without RPC plumbing.
public protocol LoginPerforming: Sendable {
    func login(username: String, password: String) async throws -> LoginOutcome
    /// The second step, with the authenticator's code or a backup code.
    func completeLogin(_ challenge: SecondStepChallenge, code: String) async throws
}

extension SessionManager: LoginPerforming {}

@MainActor
public final class LoginViewModel {
    public nonisolated enum State: Equatable, Sendable {
        case idle
        case submitting
        case failed(message: String)
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// The view's render hook. Navigation on success is NOT signalled here —
    /// the app coordinator observes `AuthSessionProviding.stateUpdates()`.
    public var onStateChange: ((State) -> Void)?
    /// The password was right and two-step sign-in is on (#383): the flow
    /// asks for the code.
    public var onSecondStep: ((SecondStepChallenge) -> Void)?

    private let loginService: any LoginPerforming
    private var submission: Task<Void, Never>?

    public init(loginService: any LoginPerforming) {
        self.loginService = loginService
    }

    public func submit(username: String, password: String) {
        guard state != .submitting else { return }

        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            state = .failed(message: "Enter your username and password.")
            return
        }

        state = .submitting
        submission = Task {
            do {
                let outcome = try await loginService.login(username: username, password: password)
                state = .idle
                if case .needsSecondStep(let challenge) = outcome { onSecondStep?(challenge) }
            } catch let error as AuthError {
                state = .failed(message: Self.message(for: error))
            } catch {
                state = .failed(message: "Something went wrong. Try again.")
            }
        }
    }

    static func message(for error: AuthError) -> String {
        switch error {
        case .invalidCredentials:
            "Incorrect username or password."
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
