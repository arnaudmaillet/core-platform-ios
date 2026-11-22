import CoreModels
import EntityStore
import PostGrid

/// The posts the app holds, read synchronously, and their loads (#1862,
/// #1863): the feed's small mirror first, then the app's `EntityStore`.
/// Read by the Snap feed's construction, the grids and the app (a wallet's
/// gallery, a notification's post). Built once by `FeedFeatureBuilder`.
@MainActor
struct FeedHeldPosts {
    private let repository: any FeedProviding
    private let entities: any EntityReading & EntityWriting

    init(dependencies: FeedFeatureBuilder.Dependencies) {
        repository = dependencies.repository
        entities = dependencies.entities
    }

    public func galleryPosts(_ ids: [PostID]) async -> [PostID: GalleryPost] {
        var found: [PostID: FeedEntry] = [:]
        var missing: [PostID] = []
        for id in ids {
            if let entry = heldEntry(id) { found[id] = entry } else { missing.append(id) }
        }
        let repository = repository
        await withTaskGroup(of: (PostID, FeedEntry?).self) { group in
            for id in missing {
                group.addTask { (id, try? await repository.loadPost(id)) }
            }
            for await (id, entry) in group {
                if let entry { found[id] = entry }
            }
        }
        return found.mapValues(DiscoverRepository.galleryPost(from:))
    }

    @MainActor
    public func heldGalleryPost(_ id: PostID) -> GalleryPost? {
        guard var post = heldEntry(id).map(DiscoverRepository.galleryPost(from:)) else { return nil }
        // A like count the store does not know is the card's unknown state,
        // not a zero (#1863): the hydration's counter read fills it.
        if repository.peekPost(id) == nil, entities.post(id)?.likeCount == nil { post.reactionCount = nil }
        return post
    }


    /// `ids`' posts, loaded together and returned in `ids`' order; a post
    /// that cannot be loaded is left out (#1863).
    nonisolated static func loadConcurrently(_ ids: [PostID], from repository: any FeedProviding) async -> [FeedEntry] {
        let loaded = await withTaskGroup(of: (PostID, FeedEntry?).self) { group in
            for id in ids { group.addTask { (id, try? await repository.loadPost(id)) } }
            return await group.reduce(into: [PostID: FeedEntry]()) { found, pair in
                if let entry = pair.1 { found[pair.0] = entry }
            }
        }
        return ids.compactMap { loaded[$0] }
    }

    /// A post the app holds, read synchronously (#1862): the feed's small
    /// mirror (`peekPost`), then the app's `EntityStore` — whose device
    /// backing reloads hundreds of posts at launch the mirror never saw. The
    /// store's like count is a copy: a real load replaces it.
    func heldEntry(_ id: PostID) -> FeedEntry? {
        // A post deleted in this session is held by no one (#896).
        guard !entities.isDeleted(id) else { return nil }
        if let entry = repository.peekPost(id) { return entry }
        return Self.entry(id, in: entities)
    }

    /// `id` as `store` holds it: the post and its author, both needed.
    static func entry(_ id: PostID, in store: any EntityReading) -> FeedEntry? {
        guard let entity = store.post(id), let post = entity.post,
              let author = store.profile(post.authorID)?.summary
        else { return nil }
        return FeedEntry(post: post, author: author, likeCount: entity.likeCount ?? 0)
    }
}
