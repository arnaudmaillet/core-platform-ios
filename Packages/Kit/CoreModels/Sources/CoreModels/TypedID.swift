/// A phantom-typed wrapper over the UUID strings the platform contracts use
/// for every identifier. `AccountID` and `PostID` are distinct types, so
/// passing one where the other is expected is a compile error instead of a
/// production incident.
///
/// The raw value is deliberately an opaque `String`: the backend owns ID
/// semantics (UUIDv7 for posts, etc.); the client never parses or orders them.
public struct TypedID<Tag>: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Internal account identifier owned by AccountService (never the IdP subject).
public typealias AccountID = TypedID<AccountIDTag>
public enum AccountIDTag: Sendable {}

/// Public-facing profile identifier owned by ProfileService.
public typealias ProfileID = TypedID<ProfileIDTag>
public enum ProfileIDTag: Sendable {}

/// Post identifier (UUIDv7 on the wire).
public typealias PostID = TypedID<PostIDTag>
public enum PostIDTag: Sendable {}

/// Auth session identifier owned by AuthService.
public typealias SessionID = TypedID<SessionIDTag>
public enum SessionIDTag: Sendable {}

/// Chat conversation identifier owned by ChatService.
public typealias ConversationID = TypedID<ConversationIDTag>
public enum ConversationIDTag: Sendable {}

/// Media asset identifier owned by MediaService.
public typealias AssetID = TypedID<AssetIDTag>
public enum AssetIDTag: Sendable {}
