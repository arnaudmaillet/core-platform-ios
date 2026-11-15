import CacheKit
import CoreModels

// The seams a feature takes instead of the concrete `EntityStore` (#2377).
//
// ⚠️ ONE STORE, NARROW VIEWS OF IT. The app keeps exactly one `EntityStore`
// (one post and one profile per id, #896); these protocols only say which part
// of it a consumer reads or writes. A feature that draws relation marks takes
// `any ProfileEntityReading & ProfileEntityWriting`, never the whole store,
// and its tests hand it a small fake instead of a real store and its cache
// coordinator.
//
// ⚠️ THE CONTRACT IS THE STORE'S, UNCHANGED. Reads are synchronous (a cell
// reads while it is configured); observers are called on the main actor after
// the write, with the ids that changed, and read the value back; a viewer
// change is `.everything`. A fake keeps those rules or the consumer's tests
// prove nothing.
//
// The store's lifecycle (`register(with:)`, `viewerDidChange()`, the follow
// channel) stays on `EntityStore`: only the app's composition calls it.

/// What a screen reads of the shared posts, and how it hears them move.
public protocol PostEntityReading: AnyObject, Sendable {
    /// The post, as a use: it becomes the most recently used of its tier.
    func post(_ id: PostID) -> PostEntity?
    /// Whether the post was deleted in this session: no write brings it back.
    func isDeleted(_ id: PostID) -> Bool
    /// Whether the viewer saved the post; nil while not known.
    func isSaved(_ id: PostID) -> Bool?
    /// Calls `handler` after every change to the post, and once on a viewer
    /// change. The post stays in memory while observed.
    func observePost(_ id: PostID, _ handler: @escaping @MainActor @Sendable (PostID) -> Void) -> EntityObservation
    /// Calls `handler` with the posts that changed, or `.everything`.
    func observePosts(_ handler: @escaping @MainActor @Sendable (EntityChange<PostID>) -> Void) -> EntityObservation
}

/// What a screen writes to the shared posts: what it loaded, what the viewer
/// did to them.
public protocol PostEntityWriting: AnyObject, Sendable {
    /// What a list loaded: the posts, their authors and their like counts.
    func upsert(_ entries: [FeedEntry], tier: CacheTier, counts freshness: CountFreshness)
    func mergeCounts(_ counts: [PostID: PostCounts], tier: CacheTier, freshness: CountFreshness)
    func setLikeCount(_ count: Int64, for id: PostID)
    func addLikes(_ delta: Int64, to id: PostID)
    func replacePost(_ post: Post)
    func deletePost(_ id: PostID)
    func restorePost(_ id: PostID)
    func setSaved(_ isSaved: Bool, for id: PostID)
}

/// What a screen reads of the shared people and where the viewer stands with
/// them, and how it hears them move.
public protocol ProfileEntityReading: AnyObject, Sendable {
    func profile(_ id: ProfileID) -> ProfileEntity?
    /// Where the viewer stands with the person; nil while not known.
    func relation(to id: ProfileID) -> FollowRelation?
    /// The best known identity of a person about to be opened (#1858).
    func knownIdentity(of id: ProfileID, stub: ProfileIdentityStub?) -> ProfileIdentityStub?
    /// Calls `handler` after every change to the person, and once on a viewer
    /// change. The person stays in memory while observed.
    func observeProfile(_ id: ProfileID, _ handler: @escaping @MainActor @Sendable (ProfileID) -> Void) -> EntityObservation
    /// Calls `handler` with the people who changed, or `.everything`.
    func observeProfiles(_ handler: @escaping @MainActor @Sendable (EntityChange<ProfileID>) -> Void) -> EntityObservation
}

/// What a screen writes to the shared people: who it showed, where the viewer
/// now stands with them.
public protocol ProfileEntityWriting: AnyObject, Sendable {
    /// A person as a screen showed them; `.ifUnknown` replaces nothing.
    func upsert(_ summary: AuthorSummary, tier: CacheTier, freshness: CountFreshness)
    /// Records where the viewer stands with the person (nil forgets it), and
    /// returns what was known before.
    @discardableResult
    func setRelation(_ relation: FollowRelation?, for id: ProfileID) -> FollowRelation?
    func applyFollowChange(_ change: FollowChange)
    func applyFollowRequestChange(_ change: FollowRequestChange)
}

/// Every read, for a consumer that draws both posts and people.
public typealias EntityReading = PostEntityReading & ProfileEntityReading
/// Every write, for a consumer that writes both posts and people.
public typealias EntityWriting = PostEntityWriting & ProfileEntityWriting

// ⚠️ NO DEFAULTED CONVENIENCES HERE. A requirement takes no default, and an
// extension overload beside `EntityStore`'s own defaulted methods makes calls
// on the concrete store ambiguous. A consumer through a protocol passes every
// argument.

extension EntityStore: PostEntityReading, PostEntityWriting, ProfileEntityReading, ProfileEntityWriting {}
