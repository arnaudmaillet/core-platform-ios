import Connect
import CoreContracts
import Foundation

/// A two-step enrolment waiting for its first code (`StartMfaEnrollment`).
public struct TwoStepEnrollment: Equatable, Sendable {
    /// The seed in base32, to type into an authenticator app.
    public let secret: String
    /// `otpauth://totp/…`, for the QR code (and to open an authenticator app).
    public let otpauthURI: String
    /// How long the enrolment waits for its first code.
    public let expiresIn: TimeInterval

    public init(secret: String, otpauthURI: String, expiresIn: TimeInterval) {
        self.secret = secret
        self.otpauthURI = otpauthURI
        self.expiresIn = expiresIn
    }

    /// The secret in groups of four, as people copy it by hand.
    public var groupedSecret: String {
        stride(from: 0, to: secret.count, by: 4).map { offset in
            let start = secret.index(secret.startIndex, offsetBy: offset)
            let end = secret.index(start, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex
            return String(secret[start..<end])
        }.joined(separator: " ")
    }
}

/// One-time backup codes: shown once, never again.
public struct BackupCodes: Equatable, Sendable {
    public let codes: [String]
    /// The account's other sessions, signed out by the change.
    public let sessionsSignedOut: Int

    public init(codes: [String], sessionsSignedOut: Int) {
        self.codes = codes
        self.sessionsSignedOut = sessionsSignedOut
    }
}

public enum TwoStepError: Error, Equatable {
    /// The action needs a fresh step-up first (PERMISSION_DENIED
    /// "step_up_required").
    case stepUpRequired
    /// The code didn't match (AUT-5017).
    case wrongCode
    /// No enrolment is waiting — it expired, or never started (AUT-5021).
    case enrollmentExpired
    /// Already on (AUT-5022) or already off (AUT-5020): the screen is stale.
    case alreadyChanged
    case transport(message: String)
}

/// Settings → Security and Login → Two-Step Sign-In (#383, backend #649).
/// Every change but confirming needs a recent step-up (`CredentialStepUp`).
public protocol TwoStepManaging: Sendable {
    func startTwoStepEnrollment() async throws -> TwoStepEnrollment
    /// The first code from the app turns two-step on and returns the backup
    /// codes; the account's other sessions are signed out.
    func confirmTwoStepEnrollment(code: String) async throws -> BackupCodes
    func disableTwoStep() async throws
    /// A new set (the old one stops working); the other sessions are signed out.
    func regenerateBackupCodes() async throws -> BackupCodes
}

extension AccountSessionsRepository: TwoStepManaging {
    public func startTwoStepEnrollment() async throws -> TwoStepEnrollment {
        let response = await authClient.startMfaEnrollment(request: Auth_V1_StartMfaEnrollmentRequest(), headers: [:])
        switch response.result {
        case .success(let body):
            return TwoStepEnrollment(secret: body.secret, otpauthURI: body.otpauthUri, expiresIn: TimeInterval(body.expiresIn))
        case .failure(let error):
            throw Self.twoStepError(error)
        }
    }

    public func confirmTwoStepEnrollment(code: String) async throws -> BackupCodes {
        var request = Auth_V1_ConfirmMfaEnrollmentRequest()
        request.code = code
        let response = await authClient.confirmMfaEnrollment(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return BackupCodes(codes: body.backupCodes, sessionsSignedOut: Int(body.sessionsRevoked))
        case .failure(let error):
            throw Self.twoStepError(error)
        }
    }

    public func disableTwoStep() async throws {
        let response = await authClient.disableMfa(request: Auth_V1_DisableMfaRequest(), headers: [:])
        if case .failure(let error) = response.result { throw Self.twoStepError(error) }
    }

    public func regenerateBackupCodes() async throws -> BackupCodes {
        let response = await authClient.regenerateBackupCodes(request: Auth_V1_RegenerateBackupCodesRequest(), headers: [:])
        switch response.result {
        case .success(let body):
            return BackupCodes(codes: body.backupCodes, sessionsSignedOut: Int(body.sessionsRevoked))
        case .failure(let error):
            throw Self.twoStepError(error)
        }
    }

    static func twoStepError(_ error: ConnectError) -> TwoStepError {
        let message = error.message ?? ""
        if error.code == .permissionDenied, message.contains("step_up_required") { return .stepUpRequired }
        if message.contains("AUT-5021") { return .enrollmentExpired }
        if message.contains("AUT-5017") { return .wrongCode }
        if message.contains("AUT-5020") || message.contains("AUT-5022") { return .alreadyChanged }
        return .transport(message: message.isEmpty ? "code \(error.code)" : message)
    }
}
