import Connect
import CoreContracts
import CoreNetworking
import Foundation

/// Which address of the account changes.
public enum ContactKind: Equatable, Sendable {
    case email, phone
}

/// A code on its way to the NEW address (`auth.v1.StartVerification`).
public struct ContactChallenge: Equatable, Sendable {
    public let id: String
    public let kind: ContactKind
    /// The new address, as it was sent.
    public let destination: String
    /// A new code can be asked for after this long.
    public let resendAfter: TimeInterval

    public init(id: String, kind: ContactKind, destination: String, resendAfter: TimeInterval) {
        self.id = id
        self.kind = kind
        self.destination = destination
        self.resendAfter = resendAfter
    }
}

public enum ContactChangeError: Error, Equatable {
    /// The change needs a fresh step-up (PERMISSION_DENIED "step_up_required").
    case stepUpRequired
    /// The code is wrong, expired or used (AUT-5011).
    case wrongCode
    /// Another account already has this address (AUT-6006 / AUT-6007).
    case addressTaken
    /// Too many codes for this address (AUT-5013): wait, then ask again.
    case rateLimited
    /// Codes can't be sent there (AUT-5012), or the address was refused.
    case unreachable
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension ContactChangeError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// Settings → Account → Email / Phone (#393, backend #651): a code to the new
/// address, then the change, behind a recent step-up. The old address is told.
public protocol ContactChanging: Sendable {
    func sendContactCode(_ kind: ContactKind, to destination: String) async throws -> ContactChallenge
    /// Returns the address now on the account, as the server stored it.
    func changeContact(_ challenge: ContactChallenge, code: String) async throws -> String
}

/// An address as the change sends it: an email trimmed and lower-cased, a
/// phone number as `+` and digits. Nil when it can't be one.
public enum ContactAddress {
    public static func normalized(_ text: String, kind: ContactKind) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .email:
            let email = trimmed.lowercased()
            let parts = email.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
                  !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
                  !email.contains(where: \.isWhitespace), email.count <= 254
            else { return nil }
            return email
        case .phone:
            // International format: the country code is what makes the
            // number reachable by SMS from anywhere.
            guard trimmed.hasPrefix("+") else { return nil }
            let digits = trimmed.filter(\.isNumber)
            guard (8...15).contains(digits.count),
                  trimmed.dropFirst().allSatisfy({ $0.isNumber || " -().".contains($0) })
            else { return nil }
            return "+" + digits
        }
    }
}

extension AccountSessionsRepository: ContactChanging {
    public func sendContactCode(_ kind: ContactKind, to destination: String) async throws -> ContactChallenge {
        var request = Auth_V1_StartVerificationRequest()
        request.channel = kind == .email ? .email : .sms
        request.destination = destination
        request.locale = Locale.current.identifier(.bcp47)
        let response = await authClient.startVerification(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return ContactChallenge(
                id: body.challengeID, kind: kind, destination: destination,
                resendAfter: TimeInterval(body.resendAfterSecs)
            )
        case .failure(let error):
            throw Self.contactError(error)
        }
    }

    public func changeContact(_ challenge: ContactChallenge, code: String) async throws -> String {
        var request = Auth_V1_ChangeContactRequest()
        request.challengeID = challenge.id
        request.code = code
        request.locale = Locale.current.identifier(.bcp47)
        let response = await authClient.changeContact(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.destination.isEmpty ? challenge.destination : body.destination
        case .failure(let error):
            throw Self.contactError(error)
        }
    }

    static func contactError(_ error: ConnectError) -> ContactChangeError {
        let message = error.message ?? ""
        if error.code == .permissionDenied, message.contains("step_up_required") { return .stepUpRequired }
        if message.contains("AUT-6006") || message.contains("AUT-6007") || error.code == .alreadyExists { return .addressTaken }
        if message.contains("AUT-5013") || error.code == .resourceExhausted { return .rateLimited }
        if message.contains("AUT-5011") || error.code == .unauthenticated { return .wrongCode }
        if message.contains("AUT-5012") || error.code == .invalidArgument || error.code == .failedPrecondition { return .unreachable }
        return .transport(message: message.isEmpty ? "code \(error.code)" : message, failure: NetworkFailure(error))
    }
}
