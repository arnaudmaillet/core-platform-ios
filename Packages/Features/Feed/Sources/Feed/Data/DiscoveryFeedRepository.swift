import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// Which posts Discover may show — the active profile's Sensitive Content
/// setting (#407), as `timeline.v1.ContentLevel`.
public enum DiscoveryContentLevel: Equatable, Sendable {
    /// No age-gated posts. Every guest, every teen, and anyone on "Less".
    case restricted
    /// Age-gated posts included — an adult on "Standard". The server clamps
    /// teens and guests to restricted whatever is sent.
    case standard

    var proto: Timeline_V1_ContentLevel {
        self == .standard ? .standard : .restricted
    }
}

/// Who is reading Discover, as `GetDiscoveryFeed` asks: the content level,
/// and the profile whose interest tags rank the page (#413, timeline #662).
public struct DiscoveryReader: Equatable, Sendable {
    public var contentLevel: DiscoveryContentLevel
    /// The active profile; nil for a guest, whose page is never personalised.
    public var profileID: String?
    /// The profile's Personalised For You is off. The server enforces the
    /// stored setting anyway; sending it keeps one read honest meanwhile.
    public var nonPersonalized: Bool

    public init(contentLevel: DiscoveryContentLevel, profileID: String?, nonPersonalized: Bool) {
        self.contentLevel = contentLevel
        self.profileID = profileID
        self.nonPersonalized = nonPersonalized
    }

    public static let guest = DiscoveryReader(contentLevel: .restricted, profileID: nil, nonPersonalized: true)
}

/// For You's Discover corpus: `timeline.v1.GetDiscoveryFeed` (backend B3,
/// #448/#512) — one pool for guests and members alike, ranked by the
/// reader's interest tags when it keeps Personalised For You on (#413).
///
/// The RPC answers identifiers only, as the following feed does; the posts
/// are hydrated through the app's one feed repository (`base`), so a tile and
/// the snap feed it opens share one cache. A post the server serves again on a
/// later page (it moved between rankings) is dropped by the caller's
/// de-duplication (`ForYouViewModel`).
public actor DiscoveryFeedRepository: FeedProviding {
    private let timelineClient: any Timeline_V1_TimelineServiceClientInterface
    private let base: any FeedProviding
    private let reader: @Sendable () async -> DiscoveryReader
    private let region: @Sendable () -> String
    private let pageSize: Int32

    public init(
        timelineClient: any Timeline_V1_TimelineServiceClientInterface,
        base: any FeedProviding,
        reader: @escaping @Sendable () async -> DiscoveryReader = { .guest },
        region: @escaping @Sendable () -> String = { Locale.current.region?.identifier ?? "" },
        pageSize: Int32 = 20
    ) {
        self.timelineClient = timelineClient
        self.base = base
        self.reader = reader
        self.region = region
        self.pageSize = pageSize
    }

    public func cachedFirstPage() async -> [FeedEntry]? { nil }

    public func loadFirstPage() async throws -> FeedPage {
        try await loadPage(token: "")
    }

    public func loadPage(afterToken token: String) async throws -> FeedPage {
        try await loadPage(token: token)
    }

    public func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await base.loadPost(id)
    }

    public func prewarm(_ ids: [PostID]) async {
        await base.prewarm(ids)
    }

    public nonisolated func peekPost(_ id: PostID) -> FeedEntry? { base.peekPost(id) }

    public func remember(_ entry: FeedEntry) async {
        await base.remember(entry)
    }

    /// FOR_YOU: the server's default mix (trending, with fresh posts given a
    /// chance). The reader is asked on every first page and every page after,
    /// so a Sensitive Content or Personalised For You change applies from the
    /// next load.
    private func loadPage(token: String) async throws -> FeedPage {
        // "A page can hold fewer items than asked (even none) with a
        // non-empty token: keep paging" — the contract's words. A few hops,
        // so an empty first page never reads as an empty pool.
        var token = token
        for _ in 0..<3 {
            let page = try await fetchPage(token: token)
            guard page.entries.isEmpty, let next = page.nextPageToken else { return page }
            token = next
        }
        return try await fetchPage(token: token)
    }

    private func fetchPage(token: String) async throws -> FeedPage {
        var request = Timeline_V1_GetDiscoveryFeedRequest()
        request.ranking = .forYou
        request.region = region()
        let reader = await reader()
        request.contentLevel = reader.contentLevel.proto
        request.profileID = reader.profileID ?? ""
        request.nonPersonalized = reader.nonPersonalized
        request.pageToken = token
        request.limit = pageSize
        let response = await timelineClient.getDiscoveryFeed(request: request, headers: [:])
        let body: Timeline_V1_GetDiscoveryFeedResponse
        switch response.result {
        case .success(let value): body = value
        case .failure(let error): throw FeedError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        let entries = try await FixedPostsFeedProvider(
            base: base, ids: body.items.map { PostID($0.postID) }
        ).loadFirstPage().entries
        return FeedPage(
            entries: entries,
            nextPageToken: body.nextPageToken.isEmpty ? nil : body.nextPageToken,
            isCold: false
        )
    }
}
