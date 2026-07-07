import Foundation

/// View-ready projection of a `NotificationItem`: a finished sentence, a short
/// relative time, an avatar monogram, and the read state.
public struct NotificationDisplayModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let timeText: String
    public let monogram: String
    public let isRead: Bool

    public init(item: NotificationItem, now: Date = Date()) {
        id = item.id
        text = Self.text(for: item)
        timeText = Self.relativeShort(from: item.createdAt, to: now)
        monogram = Self.monogram(item.senderName)
        isRead = item.isRead
    }

    private static func text(for item: NotificationItem) -> String {
        let subject = item.otherSenderCount > 0
            ? "\(item.senderName) and \(item.otherSenderCount) other\(item.otherSenderCount == 1 ? "" : "s")"
            : item.senderName
        return "\(subject) \(phrase(for: item))"
    }

    private static func phrase(for item: NotificationItem) -> String {
        let onPost = item.postSubjectID != nil
        switch item.action {
        case .reaction: return onPost ? "liked your post" : "liked your comment"
        case .comment: return "commented on your post"
        case .reply: return "replied to you"
        case .mention: return "mentioned you"
        case .other: return "interacted with you"
        }
    }

    private static func monogram(_ name: String) -> String {
        let initials = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    private static func relativeShort(from date: Date, to now: Date) -> String {
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
