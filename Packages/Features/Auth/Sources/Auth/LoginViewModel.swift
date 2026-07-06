import Foundation

/// Narrow seam between the login screen and the session manager, so the
/// view model is testable without RPC plumbing.
public protocol LoginPerforming: Sendable {
    func login(username: String, password: String) async throws
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
                try await loginService.login(username: username, password: password)
                state = .idle
            } catch let error as AuthError {
                state = .failed(message: Self.message(for: error))
            } catch {
                state = .failed(message: "Something went wrong. Try again.")
            }
        }
    }

    private static func message(for error: AuthError) -> String {
        switch error {
        case .invalidCredentials:
            "Incorrect username or password."
        case .notAuthenticated, .sessionExpired:
            "Your session has expired. Sign in again."
        case .transport:
            "Can't reach the server. Check your connection and try again."
        }
    }
}
