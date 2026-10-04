import CoreModels
import Foundation

/// For You's corpus for a guest (guest mode).
///
/// A guest follows no one, so the following timeline — the corpus For You
/// reads for a member — has nothing to give them and fails. This serves the
/// posts the composition root hands it instead (`postIDs`, asked once per
/// first page), hydrated through the real repository exactly as a map pin's
/// feed is (`FixedPostsFeedProvider`).
///
/// ⚠️ INTERIM: the backend has no discovery feed yet (`GetDiscoveryFeed`,
/// #448). Until it does, the app supplies a viewer-free list it can already
/// read; when the RPC lands, `postIDs` becomes that call and nothing here
/// changes.
actor GuestDiscoveryFeedProvider: FeedProviding {
    private let base: any FeedProviding
    private let postIDs: @Sendable () async throws -> [PostID]

    init(base: any FeedProviding, postIDs: @escaping @Sendable () async throws -> [PostID]) {
        self.base = base
        self.postIDs = postIDs
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }

    func loadFirstPage() async throws -> FeedPage {
        let ids = try await postIDs()
        return try await FixedPostsFeedProvider(base: base, ids: ids).loadFirstPage()
    }

    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }

    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await base.loadPost(id)
    }

    func prewarm(_ ids: [PostID]) async {
        await base.prewarm(ids)
    }

    nonisolated func peekPost(_ id: PostID) -> FeedEntry? { base.peekPost(id) }

    func remember(_ entry: FeedEntry) async {
        await base.remember(entry)
    }
}
