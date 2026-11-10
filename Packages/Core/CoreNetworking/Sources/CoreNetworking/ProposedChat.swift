import Connect
import Foundation
import SwiftProtobuf

/// Groups' and channels' needs on the wire (#2211, #2213), until chat.v1
/// carries them (core-platform-backend#995: identity, invitations that reach
/// the invitee, join requests and a "listed on request" state, member
/// management, channels' rights).
///
/// ONE path, a JSON call in, a JSON reply out — each carried in a well-known
/// `StringValue`, so neither side needs generated types for a contract the
/// backend has not written. The mock answers it (`MockChatService`), the
/// repository calls it (`ChatRepository`); when #995 lands, each call becomes
/// its typed RPC and this file goes.
///
/// What chat.v1 already has stays chat.v1's: the inbox and its kinds,
/// history, sending, members (`ListMembers`, with roles), leaving,
/// subscribing, the Private / Public toggle.
public enum ProposedChat {
    public static let path = "/chat.v1.proposed.ConversationService/Call"

    /// A group holds at most this many members (chat.v1's cap): the mock
    /// refuses a join past it, the app offers Follow only (#2217).
    public static let groupCap = 500

    public enum Kind: String, Codable, Sendable { case direct, group, channel }

    /// Who may find and join: members only (`private`), anyone (`public`), or
    /// shown on its showcases while joining waits for an admin
    /// (`listedOnRequest`, #995).
    public enum Visibility: String, Codable, Sendable { case `private`, `public`, listedOnRequest }

    public enum Role: String, Codable, Sendable { case owner, admin, member, subscriber, guest }

    /// The viewer's standing in a conversation.
    public enum ViewerState: String, Codable, Sendable {
        case owner, admin, member, subscriber, invited, requested, none, banned
    }

    /// A group's or a channel's identity and the viewer's place in it.
    public struct Details: Codable, Sendable, Equatable {
        public var conversationID: String
        public var kind: Kind
        public var name: String
        public var photoURL: String
        public var description: String
        public var visibility: Visibility
        public var memberCount: Int
        public var subscriberCount: Int
        public var viewerState: ViewerState
        /// Who invited the viewer, while `viewerState == .invited`.
        public var invitedBy: String

        public init(
            conversationID: String, kind: Kind, name: String = "", photoURL: String = "", description: String = "",
            visibility: Visibility = .private, memberCount: Int = 0, subscriberCount: Int = 0,
            viewerState: ViewerState = .none, invitedBy: String = ""
        ) {
            self.conversationID = conversationID
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
    }

    public struct Member: Codable, Sendable, Equatable {
        public var profileID: String
        public var role: Role
        public var joinedAtMs: Int64

        public init(profileID: String, role: Role, joinedAtMs: Int64) {
            self.profileID = profileID
            self.role = role
            self.joinedAtMs = joinedAtMs
        }
    }

    public struct JoinRequest: Codable, Sendable, Equatable {
        public var profileID: String
        public var requestedAtMs: Int64

        public init(profileID: String, requestedAtMs: Int64) {
            self.profileID = profileID
            self.requestedAtMs = requestedAtMs
        }
    }

    /// One call; `viewer` is the acting profile.
    public enum Call: Codable, Sendable, Equatable {
        case details(viewer: String, conversationIDs: [String])
        case members(viewer: String, conversationID: String)
        /// One page of `roles`' members, `limit` at most, after `pageToken`
        /// (empty: the first) — #995's paged `ListMembers` (#2237). The
        /// reply's `nextPageToken` (empty: the end) and `total`, every
        /// member of those roles, which is what a counter says.
        case membersPage(viewer: String, conversationID: String, roles: [Role], pageToken: String, limit: Int)
        case create(viewer: String, kind: Kind, name: String, photoURL: String, description: String,
                    visibility: Visibility, memberIDs: [String])
        case editIdentity(viewer: String, conversationID: String, name: String, photoURL: String, description: String)
        case invite(viewer: String, conversationID: String, profileIDs: [String])
        case answerInvitation(viewer: String, conversationID: String, accept: Bool)
        case requestToJoin(viewer: String, conversationID: String)
        case cancelJoinRequest(viewer: String, conversationID: String)
        case joinRequests(viewer: String, conversationID: String)
        case answerJoinRequest(viewer: String, conversationID: String, requester: String, approve: Bool)
        case setRole(viewer: String, conversationID: String, member: String, role: Role)
        case remove(viewer: String, conversationID: String, member: String, ban: Bool)
        case transferOwnership(viewer: String, conversationID: String, to: String)
        case leave(viewer: String, conversationID: String)
        case setVisibility(viewer: String, conversationID: String, visibility: Visibility)
        case subscribe(viewer: String, conversationID: String)
        case unsubscribe(viewer: String, conversationID: String)
        /// The channels `owner` owns that `viewer` may see, each read for
        /// the viewer (#2232, #995's "a profile's channels"): for a profile's
        /// Channels tab. Someone else's private channels never answer — a
        /// private conversation can't be probed — and a channel `owner` only
        /// admins is not theirs.
        case ownedChannels(viewer: String, owner: String)
    }

    /// What a call answers; `error` is a refusal ("CHT-…: …").
    public struct Reply: Codable, Sendable, Equatable {
        public var details: [Details]
        public var members: [Member]
        public var joinRequests: [JoinRequest]
        public var conversationID: String
        public var error: String
        /// A `membersPage`'s next page; nil or empty: none (#2237).
        public var nextPageToken: String?
        /// A `membersPage`'s total for its roles (#2237).
        public var total: Int?

        public init(
            details: [Details] = [], members: [Member] = [], joinRequests: [JoinRequest] = [],
            conversationID: String = "", error: String = "", nextPageToken: String? = nil, total: Int? = nil
        ) {
            self.details = details
            self.members = members
            self.joinRequests = joinRequests
            self.conversationID = conversationID
            self.error = error
            self.nextPageToken = nextPageToken
            self.total = total
        }
    }

    /// A call or a reply as the wire carries it.
    public static func wrap(_ value: some Encodable) throws -> Google_Protobuf_StringValue {
        var wrapped = Google_Protobuf_StringValue()
        wrapped.value = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return wrapped
    }

    public static func unwrap<Value: Decodable>(_ type: Value.Type, from wrapped: Google_Protobuf_StringValue) throws -> Value {
        try JSONDecoder().decode(type, from: Data(wrapped.value.utf8))
    }
}

/// The repository's side of `ProposedChat` (#2213).
public struct ProposedChatClient: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The server refused ("CHT-…: …").
        case refused(String)
        case transport(String)
    }

    private let client: any ProtocolClientInterface

    public init(client: any ProtocolClientInterface) {
        self.client = client
    }

    public func call(_ call: ProposedChat.Call) async throws -> ProposedChat.Reply {
        let request = try ProposedChat.wrap(call)
        let response: ResponseMessage<Google_Protobuf_StringValue> = await client.unary(
            path: ProposedChat.path, idempotencyLevel: .unknown, request: request, headers: [:]
        )
        switch response.result {
        case .success(let wrapped):
            let reply = try ProposedChat.unwrap(ProposedChat.Reply.self, from: wrapped)
            if !reply.error.isEmpty { throw Failure.refused(reply.error) }
            return reply
        case .failure(let error):
            throw Failure.transport(error.message ?? "code \(error.code)")
        }
    }
}
