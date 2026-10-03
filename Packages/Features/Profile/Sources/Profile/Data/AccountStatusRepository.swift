import AuthInterface
import Connect
import CoreContracts
import Foundation

/// One active restriction on the account, as Account Status lists it.
public struct AccountRestriction: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case warning, contentRemoved, ageRestricted, reducedVisibility, featuresLimited, suspended, banned
    }

    public let id: String
    public let kind: Kind
    public let since: Date?
    /// Nil for a permanent action.
    public let until: Date?

    public init(id: String, kind: Kind, since: Date?, until: Date?) {
        self.id = id
        self.kind = kind
        self.since = since
        self.until = until
    }

    public var title: String {
        switch kind {
        case .warning: "Warning"
        case .contentRemoved: "Content removed"
        case .ageRestricted: "Content age-restricted"
        case .reducedVisibility: "Reduced visibility"
        case .featuresLimited: "Some features limited"
        case .suspended: "Account suspended"
        case .banned: "Account banned"
        }
    }
}

/// Settings → Safety → Account Status (#390, DSA Art. 17/20).
public protocol AccountStatusProviding: Sendable {
    func activeRestrictions() async throws -> [AccountRestriction]
}

public enum AccountStatusError: Error, Equatable {
    case notAuthenticated
    case transport(message: String)
}

/// `moderation.v1.GetEnforcementState` for the signed-in account. The actor
/// is the ACCOUNT id — the same identity the Report flow files cases under.
///
/// ⚠️ `EnforcementView` carries no `decision_id`, so a restriction cannot be
/// linked to its `GetStatementOfReasons` or to `FileAppeal` (both take a
/// decision id). Account Status therefore lists restrictions without reasons
/// or an appeal button until the contract links them (#390).
public actor AccountStatusRepository: AccountStatusProviding {
    private let moderationClient: any Moderation_V1_ModerationServiceClientInterface
    private let authSession: any AuthSessionProviding

    public init(
        moderationClient: any Moderation_V1_ModerationServiceClientInterface,
        authSession: any AuthSessionProviding
    ) {
        self.moderationClient = moderationClient
        self.authSession = authSession
    }

    public func activeRestrictions() async throws -> [AccountRestriction] {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw AccountStatusError.notAuthenticated
        }
        var request = Moderation_V1_GetEnforcementStateRequest()
        request.actorID = accountID.rawValue
        let response = await moderationClient.getEnforcementState(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return Self.restrictions(from: body.activeEnforcements)
        case .failure(let error):
            throw AccountStatusError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// Active, user-visible enforcements, newest first. `noAction` and
    /// unspecified actions are not restrictions and are dropped.
    static func restrictions(from views: [Moderation_V1_EnforcementView]) -> [AccountRestriction] {
        func date(_ seconds: Int64, _ nanos: Int32) -> Date {
            Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1e9)
        }
        return views
            .filter { $0.status == .active || $0.status == .unspecified }
            .compactMap { view -> AccountRestriction? in
                let kind: AccountRestriction.Kind
                switch view.action {
                case .warn: kind = .warning
                case .removeContent: kind = .contentRemoved
                case .ageGate: kind = .ageRestricted
                case .visibilityLimit: kind = .reducedVisibility
                case .restrictActor: kind = .featuresLimited
                case .suspend: kind = .suspended
                case .ban: kind = .banned
                case .noAction, .unspecified, .UNRECOGNIZED: return nil
                }
                return AccountRestriction(
                    id: view.enforcementID,
                    kind: kind,
                    since: view.hasAppliedAt ? date(view.appliedAt.seconds, view.appliedAt.nanos) : nil,
                    until: view.hasExpiresAt ? date(view.expiresAt.seconds, view.expiresAt.nanos) : nil
                )
            }
            .sorted { ($0.since ?? .distantPast) > ($1.since ?? .distantPast) }
    }
}
