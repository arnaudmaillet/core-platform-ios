import CoreModels
import FeedInterface
import Foundation

/// The Text Post screen's publisher: Feed's seam, answered by the one pipeline
/// every post goes through.
///
/// One per screen, so its `intent` is that screen's publish intent (#795): a
/// retry of the same text as the same author goes under the same CreatePost
/// key, an edited text under a new one.
struct ComposerTextPostPublisher: TextPostPublishing {
    let composer: any PostComposing
    let intent = PublishIntentKey()

    func publishTextPost(_ text: String, as author: AuthorSummary?) async throws -> FeedEntry {
        let content = (author?.id.rawValue ?? "") + "\u{1F}" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = try await composer.publish(
            media: [], caption: text, as: author, idempotencyKey: intent.key(for: content)
        )
        intent.settle()
        return entry
    }

    /// A voice post (#2209): the take is uploaded, then the text post is
    /// created carrying it. The key covers the voice too: a new take is a new
    /// post.
    func publishTextPost(_ text: String, voice: TextPostVoice?, as author: AuthorSummary?) async throws -> FeedEntry {
        guard let voice else { return try await publishTextPost(text, as: author) }
        let authorID: String = author?.id.rawValue ?? ""
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = "\(authorID)\u{1F}\(trimmed)\u{1F}\(voice.fileURL.lastPathComponent)"
        let entry = try await composer.publishVoicePost(
            caption: text, voice: voice, as: author, idempotencyKey: intent.key(for: content)
        )
        intent.settle()
        return entry
    }

    /// A showcase (#2216): the text post created carrying the embed and the
    /// place. The key covers both: another channel, or another place, is
    /// another post.
    func publishTextPost(
        _ text: String, embed: PostEmbed, place: TextPostPlace?, as author: AuthorSummary?
    ) async throws -> FeedEntry {
        let content = Self.showcaseContent(text, embed: embed, place: place, author: author)
        let entry = try await composer.publishShowcasePost(
            caption: text, embed: embed, place: place, as: author, idempotencyKey: intent.key(for: content)
        )
        intent.settle()
        return entry
    }

    /// What a showcase's key is minted from (#795): the author, the words,
    /// the conversation and the place.
    static func showcaseContent(
        _ text: String, embed: PostEmbed, place: TextPostPlace?, author: AuthorSummary?
    ) -> String {
        let authorID: String = author?.id.rawValue ?? ""
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String
        switch embed {
        case .channel(let channel): target = "channel:" + channel.conversationID.rawValue
        }
        let point: String = place.map { "\($0.latitude),\($0.longitude)" } ?? ""
        return [authorID, trimmed, target, point].joined(separator: "\u{1F}")
    }
}
