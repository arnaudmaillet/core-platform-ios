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
    /// The media asset behind it (media.v1, #990): what an upload produced,
    /// sent on CreatePost so the server ties the post to the asset — a
    /// stable key, unlike a SIGNED URL. Nil when unknown (an older snapshot,
    /// a URL-only post). Optional, so snapshots without it still decode.
    public let assetID: String?

    public init(
        url: URL?, thumbnailURL: URL?, mimeType: String, pixelWidth: Int, pixelHeight: Int,
        assetID: String? = nil
    ) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.assetID = assetID
    }

    /// width / height; 1 when dimensions are missing so layout never divides by zero.
    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// A voice post's voice (#2204, #2206): a property of a TEXT post's caption,
/// not a kind of post. A voice post is drawn as a text post whose caption is
/// the voice component.
///
/// - ⚠️ **Never in `attachments`:** every `attachments.isEmpty` test would
///   read the post as media, and the MIME would make it an image.
/// - ⚠️ **Never `audio_ref`:** that is the reusable sound — a text post has
///   no sound (#1999).
public struct PostVoice: Sendable, Equatable, Hashable, Codable {
    /// The audio asset (media.v1), the cache's stable key.
    public let assetID: String
    /// Where it plays from (signed, through `VoiceFileCache`).
    public let url: URL?
    public let duration: TimeInterval
    /// 100 levels, 0–31 (`VoiceWaveform`); empty when the summary has none.
    public let waveform: [UInt8]

    public init(assetID: String, url: URL?, duration: TimeInterval, waveform: [UInt8]) {
        self.assetID = assetID
        self.url = url
        self.duration = duration
        self.waveform = waveform
    }
}

/// A published post, hydrated for rendering.
public struct Post: Sendable, Equatable, Codable {
    public let id: PostID
    public let authorID: ProfileID
    public let caption: String
    public let attachments: [MediaAttachment]
    public let publishedAt: Date
    /// The caption's voice (#2206): a text post that speaks. Optional, so a
    /// snapshot stored before it decodes with none.
    public let voice: PostVoice?

    /// Whether the post speaks — the ONE test a surface reads to draw a
    /// voice (#2206), never a URL, a MIME or a caption.
    public var hasVoice: Bool { voice != nil }
    /// What the post shows as a card in its caption's place (#2216): a
    /// channel's showcase. Optional, so a snapshot stored before it decodes
    /// with none; the post stays a text post.
    public let embed: PostEmbed?
    // No "likes hidden" (#1713, the owner): a post's likes always show — the
    // client honours no hiding, and an old snapshot's key is ignored.

    public init(
        id: PostID, authorID: ProfileID, caption: String, attachments: [MediaAttachment], publishedAt: Date,
        voice: PostVoice? = nil, embed: PostEmbed? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.caption = caption
        self.attachments = attachments
        self.publishedAt = publishedAt
        self.voice = voice
        self.embed = embed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PostID.self, forKey: .id)
        authorID = try container.decode(ProfileID.self, forKey: .authorID)
        caption = try container.decode(String.self, forKey: .caption)
        attachments = try container.decode([MediaAttachment].self, forKey: .attachments)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        voice = try container.decodeIfPresent(PostVoice.self, forKey: .voice)
        // An embed this build can't read (a later case, a later state) is
        // none: the post still reads, as the text post it is (#2216).
        embed = (try? container.decodeIfPresent(PostEmbed.self, forKey: .embed)) ?? nil
    }
}

/// The author facts a feed cell renders; a subset of profile.v1.ProfileSummaryView.
public struct AuthorSummary: Sendable, Equatable, Codable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    /// The avatar frame the author wears (#943, `avatar_frame_id`): a
    /// catalogue item id, nil for none. Optional, so a snapshot stored
    /// before it decodes with none.
    public let avatarFrameID: String?
    /// Whether the person has a banner (#1859), when the view that showed them
    /// said: nil unknown. Optional, so a snapshot stored before it decodes
    /// as unknown. It only shapes a profile's skeleton.
    public let hasBanner: Bool?

    public init(
        id: ProfileID, handle: String, displayName: String, avatarURL: URL?, avatarFrameID: String? = nil,
        hasBanner: Bool? = nil
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarFrameID = avatarFrameID
        self.hasBanner = hasBanner
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
