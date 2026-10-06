import CoreModels
import DesignSystem
import Foundation

/// The posts carrying one `#tag` (#524): its most liked with a picture, and
/// all of them newest first, and how many there are.
///
/// ⚠️ FROM `search.v1`, until a posts-by-tag endpoint exists: a `#tag` query
/// over posts, sorted by POPULARITY for Top and RECENCY for Recent. The
/// engine indexes a post's tags with its caption, so a loose match is
/// possible on the fleet; the count is the tag's own (`HashtagHit`).
@MainActor
final class HashtagViewModel {
    /// The tag, lowercased and without its `#`.
    let tag: String
    /// Top: the gallery, so posts WITH a picture — a text post has no tile.
    private(set) var top: SearchPostSurfaceState = .loading
    /// Recent: every post, cards, newest first.
    private(set) var recent: SearchPostSurfaceState = .loading
    /// What Recent found when it fits in one page — every post there is —
    /// else the index's coarse count; nil until either is known.
    private(set) var postCount: Int?
    var onChange: (() -> Void)?

    static let pageSize: Int32 = 60

    private let repository: any SearchProviding

    init(tag: String, repository: any SearchProviding) {
        let bare = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        self.tag = bare.lowercased()
        self.repository = repository
    }

    /// `#tag`, as the screen and its empty states name it.
    var title: String { "#" + tag }

    /// "1 post", "12 posts", "1.2K posts".
    var countText: String? {
        postCount.map { $0 == 1 ? "1 post" : "\(CountFormatter.compactString(for: $0)) posts" }
    }

    func load() async {
        top = .loading
        recent = .loading
        onChange?()
        let query = title
        async let topHits = Self.attempt { [repository] in
            try await repository.searchPosts(matching: query, sort: .popularity, limit: Self.pageSize)
        }
        async let recentHits = Self.attempt { [repository] in
            try await repository.searchPosts(matching: query, sort: .recency, limit: Self.pageSize)
        }
        async let count = try? await repository.hashtagPostCount(tag)

        switch await topHits {
        case .success(let hits):
            let media = hits.filter(\.hasMedia).map(\.id)
            top = media.isEmpty ? .empty(query: query) : .posts(media)
        case .failure:
            top = .failed(message: "Couldn\u{2019}t load \(query).")
        }
        switch await recentHits {
        case .success(let hits):
            recent = hits.isEmpty ? .empty(query: query) : .posts(hits.map(\.id))
            // A first page that is not full is every post there is.
            if hits.count < Int(Self.pageSize) { postCount = hits.count }
        case .failure:
            recent = .failed(message: "Couldn\u{2019}t load \(query).")
        }
        if postCount == nil, let counted = await count { postCount = counted }
        onChange?()
    }

    private static func attempt(
        _ body: @Sendable () async throws -> [PostSearchHit]
    ) async -> Result<[PostSearchHit], Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
