import DesignSystem
import Foundation

/// View-ready projection of a `NotificationItem`: who (the bold part of the
/// sentence, and up to two faces), what they did, when, and what it was about.
public struct NotificationDisplayModel: Equatable, Sendable, Identifiable {
    /// One face in the row's avatar: the picture when there is one, the
    /// initials always (they are what shows until — or instead of — it).
    public struct Face: Equatable, Sendable {
        public let monogram: String
        public let avatarURL: URL?
    }

    public let id: String
    public let action: NotificationItem.Action
    /// The people, as the sentence opens: "Ava Moreau" or "Ava Moreau and 3
    /// others". Drawn bold.
    public let actorsText: String
    /// What they did: "liked your post". Drawn regular.
    public let phrase: String
    /// The whole sentence — the accessibility label's opening, and what the
    /// tests read.
    public let text: String
    public let timeText: String
    /// The primary sender's initials (kept for callers that draw one disc).
    public let monogram: String
    /// One face, or two for a row with more than one sender (the most recent
    /// in front).
    public let faces: [Face]
    /// The subject post's still, drawn at the trailing edge.
    public let thumbnailURL: URL?
    /// A text post's opening, drawn under the sentence.
    public let excerpt: String?
    public let isRead: Bool

    public init(item: NotificationItem, now: Date = Date()) {
        id = item.id
        action = item.action
        actorsText = Self.actors(for: item)
        phrase = Self.phrase(for: item)
        text = "\(actorsText) \(phrase)"
        timeText = RelativeAgeFormatter.short(from: item.createdAt, to: now)
        monogram = MonogramAvatarView.monogram(name: item.senderName, handle: "")
        var faces = [Face(monogram: monogram, avatarURL: item.senderAvatarURL)]
        if item.otherSenderCount > 0, let second = item.sampleSenders.first {
            faces.append(Face(monogram: MonogramAvatarView.monogram(name: second.name, handle: ""), avatarURL: second.avatarURL))
        }
        self.faces = faces
        thumbnailURL = item.subjectPreview?.thumbnailURL
        excerpt = item.subjectPreview?.thumbnailURL == nil ? item.subjectPreview?.excerpt : nil
        isRead = item.isRead
    }

    /// The row as VoiceOver reads it: the sentence, the text it is about, and
    /// how long ago.
    public var accessibilityText: String {
        let when = timeText == "now" ? "just now" : "\(timeText) ago"
        return [text, excerpt, when].compactMap { $0 }.joined(separator: ", ")
    }

    private static func actors(for item: NotificationItem) -> String {
        guard item.otherSenderCount > 0 else { return item.senderName }
        return "\(item.senderName) and \(item.otherSenderCount) other\(item.otherSenderCount == 1 ? "" : "s")"
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
}
