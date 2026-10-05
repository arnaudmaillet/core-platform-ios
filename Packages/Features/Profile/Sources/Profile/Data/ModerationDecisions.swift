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

/// Reads a restriction's reasons and appeals it (DSA Art. 17 and 20), both
/// addressed by the decision that imposed it.
public protocol ModerationDecisionReviewing: Sendable {
    func statementOfReasons(decisionID: String) async throws -> DecisionStatement
    /// Files an appeal and returns when it was filed.
    func fileAppeal(decisionID: String, statement: String) async throws -> Date
}

/// The appeals filed from this iPhone, by decision. `moderation.v1` has no
/// read for an appeal (only the reviewer console resolves them), so this is
/// how Account Status knows not to offer a second one.
public enum FiledAppeals {
    static let key = "moderation.appealsFiled"
    /// Swappable for tests.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    public static func record(decisionID: String, at date: Date) {
        var filed = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        filed[decisionID] = date.timeIntervalSince1970
        defaults.set(filed, forKey: key)
    }

    public static func filedAt(decisionID: String) -> Date? {
        (defaults.dictionary(forKey: key) as? [String: Double])?[decisionID].map(Date.init(timeIntervalSince1970:))
    }
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
            let filedAt = body.appeal.hasFiledAt ? body.appeal.filedAt.date : Date()
            FiledAppeals.record(decisionID: decisionID, at: filedAt)
            return filedAt
        case .failure(let error):
            let message = error.message ?? ""
            if message.contains("MOD-5003") { throw AppealError.windowClosed }
            if message.contains("MOD-5004") { throw AppealError.notAppealable }
            if error.code == .notFound { throw AppealError.notFound }
            throw AppealError.transport(message: error.message ?? "code \(error.code)")
        }
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
