import Foundation

/// What `MockAuthService` and `MockAccountService` both need to know about the
/// demo account, the way auth and account share it on the fleet:
///
/// - **step-up**: `VerifyCredentials` (auth) mints a fresh access token, and
///   step-up-gated account RPCs (`DeactivateAccount`) accept only a token
///   stepped up within the last `stepUpWindow` seconds;
/// - **deactivation**: `DeactivateAccount` (account) marks the account
///   deactivated, and the next `Login` (auth) resumes it and says so with
///   `LoginResponse.reactivated`;
/// - **erasure grace period** (backend #653): `RequestGdprDeletion` records
///   the request and deactivates the account; the next `Login` resumes it
///   and withdraws the request, as `CancelGdprDeletion` does.
///
/// - **two-step sign-in** (backend #649): auth enrols, disables and checks
///   the second factor; account reports it as `mfa_enrolled`.
///
/// `MockBackend` hands the same instance to both services.
public final class MockAccountLifecycle: @unchecked Sendable {
    /// How long a step-up proof is accepted, as the contract's
    /// `step_up_expires_in`.
    public static let stepUpWindow: TimeInterval = 300

    private let lock = NSLock()
    private var steppedUp: [String: Date] = [:]
    private var deactivated = false
    private var deletionRequested: Date?

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

    /// Resumes a deactivated account, withdrawing a pending deletion with it;
    /// true when it was deactivated.
    func resumeIfDeactivated() -> Bool {
        lock.withLock {
            defer {
                deactivated = false
                deletionRequested = nil
            }
            return deactivated
        }
    }

    /// Records an erasure request (the first one stands) and deactivates the
    /// account, as the backend does for an active account.
    func requestDeletion(at date: Date = Date()) {
        lock.withLock {
            if deletionRequested == nil { deletionRequested = date }
            deactivated = true
        }
    }

    /// Withdraws a pending erasure; false when none was pending.
    func cancelDeletion() -> Bool {
        lock.withLock {
            guard deletionRequested != nil else { return false }
            deletionRequested = nil
            return true
        }
    }

    var deletionRequestedAt: Date? { lock.withLock { deletionRequested } }

    public var isDeactivated: Bool { lock.withLock { deactivated } }

    // MARK: - Two-step sign-in (backend #649)

    /// The seed every mock enrolment hands out. The mock checks no real
    /// TOTP: the authenticator's code is `MockAuthService.verificationCode`.
    public static let authenticatorSecret = "JBSWY3DPEHPK3PXP"
    /// How long an enrolment waits for its first code, as the contract's
    /// `expires_in`.
    public static let enrollmentWindow: TimeInterval = 600

    private var twoStepOn = false
    private var enrollmentStarted: Date?
    private var backupCodes: Set<String> = []

    /// `twoStepOn`: the account starts with two-step sign-in on and a set of
    /// backup codes (`-mock-two-step`), so the sign-in's second step can be
    /// seen without enrolling first.
    public init(twoStepOn: Bool) {
        if twoStepOn {
            self.twoStepOn = true
            backupCodes = Set(Self.freshBackupCodes().map(Self.normalized))
        }
    }

    /// Two-step sign-in is on (`AccountView.mfa_enrolled`).
    public var isTwoStepOn: Bool { lock.withLock { twoStepOn } }

    /// Starts (or restarts) an enrolment; false when two-step is already on.
    func startEnrollment(at date: Date = Date()) -> Bool {
        lock.withLock {
            guard !twoStepOn else { return false }
            enrollmentStarted = date
            return true
        }
    }

    /// Turns two-step on and returns the backup codes, shown once; nil when
    /// no enrolment is waiting (never started, or expired).
    func confirmEnrollment(at date: Date = Date()) -> [String]? {
        lock.withLock {
            guard let started = enrollmentStarted, date.timeIntervalSince(started) <= Self.enrollmentWindow else {
                return nil
            }
            enrollmentStarted = nil
            twoStepOn = true
            let codes = Self.freshBackupCodes()
            backupCodes = Set(codes.map(Self.normalized))
            return codes
        }
    }

    /// Turns two-step off; false when it was off.
    func disableTwoStep() -> Bool {
        lock.withLock {
            guard twoStepOn else { return false }
            twoStepOn = false
            backupCodes = []
            return true
        }
    }

    /// A new set of backup codes (the old ones stop working); nil when
    /// two-step is off.
    func regenerateBackupCodes() -> [String]? {
        lock.withLock {
            guard twoStepOn else { return nil }
            let codes = Self.freshBackupCodes()
            backupCodes = Set(codes.map(Self.normalized))
            return codes
        }
    }

    /// Whether `code` proves the second factor: the authenticator's code, or
    /// an unused backup code (which it uses up). Case and the dash don't
    /// matter, as on the fleet.
    func acceptsSecondFactor(_ code: String) -> Bool {
        lock.withLock {
            guard twoStepOn else { return false }
            if code.trimmingCharacters(in: .whitespaces) == MockAuthService.verificationCode { return true }
            return backupCodes.remove(Self.normalized(code)) != nil
        }
    }

    private static func normalized(_ code: String) -> String {
        code.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Ten `xxxxx-xxxxx` codes.
    private static func freshBackupCodes() -> [String] {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return (0..<10).map { _ in
            let characters = (0..<10).map { _ in alphabet.randomElement()! }
            return String(characters[0..<5]) + "-" + String(characters[5..<10])
        }
    }
}
