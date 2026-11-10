import CoreModels
import CoreNetworking
import Foundation

/// Who may find and join a group or a channel (#2213): its members only, anyone,
/// or shown on its showcases while joining waits for an admin.
public enum ConversationVisibility: Sendable, Hashable {
    case `private`
    case `public`
    case listedOnRequest
}

/// What a member may do (chat.v1 `Role`, #2213): owner, admin and member
/// talk; a subscriber and a guest only read.
public enum ConversationRole: Sendable, Hashable, Comparable {
    case owner
    case admin
    case member
    case subscriber
    case guest

    /// Whether this role writes in a channel — owner and admins publish.
    public var publishesInChannel: Bool { self == .owner || self == .admin }

    /// Whether this role manages members and identity.
    public var manages: Bool { self == .owner || self == .admin }

    /// Whether this role is a member who talks (#2217): owner, admin,
    /// member. A group's followers (subscribers) and guests are its
    /// audience — never listed or counted among its members.
    public var talks: Bool { self == .owner || self == .admin || self == .member }
}

/// The viewer's standing in a group or a channel (#2213).
public enum ConversationViewerState: Sendable, Hashable {
    case owner
    case admin
    case member
    case subscriber
    case invited
    case requested
    case none
    case banned

    /// Whether this standing writes in a channel (#2215): its owner and
    /// admins get the composer; everyone else reads — the ONE place it is
    /// decided, from `ConversationRole.publishesInChannel`.
    public var publishesInChannel: Bool { role?.publishesInChannel == true }

    /// Whether this standing runs a channel (#2215): owner or admin — who
    /// answers its join requests, in Requests (#2230).
    public var runsChannel: Bool { role?.manages == true }

    /// The role this standing gives, if the viewer is in.
    public var role: ConversationRole? {
        switch self {
        case .owner: .owner
        case .admin: .admin
        case .member: .member
        case .subscriber: .subscriber
        default: nil
        }
    }
}

/// A group's or a channel's identity and the viewer's place in it (#2213).
/// A DM has none: it is its peer.
public struct ConversationIdentity: Equatable, Sendable {
    /// A group or a channel (#2215): what the thread opened from a link —
    /// which the inbox has never listed — draws it as. Defaulted to a
    /// group, every identity #2214 built.
    public let kind: ConversationKind
    /// Its own name; empty for a group named by its members.
    public let name: String
    public let photoURL: URL?
    public let description: String
    public let visibility: ConversationVisibility
    public let memberCount: Int
    public let subscriberCount: Int
    public let viewerState: ConversationViewerState
    /// Who invited the viewer, while invited.
    public let invitedBy: ProfileID?

    public init(
        kind: ConversationKind = .group,
        name: String = "", photoURL: URL? = nil, description: String = "", visibility: ConversationVisibility = .private,
        memberCount: Int = 0, subscriberCount: Int = 0, viewerState: ConversationViewerState = .member,
        invitedBy: ProfileID? = nil
    ) {
        self.kind = kind
        self.name = name
        self.photoURL = photoURL
        self.description = description
        self.visibility = visibility
        self.memberCount = memberCount
        self.subscriberCount = subscriberCount
        self.viewerState = viewerState
        self.invitedBy = invitedBy
    }

    /// A group with no name, named by its members (#2213) — the ONE place:
    /// "Alice", "Alice and Bob", "Alice, Bob and Carla", "Alice, Bob and 3
    /// others". `total` counts every other member, named or not.
    public static func memberName(_ names: [String], total: Int? = nil) -> String {
        let names = names.filter { !$0.isEmpty }
        let count = max(total ?? names.count, names.count)
        switch (names.count, count) {
        case (0, _): return "Group"
        case (1, 1): return names[0]
        case (2, 2): return "\(names[0]) and \(names[1])"
        case (3, 3): return "\(names[0]), \(names[1]) and \(names[2])"
        default:
            let others = count - 2
            return "\(names[0]), \(names[1]) and \(others) \(others == 1 ? "other" : "others")"
        }
    }

    /// The faces a nameless, photoless group shows, stacked: up to three.
    public static let stackedFaces = 3

    /// A group with no room left (#2217): chat.v1's cap reached, so an
    /// outsider or a follower is offered Follow only.
    public var isFull: Bool { kind == .group && memberCount >= ConversationDraft.groupCap }
}

/// A member of a group or a channel, from `ListMembers` (#2213).
public struct ConversationMember: Equatable, Sendable, Identifiable {
    public let profileID: ProfileID
    public let role: ConversationRole
    public let joinedAt: Date
    public var id: ProfileID { profileID }

    public init(profileID: ProfileID, role: ConversationRole, joinedAt: Date) {
        self.profileID = profileID
        self.role = role
        self.joinedAt = joinedAt
    }
}

/// One page of a conversation's people (#2237): #995's paged `ListMembers`.
/// `total` is every member of the roles asked — what a counter says, and so
/// what the list must add up to.
public struct ConversationMemberPage: Equatable, Sendable {
    public let members: [ConversationMember]
    /// Nil: the last page.
    public let nextPageToken: String?
    public let total: Int

    public init(members: [ConversationMember], nextPageToken: String?, total: Int) {
        self.members = members
        self.nextPageToken = nextPageToken
        self.total = total
    }
}

