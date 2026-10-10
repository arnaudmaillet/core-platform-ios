import AuthInterface
import Connect
import CoreContracts
import CoreNetworking
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
    /// The decision that imposed it: the key for its statement of reasons and
    /// its appeal. Nil when the server sent none.
    public let decisionID: String?

    public init(id: String, kind: Kind, since: Date?, until: Date?, decisionID: String? = nil) {
        self.id = id
        self.kind = kind
        self.since = since
        self.until = until
        self.decisionID = decisionID
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
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension AccountStatusError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// `moderation.v1.GetEnforcementState` for the signed-in account. The actor
/// is the ACCOUNT id. Each enforcement names its decision (backend #658), which
/// is what `GetStatementOfReasons` and `FileAppeal` take
/// (`ModerationDecisionReviewing`).
public actor AccountStatusRepository: AccountStatusProviding {
    let moderationClient: any Moderation_V1_ModerationServiceClientInterface
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
            throw AccountStatusError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
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
                guard let kind = AccountRestriction.Kind(view.action) else { return nil }
                return AccountRestriction(
                    id: view.enforcementID,
                    kind: kind,
                    since: view.hasAppliedAt ? date(view.appliedAt.seconds, view.appliedAt.nanos) : nil,
                    until: view.hasExpiresAt ? date(view.expiresAt.seconds, view.expiresAt.nanos) : nil,
                    decisionID: view.decisionID.isEmpty ? nil : view.decisionID
                )
            }
            .sorted { ($0.since ?? .distantPast) > ($1.since ?? .distantPast) }
    }

    func accountID() async throws -> String {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw AccountStatusError.notAuthenticated
        }
        return accountID.rawValue
    }
}

extension AccountRestriction.Kind {
    /// Nil for `noAction` and unknown actions: they restrict nothing.
    init?(_ action: Moderation_V1_ActionType) {
        switch action {
        case .warn: self = .warning
        case .removeContent: self = .contentRemoved
        case .ageGate: self = .ageRestricted
        case .visibilityLimit: self = .reducedVisibility
        case .restrictActor: self = .featuresLimited
        case .suspend: self = .suspended
        case .ban: self = .banned
        case .noAction, .unspecified, .UNRECOGNIZED: return nil
        }
    }
}
