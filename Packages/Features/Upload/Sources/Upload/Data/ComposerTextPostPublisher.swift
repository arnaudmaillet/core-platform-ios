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
}
