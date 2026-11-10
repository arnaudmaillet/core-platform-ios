import CoreModels
import DesignSystem
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
    /// The caption's voice, when voice posts are drawn (#2207, `-voice-posts`):
    /// the caption row is the voice component, its words under it.
    public let voice: PostVoice?

    /// A channel showcase's card, when showcases are drawn (#2216,
    /// `-channels`): under the caption's words. Off, a showcase is the text
    /// post it is — its caption.
    public let embed: PostEmbed?

    /// Whether the stream leads with a caption row: words, a voice, or a card.
    public var showsCaptionRow: Bool { hasCaption || voice != nil || embed != nil }

    /// Whether the post takes comments (#2216): a showcase takes none — the
    /// conversation is the channel (#2211). Likes and Share stay.
    public var takesComments: Bool { embed == nil }

    public init(
        entry: FeedEntry, now: Date = Date(), showsVoice: Bool = VoicePosts.areDrawn,
        showsEmbed: Bool = PostEmbeds.areDrawn
    ) {
        voice = showsVoice ? entry.post.voice : nil
        embed = PostEmbeds.shown(entry.post.embed, drawn: showsEmbed)
        postID = entry.post.id
        authorID = entry.author.id
        authorName = entry.author.displayName
        handle = "@" + entry.author.handle
        timestampText = Self.timestamp(entry.post.publishedAt, now: now)
        avatarURL = entry.author.avatarURL
        avatarMonogram = MonogramAvatarView.monogram(name: entry.author.displayName, handle: entry.author.handle)

        let trimmed = entry.post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        caption = trimmed
        hasCaption = !trimmed.isEmpty

        let attachment = entry.post.attachments.first
        mediaURL = attachment?.url
        mediaAspectRatio = attachment?.aspectRatio ?? 1
        hasMedia = attachment?.url != nil
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
