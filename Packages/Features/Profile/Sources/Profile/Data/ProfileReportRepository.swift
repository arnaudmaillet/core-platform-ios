import AuthInterface
import Connect
import CoreContracts
import CoreModels
import Foundation

/// Why the viewer is reporting a profile. A deliberately short list — the
/// contract's `PolicyCategory` carries nine values, but three of them
/// (`csam`, `ncii`, `violentExtremism`) are legal-escalation categories that
/// belong behind a dedicated, guided flow rather than a one-tap menu, and
/// `unspecified` is not a user intent. The rest map 1:1 onto the wire enum.
public enum ProfileReportReason: String, CaseIterable, Sendable {
    case spam
    case harassment
    case hate
    case misinformation
    case other

    /// The row title in the reason picker.
    public var title: String {
        switch self {
        case .spam: "Spam or scam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate speech"
        case .misinformation: "False information"
        case .other: "Something else"
        }
    }
}

/// Files moderation reports for a profile. Separate from `ProfileProviding`
/// on purpose: reporting is a moderation-domain command with its own service
/// and its own failure semantics, and the same seam will serve posts and
/// comments once those surfaces grow a Report action — at which point this
/// protocol graduates out of the Profile package into Kit.
public protocol ProfileReporting: Sendable {
    /// Opens a moderation case against `profileID`. Throws if the report was
    /// not accepted — the caller surfaces that, because a silently-dropped
    /// report is worse than an honest failure.
    func reportProfile(_ profileID: ProfileID, reason: ProfileReportReason) async throws
}

/// Files reports through `moderation.v1.OpenCase`.
///
/// **Fleet routing.** `moderation.v1` is not yet exposed through the dev
/// gateway's upstream (see `dev/BACKEND_GAPS.md` §11) — a route and cluster
/// are in `dev/envoy/envoy.yaml` but the upstream port is unconfirmed, so
/// against the local fleet a report may fail until that is settled. Mock mode
/// answers it exactly (`MockModerationService`), which is where the flow is
/// verified.
public actor ProfileReportRepository: ProfileReporting {
    private let moderationClient: any Moderation_V1_ModerationServiceClientInterface
    private let authSession: any AuthSessionProviding
    /// Names where the report was filed, for the moderation queue's triage —
    /// the contract's `SubjectRef.surface` is a free-form string.
    private static let surface = "ios.profile"

    public init(
        moderationClient: any Moderation_V1_ModerationServiceClientInterface,
        authSession: any AuthSessionProviding
    ) {
        self.moderationClient = moderationClient
        self.authSession = authSession
    }

    public func reportProfile(_ profileID: ProfileID, reason: ProfileReportReason) async throws {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw ProfileError.notAuthenticated
        }

        var subject = Moderation_V1_SubjectRef()
        subject.entityType = .profile
        subject.entityID = profileID.rawValue
        // The *reporter*, not the reported: `SubjectRef.actorID` identifies who
        // raised the case, which is what the queue needs for rate-limiting and
        // abuse-of-reporting signals.
        subject.actorID = accountID.rawValue
        subject.surface = Self.surface

        var request = Moderation_V1_OpenCaseRequest()
        request.subject = subject
        request.category = Self.category(for: reason)
        request.reason = reason.title

        let response = await moderationClient.openCase(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
        // `created == false` is still success — the contract documents it as an
        // idempotent open that returns the EXISTING case for this subject. Only
        // a missing case id means nothing was filed.
        guard let body = response.message, !body.case.caseID.isEmpty else {
            throw ProfileError.transport(message: "report rejected")
        }
    }

    private static func category(for reason: ProfileReportReason) -> Moderation_V1_PolicyCategory {
        switch reason {
        case .spam: .spam
        case .harassment: .harassment
        case .hate: .hate
        case .misinformation: .misinformation
        case .other: .other
        }
    }
}
