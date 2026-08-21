import AuthInterface
import Connect
import CoreContracts
import CoreModels
import Foundation

/// Files reports through `moderation.v1.OpenCase`, for any subject the app
/// can raise a case about.
///
/// ⚠️ It is named for a profile and lives in the Profile package for one
/// reason only: this package already holds the moderation client's wiring and
/// the auth session it needs. Its CALLERS reach it through `ContentReporting`
/// in CoreModels, so nothing outside the composition root knows where the
/// class lives, and moving it is a move rather than a refactor.
///
/// **Fleet routing.** `moderation.v1` is not yet exposed through the dev
/// gateway's upstream (see `dev/BACKEND_GAPS.md` §11) — a route and cluster
/// are in `dev/envoy/envoy.yaml` but the upstream port is unconfirmed, so
/// against the local fleet a report may fail until that is settled. Mock mode
/// answers it exactly (`MockModerationService`), which is where the flow is
/// verified.
public actor ProfileReportRepository: ContentReporting {
    private let moderationClient: any Moderation_V1_ModerationServiceClientInterface
    private let authSession: any AuthSessionProviding

    public init(
        moderationClient: any Moderation_V1_ModerationServiceClientInterface,
        authSession: any AuthSessionProviding
    ) {
        self.moderationClient = moderationClient
        self.authSession = authSession
    }

    public func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw ProfileError.notAuthenticated
        }

        var subjectRef = Moderation_V1_SubjectRef()
        switch subject {
        case .profile(let id):
            subjectRef.entityType = .profile
            subjectRef.entityID = id.rawValue
        case .post(let id):
            subjectRef.entityType = .post
            subjectRef.entityID = id.rawValue
        }
        // The *reporter*, not the reported: `SubjectRef.actorID` identifies who
        // raised the case, which is what the queue needs for rate-limiting and
        // abuse-of-reporting signals.
        subjectRef.actorID = accountID.rawValue
        subjectRef.surface = surface

        var request = Moderation_V1_OpenCaseRequest()
        request.subject = subjectRef
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

    private static func category(for reason: ReportReason) -> Moderation_V1_PolicyCategory {
        switch reason {
        case .spam: .spam
        case .harassment: .harassment
        case .hate: .hate
        case .misinformation: .misinformation
        case .other: .other
        }
    }
}
