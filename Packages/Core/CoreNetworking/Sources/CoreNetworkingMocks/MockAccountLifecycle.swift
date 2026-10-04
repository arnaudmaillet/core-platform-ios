import Foundation

/// What `MockAuthService` and `MockAccountService` both need to know about the
/// demo account, the way auth and account share it on the fleet:
///
/// - **step-up**: `VerifyCredentials` (auth) mints a fresh access token, and
///   step-up-gated account RPCs (`DeactivateAccount`) accept only a token
///   stepped up within the last `stepUpWindow` seconds;
/// - **deactivation**: `DeactivateAccount` (account) marks the account
///   deactivated, and the next `Login` (auth) resumes it and says so with
///   `LoginResponse.reactivated`.
///
/// `MockBackend` hands the same instance to both services.
public final class MockAccountLifecycle: @unchecked Sendable {
    /// How long a step-up proof is accepted, as the contract's
    /// `step_up_expires_in`.
    public static let stepUpWindow: TimeInterval = 300

    private let lock = NSLock()
    private var steppedUp: [String: Date] = [:]
    private var deactivated = false

    public init() {}

    func recordStepUp(accessToken: String, at date: Date = Date()) {
        lock.withLock { steppedUp[accessToken] = date }
    }

    func isSteppedUp(accessToken: String, now: Date = Date()) -> Bool {
        lock.withLock {
            guard let at = steppedUp[accessToken] else { return false }
            return now.timeIntervalSince(at) <= Self.stepUpWindow
        }
    }

    func deactivate() {
        lock.withLock { deactivated = true }
    }

    /// Resumes a deactivated account; true when it was deactivated.
    func resumeIfDeactivated() -> Bool {
        lock.withLock {
            defer { deactivated = false }
            return deactivated
        }
    }

    public var isDeactivated: Bool { lock.withLock { deactivated } }
}
