import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

/// Fake of moderation.v1 — the RPCs a *user-facing* surface calls:
/// - `SubmitReport` (the Report actions) and `ListMyReports` (Settings →
///   Safety → Your Reports, DSA Art. 16(5));
/// - `GetEnforcementState`, `GetStatementOfReasons`, `FileAppeal` and
///   `ListMyAppeals` (Settings → Account Status, DSA Art. 17/20). A reporter
///   appeals the decision on their report too (backend #745).
///
/// With the report history seeded, the decided reports carry their decision,
/// and the one found not violating has a reporter's appeal already resolved
/// (upheld, with the reviewer's reasons), so a resolved appeal can be seen.
///
/// `OpenCase` stays for the tests that drive it; on the fleet it is mesh-only
/// since backend #677. The rest of the service is a moderator console
/// (`listQueue`, `assignCase`, `decideCase`, `resolveAppeal`) with no client
/// in this app, so mocking it would be fiction with no reader.
///
/// This mock is how the report flow is verified at all: `moderation.v1` is not
/// routed through the dev gateway (see `dev/BACKEND_GAPS.md` §11), so against
/// the local fleet the call does not currently land.
public final class MockModerationService: @unchecked Sendable {
    /// The seeded restriction's decision: the key its statement of reasons and
    /// its appeal are read and filed under.
    public static let seededDecisionID = "dec-seed-1"

    /// Cases opened this session, newest last — inspectable from tests so a
    /// report assertion can check the subject and category that were filed,
    /// not merely that the call succeeded.
    public var openedCases: [Moderation_V1_CaseView] {
        lock.withLock { storage }
    }

    /// Reports submitted this session plus the seeded ones, in filing order.
    public var submittedReports: [Moderation_V1_ReportView] {
        lock.withLock { reports.map(\.view) }
    }

    /// Appeals filed this session, newest last.
    public var filedAppeals: [Moderation_V1_AppealView] {
        lock.withLock { appeals }
    }

    private struct StoredReport {
        /// The account id, or "guest" for a caller without a token.
        var reporter: String
        var view: Moderation_V1_ReportView
    }

    private let lock = NSLock()
    private var storage: [Moderation_V1_CaseView] = []
    private var reports: [StoredReport] = []
    private var appeals: [Moderation_V1_AppealView] = []
    private let seedsViewerRestriction: Bool

    /// `seedsViewerRestriction` gives the viewer's account one active,
    /// time-boxed restriction (comments limited for a week) with its decision.
    /// `seedsReportHistory` gives the viewer three past reports, one per
    /// outcome, so Your Reports can be seen filled.
    public init(seedsViewerRestriction: Bool = false, seedsReportHistory: Bool = false) {
        self.seedsViewerRestriction = seedsViewerRestriction
        if seedsReportHistory {
            reports = Self.reportHistory()
            appeals = [Self.resolvedReporterAppeal()]
        }
    }

