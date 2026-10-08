import Foundation

/// A media attachment as rendered by the client. Pixel dimensions come from
/// the contract (post.v1.MediaAttachmentView) and drive pre-layout: cell
/// heights are computed from `aspectRatio` off the main thread, never by
/// sizing views.
public struct MediaAttachment: Sendable, Equatable, Codable {
    public let url: URL?
    public let thumbnailURL: URL?
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(url: URL?, thumbnailURL: URL?, mimeType: String, pixelWidth: Int, pixelHeight: Int) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// width / height; 1 when dimensions are missing so layout never divides by zero.
    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// A published post, hydrated for rendering.
public struct Post: Sendable, Equatable, Codable {
    public let id: PostID
    public let authorID: ProfileID
    public let caption: String
    public let attachments: [MediaAttachment]
    public let publishedAt: Date
    /// The author hides like counts from this reader (#397, backend #809):
    /// the server withholds the number, and the app shows none — not a 0.
    public let likeCountsHidden: Bool

    public init(
        id: PostID, authorID: ProfileID, caption: String, attachments: [MediaAttachment], publishedAt: Date,
        likeCountsHidden: Bool = false
    ) {
        self.id = id
        self.authorID = authorID
        self.caption = caption
        self.attachments = attachments
        self.publishedAt = publishedAt
        self.likeCountsHidden = likeCountsHidden
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PostID.self, forKey: .id)
        authorID = try container.decode(ProfileID.self, forKey: .authorID)
        caption = try container.decode(String.self, forKey: .caption)
        attachments = try container.decode([MediaAttachment].self, forKey: .attachments)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        // Default keeps pre-existing snapshots decodable.
        likeCountsHidden = try container.decodeIfPresent(Bool.self, forKey: .likeCountsHidden) ?? false
    }
}

/// The author facts a feed cell renders; a subset of profile.v1.ProfileSummaryView.
public struct AuthorSummary: Sendable, Equatable, Codable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?

    public init(id: ProfileID, handle: String, displayName: String, avatarURL: URL?) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// One hydrated feed row: the post, its author, and the like count at
/// hydration time (live updates supersede it via the realtime plane).
public struct FeedEntry: Sendable, Equatable, Codable {
    public let post: Post
    public let author: AuthorSummary
    public let likeCount: Int64

    public init(post: Post, author: AuthorSummary, likeCount: Int64 = 0) {
        self.post = post
        self.author = author
        self.likeCount = likeCount
    }

    /// The like count to show, or nil when the author hides it from this
    /// reader (#397): a hidden count is no number at all, never a 0.
    public var visibleLikeCount: Int64? {
        post.likeCountsHidden ? nil : likeCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        post = try container.decode(Post.self, forKey: .post)
        author = try container.decode(AuthorSummary.self, forKey: .author)
        // Default keeps pre-existing snapshots decodable.
        likeCount = try container.decodeIfPresent(Int64.self, forKey: .likeCount) ?? 0
    }
}

/// One page of the following feed.
public struct FeedPage: Sendable, Equatable {
    public let entries: [FeedEntry]
    /// Opaque cursor; nil when the feed is exhausted.
    public let nextPageToken: String?
    /// True when the backend served cold storage and is warming its cache;
    /// the UI may surface a transient refreshing indicator.
    public let isCold: Bool
    /// True when this page is KNOWN to be the source's last: nothing at all
    /// follows it, not merely no cursor this provider can follow (#628).
    ///
    /// ⚠️ A nil `nextPageToken` alone does not say that. A feed opened from a
    /// grid's tile was a fixed window with no cursor, and its "last" post was
    /// routinely the middle of a result set. Only a provider that knows — a
    /// complete set (a map marker's posts), or a source's continuation that
    /// answered "nothing after this" — sets it. False by default.
    public let isEndOfSource: Bool

    public init(entries: [FeedEntry], nextPageToken: String?, isCold: Bool, isEndOfSource: Bool = false) {
        self.entries = entries
        self.nextPageToken = nextPageToken
        self.isCold = isCold
        self.isEndOfSource = isEndOfSource
    }
}
