import CoreModels
import DesignSystem
import Foundation
import LocalStore
import OSLog

/// Search's resting screen on the device (#893), in the LocalStore: the
/// trending people open on their last list at a cold start, offline included,
/// then revalidate, or not at all inside their freshness window
/// (`LocalStorePolicy.trendingRevalidation`).
///
/// Only the server's half of the screen. The recent searches are the
/// viewer's own typing, kept by `RecentSearchStore` already.
///
/// One list (`search.trending`), one page: the people in their order, each
/// with the context their row last said ("Following", "12 followers"), so the
/// rows are whole on the first frame. A person is a versioned JSON record; a
/// format this build cannot read is a miss. Reads are synchronous (the
/// screen's first frame); writes go to a serial queue, each as the viewer
/// captured BEFORE its network call.
final class SearchLocalCache: Sendable {
    static let listKey = "search.trending"
    static let entityType = "search.creator"
    static let format = 1

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.search-local-cache", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "search-cache")

    init(store: LocalStore) {
        self.store = store
    }

    /// Who the trending list is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { store.currentViewer }

    /// The stored trending people, and when their list was fetched.
    struct Trending: Equatable {
        var creators: [ExploreCreator]
        var fetchedAt: Date
    }

    func trending() -> Trending? {
        guard let list = store.list(Self.listKey) else { return nil }
        let creators = list.entries.compactMap { entity -> ExploreCreator? in
            guard entity.format == Self.format,
                  let record = try? JSONDecoder().decode(Record.self, from: entity.payload) else { return nil }
            return record.creator
        }
        return Trending(creators: creators, fetchedAt: list.fetchedAt)
    }

    /// Replaces the stored list: the screen's `retained` page.
    func storeTrending(_ creators: [ExploreCreator], as viewer: LocalStoreViewer?) {
        let store = store
        let logger = logger
        queue.async {
            let encoder = JSONEncoder()
            let writes = creators.compactMap { creator -> LocalEntityWrite? in
                guard let payload = try? encoder.encode(Record(creator)) else { return nil }
                return LocalEntityWrite(
                    key: LocalEntityKey(type: Self.entityType, id: creator.id.rawValue),
                    payload: payload, format: Self.format, lifetime: LocalStorePolicy.profileLifetime
                )
            }
            let page = LocalListPage(items: writes.map(\.key), entities: writes, nextCursor: nil, tier: .retained)
            do {
                try store.replaceList(Self.listKey, with: page, as: viewer)
            } catch {
                logger.error("search cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }

    // MARK: - Record

    /// One person as stored. The context is a fixed word, never the case
    /// order: the file outlives the code.
    struct Record: Codable, Equatable {
        var id: String
        var displayName: String
        var handle: String
        var monogram: String
        var avatarURL: URL?
        /// "following", "followers" (with `followerCount`), or absent.
        var context: String?
        var followerCount: Int?

        init(_ creator: ExploreCreator) {
            id = creator.id.rawValue
            displayName = creator.displayName
            handle = creator.handle
            monogram = creator.monogram
            avatarURL = creator.avatarURL
            switch creator.context {
            case .following:
                context = "following"
            case .followerCount(let count):
                context = "followers"
                followerCount = count
            case .none, .newPostsCount:
                context = nil
            }
        }

        var creator: ExploreCreator {
            var creator = ExploreCreator(
                id: ProfileID(id), displayName: displayName, handle: handle, monogram: monogram, avatarURL: avatarURL
            )
            switch (context, followerCount) {
            case ("following", _): creator.context = .following
            case ("followers", let count?): creator.context = .followerCount(count)
            default: creator.context = .none
            }
            return creator
        }
    }
}
