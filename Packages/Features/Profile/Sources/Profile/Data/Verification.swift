import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// What a verified badge says about a profile (#415, backend #668).
public enum VerificationCategory: Equatable, Sendable, CaseIterable {
    case official, notable, business

    public var title: String {
        switch self {
        case .official: "Official"
        case .notable: "Notable Person"
        case .business: "Business"
        }
    }

    public var detail: String {
        switch self {
        case .official: "A government body, an organisation or its official representative."
        case .notable: "A public figure, artist, creator or journalist covered by independent media."
        case .business: "A registered company, brand or shop."
        }
    }

    init?(_ proto: Profile_V1_VerificationKind) {
        switch proto {
        case .official: self = .official
        case .notable: self = .notable
        case .business: self = .business
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Profile_V1_VerificationKind {
        switch self {
        case .official: .official
        case .notable: .notable
        case .business: .business
        }
    }
}

/// Where the active profile stands with its badge.
public enum VerificationStatus: Equatable, Sendable {
    /// Never asked, or nothing on record.
    case notRequested
    /// Asked; waiting for a decision.
    case pending(VerificationCategory?, submittedAt: Date)
    /// The last request was turned down, and why. The profile may ask again.
    case rejected(reason: String, decidedAt: Date?)
    /// The profile carries the badge.
    case verified(VerificationCategory?)

    /// Whether the profile can send a new request.
    public var canRequest: Bool {
        switch self {
        case .notRequested, .rejected: true
        case .pending, .verified: false
        }
    }
}

public enum VerificationError: Error, Equatable {
    /// PRF-5001: the profile is already verified.
    case alreadyVerified
    /// PRF-5002: a request is already waiting for a decision.
    case alreadyPending
    /// The server refused the request as sent (category, or 1–5 links).
    case invalid(message: String)
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension VerificationError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// A supporting link for a verification request: an official website, news
/// coverage, a business registry entry.
///
/// Links rather than uploaded identity documents, deliberately: profile.v1
/// takes the documents as opaque keys of up to 512 characters, and
/// media.v1 has no private kind to upload an ID into — every kind it has is
/// served publicly. See the PR for #415, part 2.
public enum VerificationLink {
    public static let maximumCount = 5
    public static let maximumLength = 512

    /// The link as it will be sent: trimmed, `https://` added when no scheme
    /// was typed, and nil unless it is a web address with a host.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard candidate.count <= maximumLength,
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return candidate
    }
}

/// Edit Profile → Account Type → Verification, for the active profile.
public protocol VerificationRequesting: Sendable {
    func verificationStatus() async throws -> VerificationStatus
    /// `links`: 1 to 5, already normalized (`VerificationLink.normalized`).
    func requestVerification(_ category: VerificationCategory, links: [String]) async throws
}

extension ProfileRepository: VerificationRequesting {
    public func verificationStatus() async throws -> VerificationStatus {
        let profileID = try await resolveViewerProfileID()
        // The badge itself is on the profile; the request is a separate record.
        let view = try await fetchProfileView(id: profileID)
        if view.verified { return .verified(VerificationCategory(view.verificationKind)) }

        var request = Profile_V1_GetVerificationRequestRequest()
        request.profileID = profileID.rawValue
        let response = await profileClient.getVerificationRequest(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return Self.status(of: body)
        case .failure(let error):
            throw VerificationError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    static func status(of response: Profile_V1_GetVerificationRequestResponse) -> VerificationStatus {
        guard response.hasRequest else { return .notRequested }
        let stored = response.request
        let decidedAt = stored.decidedAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(stored.decidedAtMs) / 1_000) : nil
        switch stored.status {
        case .pending:
            return .pending(
                VerificationCategory(stored.category),
                submittedAt: Date(timeIntervalSince1970: TimeInterval(stored.submittedAtMs) / 1_000)
            )
        case .rejected:
            return .rejected(reason: stored.reason, decidedAt: decidedAt)
        // Approved, but the profile carries no badge (it was taken away
        // since): nothing stands in the way of asking again.
        case .approved, .unspecified, .UNRECOGNIZED:
            return .notRequested
        }
    }

    public func requestVerification(_ category: VerificationCategory, links: [String]) async throws {
        var request = Profile_V1_RequestVerificationRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "requestVerification").rawValue
        request.category = category.proto
        request.documents = links
        let response = await profileClient.requestVerification(request: request, headers: [:])
        guard let error = response.error else { return }
        let message = error.message ?? ""
        if message.contains("PRF-5001") { throw VerificationError.alreadyVerified }
        if message.contains("PRF-5002") { throw VerificationError.alreadyPending }
        if error.code == .invalidArgument { throw VerificationError.invalid(message: message) }
        throw VerificationError.transport(message: message.isEmpty ? "code \(error.code)" : message, failure: NetworkFailure(error))
    }
}