    /// Whether the caller may appeal a decision, and as whom: their
    /// restriction's (false), or the one on a report they made (true,
    /// backend #745). Nil for anyone else's: NOT_FOUND.
    private func appealsAsReporter(_ decisionID: String) -> Bool? {
        if seedsViewerRestriction, decisionID == Self.seededDecisionID { return false }
        let onMyReport = lock.withLock {
            reports.contains { $0.reporter == MockAuthService.accountID && $0.view.decisionID == decisionID }
        }
        return onMyReport ? true : nil
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/moderation.v1.ModerationService/GetEnforcementState") { [self] (request: Moderation_V1_GetEnforcementStateRequest) in
            var response = Moderation_V1_GetEnforcementStateResponse()
            if seedsViewerRestriction, request.actorID == MockAuthService.accountID {
                response.actorRestricted = true
                response.activeEnforcements = [Self.seededEnforcement()]
            }
            return .success(response)
        }
        bff.register(path: "/moderation.v1.ModerationService/GetStatementOfReasons") { [self] (request: Moderation_V1_GetStatementOfReasonsRequest) -> Result<Moderation_V1_GetStatementOfReasonsResponse, ConnectError> in
            // Only the sanctioned account reads it; anything else is NOT_FOUND,
            // as on the edge (backend #658).
            guard seedsViewerRestriction, request.decisionID == Self.seededDecisionID else {
                return .failure(ConnectError(code: .notFound, message: "MOD-2001: decision not found"))
            }
            var response = Moderation_V1_GetStatementOfReasonsResponse()
            response.statement = Self.seededStatement()
            return .success(response)
        }
        bff.register(path: "/moderation.v1.ModerationService/FileAppeal") { [self] (request: Moderation_V1_FileAppealRequest) -> Result<Moderation_V1_FileAppealResponse, ConnectError> in
            guard let byReporter = appealsAsReporter(request.decisionID) else {
                return .failure(ConnectError(code: .notFound, message: "MOD-2001: decision not found"))
            }
            guard !request.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(ConnectError(code: .invalidArgument, message: "MOD-9001: an appeal must include a statement"))
            }
            let appeal: Moderation_V1_AppealView = lock.withLock {
                // One appeal per decision and appellant: filing again
                // returns the existing one (backend #744).
                if let existing = appeals.first(where: { $0.decisionID == request.decisionID }) { return existing }
                var appeal = Moderation_V1_AppealView()
                appeal.appealID = "appeal-\(appeals.count + 1)"
                appeal.decisionID = request.decisionID
                appeal.statement = request.statement
                appeal.status = .filed
                appeal.filedAt = .init(date: Date())
                appeal.byReporter = byReporter
                appeals.append(appeal)
                return appeal
            }
            var response = Moderation_V1_FileAppealResponse()
            response.appeal = appeal
            return .success(response)
        }
        // The caller's appeals, newest first (backend #744).
        bff.register(path: "/moderation.v1.ModerationService/ListMyAppeals") { [self] (request: Moderation_V1_ListMyAppealsRequest) -> Result<Moderation_V1_ListMyAppealsResponse, ConnectError> in
            let mine = lock.withLock { appeals }.sorted { $0.filedAt.date > $1.filedAt.date }
            let pageSize = Int(request.pageSize <= 0 ? 20 : min(request.pageSize, 50))
            let start = Int(request.pageToken) ?? 0
            let end = min(start + pageSize, mine.count)
            var response = Moderation_V1_ListMyAppealsResponse()
            response.appeals = start < end ? Array(mine[start..<end]) : []
            response.nextPageToken = end < mine.count ? String(end) : ""
            return .success(response)
        }
        bff.register(path: "/moderation.v1.ModerationService/SubmitReport") { [self] (request: Moderation_V1_SubmitReportRequest, headers: Headers) -> Result<Moderation_V1_SubmitReportResponse, ConnectError> in
            guard [.post, .comment, .profile].contains(request.entityType) else {
                return .failure(ConnectError(code: .invalidArgument, message: "MOD-6006: unsupported report target"))
            }
            // The reporter is the caller's token, never a request field.
            let reporter = MockEdgePolicy.caller(from: headers) == .member ? MockAuthService.accountID : "guest"
            let reportID = "report-\(reporter)-\(request.entityType.rawValue)-\(request.entityID)"
            lock.withLock {
                // One row per reporter × subject: a re-report keeps the first.
                guard !reports.contains(where: { $0.view.reportID == reportID }) else { return }
                var view = Moderation_V1_ReportView()
                view.reportID = reportID
                view.entityType = request.entityType
                view.entityID = request.entityID
                view.category = request.category
                view.reason = request.reason
                view.status = .underReview
                view.reportedAt = .init(date: Date())
                reports.append(StoredReport(reporter: reporter, view: view))
            }
            var response = Moderation_V1_SubmitReportResponse()
            response.reportID = reportID
            return .success(response)
        }
        bff.register(path: "/moderation.v1.ModerationService/ListMyReports") { [self] (request: Moderation_V1_ListMyReportsRequest, headers: Headers) -> Result<Moderation_V1_ListMyReportsResponse, ConnectError> in
            let reporter = MockEdgePolicy.caller(from: headers) == .member ? MockAuthService.accountID : "guest"
            let mine = lock.withLock { reports.filter { $0.reporter == reporter }.map(\.view) }
                .sorted { $0.reportedAt.date > $1.reportedAt.date }
            let pageSize = Int(request.pageSize <= 0 ? 20 : min(request.pageSize, 50))
            let start = Int(request.pageToken) ?? 0
            let end = min(start + pageSize, mine.count)
            var response = Moderation_V1_ListMyReportsResponse()
            response.reports = start < end ? Array(mine[start..<end]) : []
            response.nextPageToken = end < mine.count ? String(end) : ""
            return .success(response)
        }
        bff.register(path: "/moderation.v1.ModerationService/OpenCase") { [self] (request: Moderation_V1_OpenCaseRequest) in
            var response = Moderation_V1_OpenCaseResponse()
            // Idempotent open, per the contract: a second report of the same
            // subject by the same actor returns the EXISTING case with
            // `created = false` rather than stacking duplicates in the queue.
            if let existing = existingCase(for: request.subject) {
                response.case = existing
                response.created = false
                return .success(response)
            }

            var view = Moderation_V1_CaseView()
            // Deterministic id from the case index — no randomness, so a test
            // asserting on the returned id stays stable between runs.
            view.caseID = "case-\(nextCaseIndex())"
            view.subject = request.subject
            view.category = request.category
            view.status = .open
            view.queue = "default"
            view.priority = "normal"
            append(view)

            response.case = view
            response.created = true
            return .success(response)
        }
    }

    // MARK: - Seeds

    private static func seededEnforcement() -> Moderation_V1_EnforcementView {
        var enforcement = Moderation_V1_EnforcementView()
        enforcement.enforcementID = "enf-seed-1"
        enforcement.decisionID = seededDecisionID
        enforcement.subject.entityType = .account
        enforcement.subject.entityID = MockAuthService.accountID
        enforcement.subject.actorID = MockAuthService.accountID
        enforcement.action = .restrictActor
        enforcement.status = .active
        enforcement.version = 1
        enforcement.appliedAt = .init(date: Date().addingTimeInterval(-2 * 86_400))
        enforcement.expiresAt = .init(date: Date().addingTimeInterval(5 * 86_400))
        return enforcement
    }

    private static func seededStatement() -> Moderation_V1_StatementOfReasons {
        var statement = Moderation_V1_StatementOfReasons()
        statement.decisionID = seededDecisionID
        statement.subject.entityType = .account
        statement.subject.entityID = MockAuthService.accountID
        statement.subject.actorID = MockAuthService.accountID
        statement.category = .harassment
        statement.action = .restrictActor
        statement.policyVersion = "community-guidelines-2026-09"
        statement.facts = "Several of your comments were reported and, on review, found to insult another member repeatedly."
        statement.legalGround = "Community Guidelines, section 3: Harassment and bullying."
        statement.automated = false
        statement.territorialEu = true
        statement.decidedAt = .init(date: Date().addingTimeInterval(-2 * 86_400))
        return statement
    }

    private static func reportHistory() -> [StoredReport] {
        let seeds: [(Moderation_V1_EntityType, String, Moderation_V1_PolicyCategory, Moderation_V1_ReportStatus, Double)] = [
            (.post, "post-seed-reported-1", .spam, .noViolation, 20),
            (.profile, "profile-seed-reported-1", .harassment, .actionTaken, 9),
            (.comment, "comment-seed-reported-1", .hate, .underReview, 1),
        ]
        return seeds.map { type, id, category, status, daysAgo in
            var view = Moderation_V1_ReportView()
            view.reportID = "report-\(MockAuthService.accountID)-\(type.rawValue)-\(id)"
            view.entityType = type
            view.entityID = id
            view.category = category
            view.status = status
            view.reportedAt = .init(date: Date().addingTimeInterval(-daysAgo * 86_400))
            // A decided case names its decision, which the reporter may appeal.
            if status != .underReview { view.decisionID = "dec-report-\(id)" }
            return StoredReport(reporter: MockAuthService.accountID, view: view)
        }
    }

    /// The reporter's appeal on the post found not violating: reviewed again,
    /// and upheld.
    private static func resolvedReporterAppeal() -> Moderation_V1_AppealView {
        var appeal = Moderation_V1_AppealView()
        appeal.appealID = "appeal-seed-1"
        appeal.decisionID = "dec-report-post-seed-reported-1"
        appeal.status = .upheld
        appeal.statement = "It's a scam link, it takes you to a fake bank login."
        appeal.filedAt = .init(date: Date().addingTimeInterval(-15 * 86_400))
        appeal.resolvedAt = .init(date: Date().addingTimeInterval(-12 * 86_400))
        appeal.outcome = "We looked at the post again. The link goes to a real shop, so it doesn't break our spam rules."
        appeal.byReporter = true
        return appeal
    }

    // MARK: - Cases

    private func existingCase(for subject: Moderation_V1_SubjectRef) -> Moderation_V1_CaseView? {
        lock.withLock {
            storage.first {
                $0.subject.entityType == subject.entityType
                    && $0.subject.entityID == subject.entityID
                    && $0.subject.actorID == subject.actorID
            }
        }
    }

    private func nextCaseIndex() -> Int {
        lock.withLock { storage.count }
    }

    private func append(_ view: Moderation_V1_CaseView) {
        lock.withLock { storage.append(view) }
    }
}
