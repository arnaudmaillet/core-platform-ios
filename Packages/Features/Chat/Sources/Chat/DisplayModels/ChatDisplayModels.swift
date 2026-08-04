import CoreModels
import Foundation

/// View-ready row for the conversation list.
public struct ConversationDisplayModel: Equatable, Sendable, Identifiable {
    public let id: ConversationID
    public let title: String
    public let preview: String
    public let timeText: String
    public let monogram: String
    public let isPinned: Bool
    public let isMuted: Bool
    /// Drives the row's whole unread treatment — bold text and a badge — rather
    /// than sorting the conversation into a list of its own.
    public let isUnread: Bool
    /// How many messages are waiting, for the badge on the avatar. Zero
    /// whenever `isUnread` is false; see `Conversation.unreadCount` for what
    /// bounds it.
    public let unreadCount: Int

    public init(
        conversation: Conversation,
        now: Date = Date(),
        isPinned: Bool = false,
        isMuted: Bool = false,
        isUnread: Bool = false,
        unreadCount: Int = 0
    ) {
        id = conversation.id
        title = conversation.title
        preview = conversation.lastMessage
        timeText = conversation.lastActivityAt.map { Self.relativeShort(from: $0, to: now) } ?? ""
        monogram = Self.monogram(conversation.title)
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isUnread = isUnread
        self.unreadCount = unreadCount
    }

    static func monogram(_ title: String) -> String {
        let initials = title.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    static func relativeShort(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }
}

/// View-ready message bubble. `senderID`/`sentAt` stay raw here: run grouping
/// and time formatting are transcript concerns (see `ChatTranscript`).
public struct MessageDisplayModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let senderID: ProfileID
    public let body: String
    public let sentAt: Date
    public let isMine: Bool
    /// The id of the message this one replies to, if any — resolved into a
    /// quoted preview by the transcript builder.
    public let replyToID: String?

    public init(message: ChatMessage) {
        id = message.id
        senderID = message.senderID
        body = message.body
        sentAt = message.createdAt
        isMine = message.isMine
        replyToID = message.replyToID
    }
}
