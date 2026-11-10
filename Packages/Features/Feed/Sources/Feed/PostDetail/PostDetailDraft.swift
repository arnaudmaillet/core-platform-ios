import CoreModels
import FeedInterface

/// How a post that does not exist yet comes to exist: its first message,
/// published as the post, comes back as the entry it became.
///
/// `author` is the identity the composer showed when the message was sent
/// (nil only when none was known). The closure also primes whatever the
/// published page will read before the entry is returned.
struct PostDetailDraft: Sendable {
    let publish: @Sendable (_ text: String, _ author: AuthorSummary?) async throws -> FeedEntry
    /// A voice post's first message (#2209): the take, and the words under
    /// it. Nil: the draft takes text only (`-voice-posts` off).
    var publishVoice: (@Sendable (_ text: String, _ voice: TextPostVoice, _ author: AuthorSummary?) async throws -> FeedEntry)?
    /// A showcase's first message (#2216): the words, published with the
    /// attached card and the place the author gave it. Nil: the draft
    /// publishes no embed (`-channels` off).
    var publishShowcase: (@Sendable (
        _ text: String, _ embed: PostEmbed, _ place: TextPostPlace?, _ author: AuthorSummary?
    ) async throws -> FeedEntry)?

    init(
        publish: @escaping @Sendable (_ text: String, _ author: AuthorSummary?) async throws -> FeedEntry,
        publishVoice: (@Sendable (_ text: String, _ voice: TextPostVoice, _ author: AuthorSummary?) async throws -> FeedEntry)? = nil,
        publishShowcase: (@Sendable (
            _ text: String, _ embed: PostEmbed, _ place: TextPostPlace?, _ author: AuthorSummary?
        ) async throws -> FeedEntry)? = nil
    ) {
        self.publish = publish
        self.publishVoice = publishVoice
        self.publishShowcase = publishShowcase
    }
}

/// What a showcase's draft carries besides its words (#2216): the card the
/// composer opened with, and the place the author picked, if any.
struct DraftShowcase: Sendable, Equatable {
    var embed: PostEmbed
    var place: TextPostPlace?
}
