import CoreModels
import FeedInterface

/// The Text Post screen's publisher: Feed's seam, answered by the one pipeline
/// every post goes through.
struct ComposerTextPostPublisher: TextPostPublishing {
    let composer: any PostComposing

    func publishTextPost(_ text: String, as author: AuthorSummary?) async throws -> FeedEntry {
        try await composer.publish(media: nil, caption: text, as: author)
    }
}
