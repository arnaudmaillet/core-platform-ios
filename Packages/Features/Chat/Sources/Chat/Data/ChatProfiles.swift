import CoreModels
import Foundation

/// Someone in a conversation, as far as profile.v1 says (#2214): what a group
/// signs its rows with, lists as a member and names its row by.
public struct ChatProfile: Equatable, Sendable {
    public let id: ProfileID
    /// The display name; empty when the profile couldn't be read.
    public let name: String
    /// The raw @handle, without the "@"; nil when unknown.
    public let handle: String?
    public let avatarURL: URL?

    public init(id: ProfileID, name: String, handle: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
    }

    /// The first word of the name — the inbox's "Alice: …", the typing line's
    /// "Alice is typing". The handle when there is no name.
    public var firstName: String { Self.firstName(of: name, handle: handle) }

    /// The ONE place a first name is cut from a display name (#2214).
    public static func firstName(of name: String, handle: String? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.split(whereSeparator: \.isWhitespace).first { return String(first) }
        return handle ?? ""
    }
}

/// The names, handles and faces of people in a conversation (#2214), read
/// from the same caches the inbox's titles are hydrated into — a member the
/// inbox already named costs nothing.
public protocol ChatProfileLookup: Sendable {
    func profiles(_ ids: [ProfileID]) async -> [ProfileID: ChatProfile]
}

/// What the group screens need from the data plane (#2214): the group's own
/// reads and writes, the people in it, and who the viewer is.
public typealias GroupChatServicing = ConversationManaging & ChatProfileLookup & ViewerIdentityProviding

extension ChatRepository: ChatProfileLookup {
    /// One `GetProfileById` per id not cached yet, concurrently; the rest
    /// from the caches. An id whose profile couldn't be read is answered with
    /// an empty name, never left out: a row signed "Member" beats a missing
    /// row.
    public func profiles(_ ids: [ProfileID]) async -> [ProfileID: ChatProfile] {
        await hydrateNames(for: ids)
        var found: [ProfileID: ChatProfile] = [:]
        for id in ids {
            found[id] = ChatProfile(id: id, name: nameCache[id] ?? "", handle: handleCache[id], avatarURL: avatarCache[id])
        }
        return found
    }
}
