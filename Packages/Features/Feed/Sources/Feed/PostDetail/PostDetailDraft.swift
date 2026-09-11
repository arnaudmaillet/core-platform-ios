import CoreModels

/// How a post that does not exist yet comes to exist: its first message,
/// published as the post, comes back as the entry it became.
///
/// The "+" menu's Text Post hands one to its panel's view model — see
/// `FeedFeatureBuilder.makeTextPostScreen`, which also primes everything the
/// published page will read before the entry is returned.
struct PostDetailDraft: Sendable {
    let publish: @Sendable (_ text: String, _ author: AuthorSummary?) async throws -> FeedEntry
}
