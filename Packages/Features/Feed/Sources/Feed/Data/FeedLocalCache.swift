import CacheKit
import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import LocalStore
import OSLog
import SwiftProtobuf
import Synchronization

/// The feed lists the device keeps (#893): each tab's last pages, in the
/// LocalStore, so it opens on them at cold start and then revalidates.
///
/// Every list is its own (#890 owner addition 2): For You's Discover, For
/// You's following timeline and the pushed Following feed are three lists.
/// A post they share is ONE entity row (the store holds lists as keys), so
/// the fresher copy is what all three read.
///
/// Entities are stored as `post.v1` / `profile.v1` / `counter.v1` wire
/// bytes, built from the fields the client maps (`Post`, `AuthorSummary`,
/// the counters). A post's author and counters ride with the page that
/// carried the post (attachments), and go with it.
public final class FeedLocalCache: Sendable {
    /// One list's key in the store.
    public struct ListKey: Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) { self.rawValue = rawValue }

        /// The pushed Following feed (`FeedRepository`): what the JSON
        /// snapshot `feed-first-page` held before.
        public static let following = ListKey("feed.following")
        /// For You's Discover corpus (`GetDiscoveryFeed`).
        public static let forYouDiscover = ListKey("foryou.discover")
        /// For You's following timeline: its rows and the pushed lists.
        public static let forYouFollowing = ListKey("foryou.following")
    }

    /// A list read back as the feed renders it.
    public struct CachedList: Sendable, Equatable {
        public let entries: [FeedEntry]
        /// `counter.v1` numbers stored with the page, by post.
        public let counters: [PostID: PostCounters]
        /// Where the network pages on from.
        public let nextCursor: String?
        public let fetchedAt: Date
    }

    enum EntityType {
        static let post = "post"
        static let author = "profile.summary"
        /// `FeedEntry.likeCount`: the like count the timeline hydrated.
        static let likes = "post.likes"
        /// `counter.v1` likes and comments (For You's cards).
        static let counters = "post.counters"
        /// Where the viewer stands with an author (For You's rows).
        static let relation = "relation"
    }

    public let store: LocalStore
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "feed-cache")
    /// The posts of each list's prefetched pages not shown yet, page by page
    /// in list order (#970): what `didShow` promotes.
    private let prefetched = Mutex<[String: [Set<PostID>]]>([:])

    public init(store: LocalStore) {
        self.store = store
    }

    /// Who a page is being fetched for: captured BEFORE the network call and
    /// handed to the write, so a page that lands after a switch is dropped.
    public var viewer: LocalStoreViewer? { store.currentViewer }

    // MARK: - Lists

    /// The stored FIRST page, as feed entries, with its cursor: what a cold
    /// start opens on, and what the first load will answer again when nothing
    /// changed. Synchronous: one indexed read, cheap enough for a screen's
    /// first frame. Entries whose post or author is missing (or unreadable)
    /// are left out.
    public func firstPage(of key: ListKey) -> CachedList? {
        store.list(key.rawValue, maxPages: 1).map(Self.decode)
    }

    /// The stored page the network would answer for `cursor`: how a list
    /// keeps paging through what the device holds when the network cannot
    /// answer.
    public func page(after cursor: String, in key: ListKey) -> CachedList? {
        store.page(of: key.rawValue, after: cursor).map(Self.decode)
    }

    private static func decode(_ list: LocalList) -> CachedList {
        var entries: [FeedEntry] = []
        var countersByPost: [PostID: PostCounters] = [:]
        for entity in list.entries {
            guard entity.key.type == EntityType.post, let decoded = Self.post(from: entity) else { continue }
            let id = decoded.id.rawValue
            let authorKey = LocalEntityKey(type: EntityType.author, id: decoded.authorID.rawValue)
            guard let summary = list.attachments[authorKey].flatMap(Self.author(from:)) else { continue }
            let likes = list.attachments[LocalEntityKey(type: EntityType.likes, id: id)]
                .flatMap(Self.counters(from:))?.likes ?? 0
            entries.append(FeedEntry(post: decoded, author: summary, likeCount: likes))
            if let stored = list.attachments[LocalEntityKey(type: EntityType.counters, id: id)]
                .flatMap(Self.counters(from:)) {
                countersByPost[decoded.id] = stored
            }
        }
        return CachedList(entries: entries, counters: countersByPost, nextCursor: list.nextCursor, fetchedAt: list.fetchedAt)
    }

    /// Replaces `key` with its first page: the tab's `retained` page.
    public func storeFirstPage(
        _ entries: [FeedEntry], counters: [PostID: PostCounters] = [:], nextCursor: String?,
        in key: ListKey, as viewer: LocalStoreViewer?
    ) {
        // A new first page: the pages fetched ahead after the old one are gone.
        prefetched.withLock { $0[key.rawValue] = nil }
        do {
            try store.replaceList(
                key.rawValue, with: Self.page(entries, counters: counters, nextCursor: nextCursor, tier: .retained),
                as: viewer
            )
        } catch {
            logger.error("feed cache write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Appends the page fetched with `cursor`. `tier` is `recent` for a page
    /// the viewer scrolled to; a lookahead's pages (#970) are `speculative`
    /// until one of their posts is shown (`didShow`).
    public func storeNextPage(
        _ entries: [FeedEntry], counters: [PostID: PostCounters] = [:], nextCursor: String?,
        after cursor: String, in key: ListKey, as viewer: LocalStoreViewer?, tier: CacheTierForPage = .recent
    ) {
        do {
            let stored = try store.appendPage(
                Self.page(entries, counters: counters, nextCursor: nextCursor, tier: tier.tier),
                to: key.rawValue, after: cursor, as: viewer
            )
            if stored, tier == .speculative {
                let posts = Set(entries.map(\.post.id))
                prefetched.withLock { $0[key.rawValue, default: []].append(posts) }
            }
        } catch {
            logger.error("feed cache write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// How much a page beyond the first is worth keeping.
    public enum CacheTierForPage: Sendable {
        /// Scrolled to by the viewer.
        case recent
        /// Fetched ahead of the viewer, not shown yet.
        case speculative

        var tier: CacheTier { self == .recent ? .recent : .speculative }
    }

    /// The viewer was shown `post` (a cell about to display it): a list
    /// page fetched ahead that carries it, and every prefetched page before
    /// it, become `recent` (`LocalStore.markShown`), so they leave the
    /// speculative cap and count as used, not wasted (#970).
    ///
    /// Cheap on main: a lookup among the pages not shown yet, and the
    /// promotion runs on the store's writer queue.
    public func didShow(_ post: PostID) {
        let lists: [String] = prefetched.withLock { pending in
            var shown: [String] = []
            for (list, pages) in pending {
                guard let index = pages.firstIndex(where: { $0.contains(post) }) else { continue }
                shown.append(list)
                pending[list] = Array(pages.dropFirst(index + 1))
            }
            return shown
        }
        let entry = LocalEntityKey(type: EntityType.post, id: post.rawValue)
        for list in lists { store.markShown(entry, in: list) }
    }

    // MARK: - Entities (#896)

    /// A post as the device holds it, outside any list: what a cold start
    /// rebuilds the `EntityStore` from.
    public struct StoredPost: Sendable, Equatable {
        /// The post, its author, and its like count: the `counter.v1`
        /// read's when one is stored — what For You's cards draw — else the
        /// timeline's.
        public let entry: FeedEntry
        public let commentCount: Int64?
    }

    /// The stored posts, most recently used first, at most `limit`: each with
    /// its author and a like count. A post missing either is left out — a
    /// count of 0 standing in for an unknown one would be drawn. Read without
    /// counting as a use (`LocalStore.entities(ofType:limit:)`).
    public func storedPosts(limit: Int) -> [StoredPost] {
        let posts = store.entities(ofType: EntityType.post, limit: limit).compactMap(Self.post(from:))
        guard !posts.isEmpty else { return [] }
        var keys: [LocalEntityKey] = []
        keys.reserveCapacity(posts.count * 3)
        for post in posts {
            keys.append(LocalEntityKey(type: EntityType.author, id: post.authorID.rawValue))
            keys.append(LocalEntityKey(type: EntityType.likes, id: post.id.rawValue))
            keys.append(LocalEntityKey(type: EntityType.counters, id: post.id.rawValue))
        }
        let found = store.entities(keys, countsAsUse: false)
        return posts.compactMap { post in
            let id = post.id.rawValue
            guard let author = found[LocalEntityKey(type: EntityType.author, id: post.authorID.rawValue)]
                .flatMap(Self.author(from:)) else { return nil }
            let read = found[LocalEntityKey(type: EntityType.counters, id: id)].flatMap(Self.counters(from:))
            let timeline = found[LocalEntityKey(type: EntityType.likes, id: id)].flatMap(Self.counters(from:))
            guard let likes = read?.likes ?? timeline?.likes else { return nil }
            return StoredPost(
                entry: FeedEntry(post: post, author: author, likeCount: likes),
                commentCount: read?.comments
            )
        }
    }

    /// Forgets posts the server no longer serves (a delete): every stored
    /// list skips them from now on, the next cold start's included.
    public func forgetPosts(_ ids: Set<PostID>) {
        guard !ids.isEmpty else { return }
        let keys = ids.flatMap { id in
            [EntityType.post, EntityType.likes, EntityType.counters].map { LocalEntityKey(type: $0, id: id.rawValue) }
        }
        do {
            try store.removeEntities(keys)
        } catch {
            logger.error("feed cache forget failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Relations

    /// Where the viewer stood with each of `authors` when last asked.
    public func relations(for authors: Set<ProfileID>) -> [ProfileID: FollowRelation] {
        let keys = authors.map { LocalEntityKey(type: EntityType.relation, id: $0.rawValue) }
        var relations: [ProfileID: FollowRelation] = [:]
        for (key, entity) in store.entities(keys) {
            guard entity.format == 1, let relation = FollowRelation(storedName: String(decoding: entity.payload, as: UTF8.self)) else { continue }
            relations[ProfileID(key.id)] = relation
        }
        return relations
    }

    public func storeRelations(_ relations: [ProfileID: FollowRelation], as viewer: LocalStoreViewer?) {
        guard !relations.isEmpty else { return }
        do {
            try store.write(relations.map { id, relation in
                LocalEntityWrite(
                    key: LocalEntityKey(type: EntityType.relation, id: id.rawValue),
                    payload: Data(relation.storedName.utf8),
                    lifetime: LocalStorePolicy.profileLifetime,
                    tier: .recent
                )
            }, as: viewer)
        } catch {
            logger.error("feed cache write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Codec

    static func page(_ entries: [FeedEntry], counters: [PostID: PostCounters], nextCursor: String?, tier: CacheTier) -> LocalListPage {
        var writes: [LocalEntityWrite] = []
        writes.reserveCapacity(entries.count * 3)
        for entry in entries {
            let id = entry.post.id.rawValue
            writes.append(write(EntityType.post, id, postView(from: entry.post), lifetime: LocalStorePolicy.postLifetime))
            writes.append(write(EntityType.author, entry.author.id.rawValue, summaryView(from: entry.author), lifetime: LocalStorePolicy.profileLifetime))
            writes.append(write(EntityType.likes, id, snapshot(postID: id, likes: entry.likeCount, comments: nil), lifetime: LocalStorePolicy.counterLifetime))
            if let stored = counters[entry.post.id] {
                writes.append(write(EntityType.counters, id, snapshot(postID: id, likes: stored.likes, comments: stored.comments), lifetime: LocalStorePolicy.counterLifetime))
            }
        }
        return LocalListPage(
            items: entries.map { LocalEntityKey(type: EntityType.post, id: $0.post.id.rawValue) },
            entities: writes,
            nextCursor: nextCursor,
            tier: tier
        )
    }

    private static func write(_ type: String, _ id: String, _ message: some SwiftProtobuf.Message, lifetime: TimeInterval) -> LocalEntityWrite {
        // Serializing a generated message with no required fields cannot fail.
        let payload = (try? message.serializedBytes() as Data) ?? Data()
        return LocalEntityWrite(key: LocalEntityKey(type: type, id: id), payload: payload, format: 1, lifetime: lifetime)
    }

    static func postView(from post: Post) -> Post_V1_PostView {
        var view = Post_V1_PostView()
        view.postID = post.id.rawValue
        view.profileID = post.authorID.rawValue
        view.caption = post.caption
        view.attachments = post.attachments.map { attachment in
            var media = Post_V1_MediaAttachmentView()
            media.cdnURL = attachment.url?.absoluteString ?? ""
            media.thumbnailURL = attachment.thumbnailURL?.absoluteString ?? ""
            media.mimeType = attachment.mimeType
            media.width = UInt32(clamping: attachment.pixelWidth)
            media.height = UInt32(clamping: attachment.pixelHeight)
            // The media asset too (#907): what a cold-started video post is
            // made a banner from (#944). A row stored before it decodes
            // with none — the field's empty default.
            media.assetID = attachment.assetID ?? ""
            return media
        }
        view.publishedAtMs = Int64((post.publishedAt.timeIntervalSince1970 * 1000).rounded())
        view.likeCountsHidden = post.likeCountsHidden
        return view
    }

    static func post(from entity: LocalEntity) -> Post? {
        guard entity.format == 1, let view = try? Post_V1_PostView(serializedBytes: entity.payload) else { return nil }
        return FeedRepository.makePost(from: view)
    }

    static func summaryView(from author: AuthorSummary) -> Profile_V1_ProfileSummaryView {
        var view = Profile_V1_ProfileSummaryView()
        view.profileID = author.id.rawValue
        view.handle = author.handle
        view.displayName = author.displayName
        view.avatarURL = author.avatarURL?.absoluteString ?? ""
        view.avatarFrameID = author.avatarFrameID ?? ""
        return view
    }

    static func author(from entity: LocalEntity) -> AuthorSummary? {
        guard entity.format == 1, let view = try? Profile_V1_ProfileSummaryView(serializedBytes: entity.payload) else { return nil }
        return AuthorSummary(
            id: ProfileID(view.profileID), handle: view.handle, displayName: view.displayName,
            avatarURL: view.avatarURL.isEmpty ? nil : URL(string: view.avatarURL),
            avatarFrameID: view.avatarFrameID.isEmpty ? nil : view.avatarFrameID
        )
    }

    static func snapshot(postID: String, likes: Int64?, comments: Int64?) -> Counter_V1_CounterSnapshot {
        var snapshot = Counter_V1_CounterSnapshot()
        var entity = Counter_V1_EntityRef()
        entity.entityType = .post
        entity.id = postID
        snapshot.entity = entity
        // Absent and zero are different claims (`PostCounters`): a number the
        // server did not answer is not written.
        for (metric, value) in [(Counter_V1_CounterMetric.like, likes), (.comment, comments)] {
            guard let value else { continue }
            var counter = Counter_V1_CounterValue()
            counter.metric = metric
            counter.value = value
            snapshot.values.append(counter)
        }
        return snapshot
    }

    static func counters(from entity: LocalEntity) -> PostCounters? {
        guard entity.format == 1, let snapshot = try? Counter_V1_CounterSnapshot(serializedBytes: entity.payload) else { return nil }
        return PostCounters(
            likes: snapshot.values.first { $0.metric == .like }?.value,
            comments: snapshot.values.first { $0.metric == .comment }?.value
        )
    }
}

extension FollowRelation {
    /// The name stored for each relation. Fixed strings, never the case
    /// order: the file outlives the code.
    var storedName: String {
        switch self {
        case .viewer: "viewer"
        case .following: "following"
        case .mutual: "mutual"
        case .notFollowing: "notFollowing"
        case .followedBy: "followedBy"
        case .blocked: "blocked"
        case .requested: "requested"
        }
    }

    init?(storedName: String) {
        switch storedName {
        case "viewer": self = .viewer
        case "following": self = .following
        case "mutual": self = .mutual
        case "notFollowing": self = .notFollowing
        case "followedBy": self = .followedBy
        case "blocked": self = .blocked
        case "requested": self = .requested
        default: return nil
        }
    }
}
