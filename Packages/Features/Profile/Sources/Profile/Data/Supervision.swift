import Connect
import CoreContracts
import CoreNavigation
import CoreNetworking
import Foundation

/// A side of a family supervision (#417, backend #670): a known adult (18+
/// by date of birth) supervises a teen aged 13 to 17.
public enum SupervisionRole: Sendable, Hashable {
    case supervisor
    case teen

    init?(_ proto: Account_V1_SupervisionRole) {
        switch proto {
        case .supervisor: self = .supervisor
        case .teen: self = .teen
        default: return nil
        }
    }

    var proto: Account_V1_SupervisionRole {
        switch self {
        case .supervisor: .supervisor
        case .teen: .teen
        }
    }

    /// The side the person who accepts an invite created as `self` takes.
    public var other: SupervisionRole { self == .supervisor ? .teen : .supervisor }
}

/// One profile of the other side, to show who it is.
public struct SupervisionProfile: Hashable, Sendable {
    public let profileID: String
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?

    public init(profileID: String, handle: String, displayName: String, avatarURL: URL? = nil) {
        self.profileID = profileID
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    init(_ proto: Account_V1_SupervisionProfile) {
        self.init(
            profileID: proto.profileID, handle: proto.handle, displayName: proto.displayName,
            avatarURL: proto.avatarURL.isEmpty ? nil : URL(string: proto.avatarURL)
        )
    }

    /// The display name, or the handle when there is none.
    public var name: String { displayName.isEmpty ? handle : displayName }
}

/// A supervision as the viewer sees it: the other side.
public struct Supervision: Hashable, Sendable {
    /// The OTHER side's role: `.teen` for a teen the viewer supervises,
    /// `.supervisor` for someone supervising the viewer.
    public let otherRole: SupervisionRole
    public let otherAccountID: String
    public let since: Date
    /// The other side's active profiles; the first is the one shown.
    public let profiles: [SupervisionProfile]

    public init(otherRole: SupervisionRole, otherAccountID: String, since: Date, profiles: [SupervisionProfile]) {
        self.otherRole = otherRole
        self.otherAccountID = otherAccountID
        self.since = since
        self.profiles = profiles
    }

    init?(_ proto: Account_V1_SupervisionView) {
        guard let role = SupervisionRole(proto.otherRole) else { return nil }
        self.init(
            otherRole: role,
            otherAccountID: proto.otherAccountID,
            since: proto.since.date,
            profiles: proto.profiles.map(SupervisionProfile.init)
        )
    }

    /// The profile a row shows; nil when the other side has none active.
    public var primary: SupervisionProfile? { profiles.first }

    /// The other side's name, for rows and confirmations.
    public var name: String { primary?.name ?? "Unknown account" }

    /// "@ava", or the name when there is no profile to take a handle from.
    public var handleText: String { primary.map { "@\($0.handle)" } ?? name }
}

/// A code to share, as `CreateSupervisionInvite` returned it.
public struct SupervisionInvite: Equatable, Sendable {
    /// Normalized: uppercase, no spaces or dashes (`SupervisionInviteCode`).
    public let code: String
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }

    /// The code as it is shown: "K7M2Q-9XRTD".
    public var displayCode: String { SupervisionInviteCode.display(code) }
    /// What the QR code and the share sheet carry.
    public var link: URL? { SupervisionInviteCode.link(for: code) }
}

/// What the server refused, in the contract's terms (backend #670).
public enum SupervisionError: Error, Equatable, Sendable {
    /// ACC-3001: the code is unknown, used, expired or taken by someone else.
    case invalidCode
    /// ACC-3002: this age does not fit that side (no date of birth included).
    case ageDoesNotFit
    /// ACC-3003: the teen already has two supervisors.
    case teenHasTwoSupervisors
    /// ACC-3004: these accounts are already linked.
    case alreadyLinked
    /// ACC-3005: no such supervision (it may have ended meanwhile).
    case notFound
    /// ACC-3006: the viewer's own code.
    case ownCode
    /// ACC-3007: too many wrong codes this hour.
    case tooManyAttempts
    /// ACC-9001: a daily limit outside 15–1440 minutes.
    case invalidLimit
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault.
    case transport(message: String, failure: NetworkFailure? = nil)

    /// The contract's code in the message picks the case; anything else is a
    /// transport failure, kept with its reason.
    init(_ error: ConnectError) {
        let message = error.message ?? ""
        let codes: [(String, SupervisionError)] = [
            ("ACC-3001", .invalidCode), ("ACC-3002", .ageDoesNotFit), ("ACC-3003", .teenHasTwoSupervisors),
            ("ACC-3004", .alreadyLinked), ("ACC-3005", .notFound), ("ACC-3006", .ownCode),
            ("ACC-3007", .tooManyAttempts), ("ACC-9001", .invalidLimit),
        ]
        if let match = codes.first(where: { message.contains($0.0) }) {
            self = match.1
        } else {
            self = .transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}

extension SupervisionError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// Settings → Family and Teens → Parental Supervision (#417): pairing a
/// parent's and a teen's accounts. Every call is the viewer's own; both sides
/// see the link, and either may end it.
public protocol SupervisionManaging: Sendable {
    /// The viewer's supervisions in both roles, most recent first.
    func supervisions() async throws -> [Supervision]
    /// A code for the other side to accept; `role` is the VIEWER's side.
    func createSupervisionInvite(as role: SupervisionRole) async throws -> SupervisionInvite
    /// Accepts another person's code: the viewer takes the other side.
    func acceptSupervisionInvite(code: String) async throws -> Supervision
    /// Ends the viewer's supervision with `otherAccountID` (the other side is
    /// told) and returns the supervisions left.
    func endSupervision(with otherAccountID: String) async throws -> [Supervision]
}

extension AccountRepository: SupervisionManaging {
    public func supervisions() async throws -> [Supervision] {
        var request = Account_V1_ListSupervisionsRequest()
        request.accountID = try await accountID()
        let response = await accountClient.listSupervisions(request: request, headers: [:])
        switch response.result {
        case .success(let list): return list.supervisions.compactMap(Supervision.init)
        case .failure(let error): throw SupervisionError(error)
        }
    }

    public func createSupervisionInvite(as role: SupervisionRole) async throws -> SupervisionInvite {
        var request = Account_V1_CreateSupervisionInviteRequest()
        request.accountID = try await accountID()
        request.role = role.proto
        let response = await accountClient.createSupervisionInvite(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            return SupervisionInvite(code: SupervisionInviteCode.normalized(view.code) ?? view.code, expiresAt: view.expiresAt.date)
        case .failure(let error):
            throw SupervisionError(error)
        }
    }

    public func acceptSupervisionInvite(code: String) async throws -> Supervision {
        var request = Account_V1_AcceptSupervisionInviteRequest()
        request.accountID = try await accountID()
        request.code = code
        let response = await accountClient.acceptSupervisionInvite(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            guard let supervision = Supervision(view) else {
                throw SupervisionError.transport(message: "a supervision with no role")
            }
            return supervision
        case .failure(let error):
            throw SupervisionError(error)
        }
    }

    public func endSupervision(with otherAccountID: String) async throws -> [Supervision] {
        var request = Account_V1_EndSupervisionRequest()
        request.accountID = try await accountID()
        request.otherAccountID = otherAccountID
        let response = await accountClient.endSupervision(request: request, headers: [:])
        switch response.result {
        case .success(let list): return list.supervisions.compactMap(Supervision.init)
        case .failure(let error): throw SupervisionError(error)
        }
    }
}
