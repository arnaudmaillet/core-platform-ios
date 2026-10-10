import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// Files reports through `moderation.v1.SubmitReport` and lists them back
/// with what became of each (`ListMyReports`, DSA Art. 16(5)).
///
/// ⚠️ It is named for a profile and lives in the Profile package for one
/// reason only: this package already holds the moderation client's wiring and
/// the auth session it needs. Its CALLERS reach it through `ContentReporting`
/// in CoreModels, so nothing outside the composition root knows where the
/// class lives, and moving it is a move rather than a refactor.
///
/// **The reporter is the token.** Neither RPC takes a reporter field: the edge
/// reads the caller from the bearer (backend #677), and the account behind
/// the reported content is resolved server-side. `OpenCase`, which the app
/// used before, is the reviewer console's and mesh-only.
///
/// **Fleet routing.** `moderation.v1` is not yet exposed through the dev
/// gateway's upstream (see `dev/BACKEND_GAPS.md` §11) — a route and cluster
/// are in `dev/envoy/envoy.yaml` but the upstream port is unconfirmed, so
/// against the local fleet a report may fail until that is settled. Mock mode
/// answers it exactly (`MockModerationService`), which is where the flow is
/// verified.
public actor ProfileReportRepository: ContentReporting {
    let moderationClient: any Moderation_V1_ModerationServiceClientInterface

    public init(moderationClient: any Moderation_V1_ModerationServiceClientInterface) {
        self.moderationClient = moderationClient
    }

    /// Anyone may report (DSA Art. 16): a member, and a guest with their
    /// guest token (backend #677 — the edge's `member_or_guest`).
    public func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {
        var request = Moderation_V1_SubmitReportRequest()
        switch subject {
        case .profile(let id):
            request.entityType = .profile
            request.entityID = id.rawValue
        case .post(let id):
            request.entityType = .post
            request.entityID = id.rawValue
        }
        request.category = Self.category(for: reason)
        request.surface = surface

        let response = await moderationClient.submitReport(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        // Reporting the same content again is still success: the id is
        // deterministic per reporter and subject. Only a missing id means
        // nothing was filed.
        guard let body = response.message, !body.reportID.isEmpty else {
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
