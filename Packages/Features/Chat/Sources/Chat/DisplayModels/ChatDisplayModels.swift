import CoreModels
import Foundation

/// View-ready row for the conversation list.
public struct ConversationDisplayModel: Equatable, Sendable, Identifiable {
    public let id: ConversationID
    public let title: String
    public let preview: String
    public let timeText: String
    public let monogram: String

    public init(conversation: Conversation, now: Date = Date()) {
        id = conversation.id
        title = conversation.title
        preview = conversation.lastMessage
        timeText = conversation.lastActivityAt.map { Self.relativeShort(from: $0, to: now) } ?? ""
        monogram = Self.monogram(conversation.title)
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

/// View-ready message bubble.
public struct MessageDisplayModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let body: String
    public let isMine: Bool

    public init(message: ChatMessage) {
        id = message.id
        body = message.body
        isMine = message.isMine
    }
}
