import CoreModels
import Foundation
import PostGrid

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

    /// THE CARD'S register, not one of this screen's own.
    ///
    /// A text page is arrived at by a reveal that opens the gallery row INTO
    /// the page, so the row's closing line and the page's first line are the
    /// same line seen twice — and they were spelling the same instant three
    /// different ways. The card said "28 May", this said "28 May 2026" (a
    /// medium date), and the seeded projection said "12 weeks". The last frame
    /// of every close swapped one for another.
    ///
    /// Both producers now defer to `PostMetadata.compactAge`, which matters as
    /// much as which one won: seeded and hydrated have to agree with each
    /// other too, or the row rewrites itself the moment its entry lands.
    private static func timestamp(_ date: Date, now: Date) -> String {
        PostMetadata.compactAge(
            ofMillis: Int64(date.timeIntervalSince1970 * 1000), now: now
        )
    }
}