/// A request to join, waiting for an admin (#2213, #2215).
public struct ConversationJoinRequest: Equatable, Sendable, Identifiable {
    public let profileID: ProfileID
    public let requestedAt: Date
    public var id: ProfileID { profileID }

    public init(profileID: ProfileID, requestedAt: Date) {
        self.profileID = profileID
        self.requestedAt = requestedAt
    }
}

/// What to create (#2213, #2214, #2215).
public struct ConversationDraft: Equatable, Sendable {
    public var kind: ConversationKind
    public var name: String
    public var photoURL: URL?
    public var description: String
    public var visibility: ConversationVisibility
    public var memberIDs: [ProfileID]

    public init(
        kind: ConversationKind, name: String = "", photoURL: URL? = nil, description: String = "",
        visibility: ConversationVisibility = .private, memberIDs: [ProfileID] = []
    ) {
        self.kind = kind
        self.name = name
        self.photoURL = photoURL
        self.description = description
        self.visibility = visibility
        self.memberIDs = memberIDs
    }

    /// A group holds at most this many members (chat.v1's cap).
    public static let groupCap = ProposedChat.groupCap
}

/// Groups' and channels' reads and writes (#2213), behind the repository —
/// each one runs on the shape core-platform-backend#995 describes
/// (`ProposedChat`) until its contract lands.
public protocol ConversationManaging: Sendable {
    func details(of conversationID: ConversationID) async throws -> ConversationIdentity
    func members(of conversationID: ConversationID) async throws -> [ConversationMember]
    /// One page of `roles`' members, `limit` at most, after `pageToken`
    /// (nil: the first) — what the info screens' lists read (#2237): a
    /// channel's 12 400 subscribers are never read at once.
    func members(
        of conversationID: ConversationID, roles: Set<ConversationRole>, after pageToken: String?, limit: Int
    ) async throws -> ConversationMemberPage
    func create(_ draft: ConversationDraft) async throws -> ConversationID
    func editIdentity(of conversationID: ConversationID, name: String, photoURL: URL?, description: String) async throws
    func invite(_ profileIDs: [ProfileID], to conversationID: ConversationID) async throws
    func answerInvitation(to conversationID: ConversationID, accept: Bool) async throws
    /// A public channel or group subscribes at once (`.subscriber`); one
    /// listed on request waits (`.requested`).
    func requestToJoin(_ conversationID: ConversationID) async throws -> ConversationViewerState
    func cancelJoinRequest(_ conversationID: ConversationID) async throws
    func joinRequests(to conversationID: ConversationID) async throws -> [ConversationJoinRequest]
    func answerJoinRequest(from profileID: ProfileID, to conversationID: ConversationID, approve: Bool) async throws
    func setRole(_ role: ConversationRole, of profileID: ProfileID, in conversationID: ConversationID) async throws
    func remove(_ profileID: ProfileID, from conversationID: ConversationID, ban: Bool) async throws
    func transferOwnership(of conversationID: ConversationID, to profileID: ProfileID) async throws
    func leave(_ conversationID: ConversationID) async throws
    func setVisibility(_ visibility: ConversationVisibility, of conversationID: ConversationID) async throws
    func subscribe(to conversationID: ConversationID) async throws
    func unsubscribe(from conversationID: ConversationID) async throws
}

// MARK: - Wire mapping

extension ConversationVisibility {
    init(_ wire: ProposedChat.Visibility) {
        switch wire {
        case .private: self = .private
        case .public: self = .public
        case .listedOnRequest: self = .listedOnRequest
        }
    }

    var wire: ProposedChat.Visibility {
        switch self {
        case .private: .private
        case .public: .public
        case .listedOnRequest: .listedOnRequest
        }
    }
}

extension ConversationRole {
    init(_ wire: ProposedChat.Role) {
        switch wire {
        case .owner: self = .owner
        case .admin: self = .admin
        case .member: self = .member
        case .subscriber: self = .subscriber
        case .guest: self = .guest
        }
    }

    var wire: ProposedChat.Role {
        switch self {
        case .owner: .owner
        case .admin: .admin
        case .member: .member
        case .subscriber: .subscriber
        case .guest: .guest
        }
    }
}

extension ConversationViewerState {
    init(_ wire: ProposedChat.ViewerState) {
        switch wire {
        case .owner: self = .owner
        case .admin: self = .admin
        case .member: self = .member
        case .subscriber: self = .subscriber
        case .invited: self = .invited
        case .requested: self = .requested
        case .none: self = .none
        case .banned: self = .banned
        }
    }
}

extension ConversationIdentity {
    init(_ details: ProposedChat.Details) {
        self.init(
            kind: details.kind == .channel ? .channel : .group,
            name: details.name,
            photoURL: details.photoURL.isEmpty ? nil : URL(string: details.photoURL),
            description: details.description,
            visibility: ConversationVisibility(details.visibility),
            memberCount: details.memberCount,
            subscriberCount: details.subscriberCount,
            viewerState: ConversationViewerState(details.viewerState),
            invitedBy: details.invitedBy.isEmpty ? nil : ProfileID(details.invitedBy)
        )
    }
}
