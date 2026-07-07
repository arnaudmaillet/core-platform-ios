import CoreModels
import Foundation

/// View-ready projection of a `FeedEntry` for the detail screen. Engagement
/// (like count / liked) is tracked separately, like the feed cell.
public struct PostDetailDisplayModel: Sendable, Equatable {
    public let postID: PostID
    public let authorID: ProfileID
    public let authorName: String
    /// "@handle"
    public let handle: String
    public let timestampText: String
    public let avatarURL: URL?
    public let avatarMonogram: String
    public let caption: String
    public let hasCaption: Bool
    public let mediaURL: URL?
    public let mediaAspectRatio: Double
    public let hasMedia: Bool

    public init(entry: FeedEntry, now: Date = Date()) {
        postID = entry.post.id
        authorID = entry.author.id
        authorName = entry.author.displayName
        handle = "@" + entry.author.handle
        timestampText = Self.timestamp(entry.post.publishedAt, now: now)
        avatarURL = entry.author.avatarURL
        avatarMonogram = Self.monogram(displayName: entry.author.displayName, handle: entry.author.handle)

        let trimmed = entry.post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        caption = trimmed
        hasCaption = !trimmed.isEmpty

        let attachment = entry.post.attachments.first
        mediaURL = attachment?.url
        mediaAspectRatio = attachment?.aspectRatio ?? 1
        hasMedia = attachment?.url != nil
    }

    private static func monogram(displayName: String, handle: String) -> String {
        let source = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? handle : displayName
        let initials = source
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    private static func timestamp(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        // Same-day posts read as a time; older ones as a medium date.
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }
}
