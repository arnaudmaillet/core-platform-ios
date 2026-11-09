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
        let content = (author?.id.rawValue ?? "") + "\u{1F}" + text.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\u{1F}" + voice.fileURL.lastPathComponent
        let entry = try await composer.publishVoicePost(
            caption: text, voice: voice, as: author, idempotencyKey: intent.key(for: content)
        )
        intent.settle()
        return entry
    }
}
