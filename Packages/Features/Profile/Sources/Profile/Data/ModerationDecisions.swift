import CoreContracts
import Foundation

/// Why a restriction was imposed: the decision's Statement of Reasons
/// (DSA Art. 17), as Account Status shows it.
public struct DecisionStatement: Equatable, Sendable {
    public let decisionID: String
    /// The policy broken, e.g. "Harassment or bullying".
    public let policy: String
    /// What was done; nil for an action the app doesn't know.
    public let action: AccountRestriction.Kind?
    /// The facts the decision rests on.
    public let facts: String
    /// The rule or law relied on.
    public let legalGround: String
    public let policyVersion: String
    /// Taken by an automated system rather than a person (Art. 17(3)(c)).
    public let automated: Bool
    public let decidedAt: Date?

    public init(
        decisionID: String, policy: String, action: AccountRestriction.Kind?, facts: String,
        legalGround: String, policyVersion: String, automated: Bool, decidedAt: Date?
    ) {
        self.decisionID = decisionID
        self.policy = policy
        self.action = action
        self.facts = facts
        self.legalGround = legalGround
        self.policyVersion = policyVersion
        self.automated = automated
        self.decidedAt = decidedAt
    }

    init(_ statement: Moderation_V1_StatementOfReasons) {
        self.init(
            decisionID: statement.decisionID,
            policy: PolicyCategoryText.title(statement.category),
            action: AccountRestriction.Kind(statement.action),
            facts: statement.facts,
            legalGround: statement.legalGround,
            policyVersion: statement.policyVersion,
            automated: statement.automated,
            decidedAt: statement.hasDecidedAt ? statement.decidedAt.date : nil
        )
    }
}

public enum AppealError: Error, Equatable {
    /// An appeal must say why (the server refuses an empty one).
    case emptyStatement
    /// MOD-5003: too late to appeal this decision.
    case windowClosed
    /// MOD-5004: the policy doesn't allow an appeal (e.g. a legally required removal).
    case notAppealable
    /// The decision isn't this account's, or no longer exists.
    case notFound
    case transport(message: String)
}

/// An appeal the viewer filed, as the server holds it (#576, backend #744):
/// against their own restriction, or against the decision on a report they
/// made (backend #745).
public struct FiledAppeal: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Filed, or being reviewed again.
        case pending
        /// The decision stands.
        case upheld
        /// The decision was reversed. For a reporter's appeal the case goes
        /// back to review; it never reverses an enforcement on its own.
        case overturned
    }

    public let id: String
    public let decisionID: String
    public let status: Status
    public let filedAt: Date?
    public let resolvedAt: Date?
    /// The reviewer's reasons once resolved (DSA Art. 20(4)–(5)); empty before.
    public let reasons: String
    public let byReporter: Bool

    public init(
        id: String, decisionID: String, status: Status, filedAt: Date?, resolvedAt: Date? = nil,
        reasons: String = "", byReporter: Bool = false
    ) {
        self.id = id
        self.decisionID = decisionID
        self.status = status
        self.filedAt = filedAt
        self.resolvedAt = resolvedAt
        self.reasons = reasons
        self.byReporter = byReporter
    }

    init(_ view: Moderation_V1_AppealView) {
        let status: Status = switch view.status {
        case .upheld: .upheld
        case .overturned: .overturned
        case .filed, .underReview, .unspecified, .UNRECOGNIZED: .pending
        }
        self.init(
            id: view.appealID,
            decisionID: view.decisionID,
            status: status,
            filedAt: view.hasFiledAt ? view.filedAt.date : nil,
            resolvedAt: view.hasResolvedAt ? view.resolvedAt.date : nil,
            reasons: view.outcome,
            byReporter: view.byReporter
        )
    }
}

/// Reads a restriction's reasons and appeals it (DSA Art. 17 and 20), both
/// addressed by the decision that imposed it — and follows the appeals.
public protocol ModerationDecisionReviewing: Sendable {
    func statementOfReasons(decisionID: String) async throws -> DecisionStatement
    /// Files an appeal and returns when it was filed. Filing again for the
    /// same decision returns the appeal already on file.
    func fileAppeal(decisionID: String, statement: String) async throws -> Date
    /// The viewer's appeals, newest first (`ListMyAppeals`).
    func myAppeals() async throws -> [FiledAppeal]
}

extension AccountStatusRepository: ModerationDecisionReviewing {
    public func statementOfReasons(decisionID: String) async throws -> DecisionStatement {
        var request = Moderation_V1_GetStatementOfReasonsRequest()
        request.decisionID = decisionID
        let response = await moderationClient.getStatementOfReasons(request: request, headers: [:])
        switch response.result {
        case .success(let body): return DecisionStatement(body.statement)
        case .failure(let error): throw AccountStatusError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func fileAppeal(decisionID: String, statement: String) async throws -> Date {
        let statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { throw AppealError.emptyStatement }
        var request = Moderation_V1_FileAppealRequest()
        request.decisionID = decisionID
        request.actorID = try await accountID()
        request.statement = statement
        let response = await moderationClient.fileAppeal(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.appeal.hasFiledAt ? body.appeal.filedAt.date : Date()
        case .failure(let error):
            let message = error.message ?? ""
            if message.contains("MOD-5003") { throw AppealError.windowClosed }
            if message.contains("MOD-5004") { throw AppealError.notAppealable }
            if error.code == .notFound { throw AppealError.notFound }
            throw AppealError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}

extension AccountStatusRepository {
    /// Up to 100 — far more than anyone has — in pages of 50.
    public func myAppeals() async throws -> [FiledAppeal] {
        var appeals: [FiledAppeal] = []
        var token = ""
        for _ in 0..<2 {
            var request = Moderation_V1_ListMyAppealsRequest()
            request.pageSize = 50
            request.pageToken = token
            let response = await moderationClient.listMyAppeals(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                appeals += body.appeals.map(FiledAppeal.init)
                token = body.nextPageToken
            case .failure(let error):
                throw AccountStatusError.transport(message: error.message ?? "code \(error.code)")
            }
            if token.isEmpty { break }
        }
        return appeals
    }
}

/// How the app names a policy category, in Account Status and Your Reports:
/// the report picker's words (`ReportReason.title`) where they overlap.
enum PolicyCategoryText {
    static func title(_ category: Moderation_V1_PolicyCategory) -> String {
        switch category {
        case .spam: "Spam or scam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate speech"
        case .violentExtremism: "Violent extremism"
        case .csam: "Child sexual abuse"
        case .ncii: "Intimate images shared without consent"
        case .selfHarm: "Suicide or self-harm"
        case .misinformation: "False information"
        case .other, .unspecified, .UNRECOGNIZED: "Something else"
        }
    }
}
