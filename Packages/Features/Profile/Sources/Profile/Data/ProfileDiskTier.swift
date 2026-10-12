import CacheKit
import CoreModels
import Foundation
import LocalStore
import OSLog
import PostGrid

/// The device tier behind `ProfileCache` (#893): what a profile screen showed
/// last, kept in the LocalStore so a cold start opens the viewer's own profile
/// and the profiles they visited on it, then revalidates.
///
/// One entity per profile (`profile.screen`): the header, the viewer's
/// relationship and the gallery as far as it was loaded, with its cursors.
/// These are the screen's own projections, not one contract message (the
/// header joins `profile.v1` with `social_graph.v1` and `counter.v1` counts;
/// the grid is `GalleryPost`s), so they are stored as a versioned JSON record:
/// a format this build cannot read is a miss, never a crash.
///
/// Reads are synchronous (the main actor seeds a screen's first frame from
/// them); writes go to a serial queue, off the main thread.
final class ProfileDiskTier: Sendable {
    static let entityType = "profile.screen"
    /// Which profile is the viewer's own, for a cold start that cannot ask the
    /// network: one row, keyed `self`, in a store that is the viewer's alone.
    static let currentUserType = "profile.current"
    static let format = 1

    let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.profile-disk-tier", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "profile-cache")

    init(store: LocalStore) {
        self.store = store
    }

    /// Who the records written now belong to: captured on the main actor with
    /// the memory they copy, so a write landing after a switch is dropped.
    var viewer: LocalStoreViewer? { store.currentViewer }

    func record(for id: ProfileID) -> ProfileDiskRecord? {
        guard let entity = store.entity(LocalEntityKey(type: Self.entityType, id: id.rawValue)),
              entity.format == Self.format else { return nil }
        return try? JSONDecoder().decode(ProfileDiskRecord.self, from: entity.payload)
    }

    func currentUserID() -> ProfileID? {
        guard let entity = store.entity(LocalEntityKey(type: Self.currentUserType, id: "self")),
              entity.format == Self.format, !entity.payload.isEmpty else { return nil }
        return ProfileID(String(decoding: entity.payload, as: UTF8.self))
    }

    /// Writes `records` (and which one is the viewer's own) in one
    /// transaction, off the caller's thread. The viewer's own profile is
    /// `retained`; the others `recent`, least recently used first out.
    func save(_ records: [ProfileID: ProfileDiskRecord], currentUser: ProfileID?, as viewer: LocalStoreViewer?) {
        guard !records.isEmpty || currentUser != nil else { return }
        let store = store
        let logger = logger
        queue.async {
            let encoder = JSONEncoder()
            var writes: [LocalEntityWrite] = []
            for (id, record) in records {
                guard let payload = try? encoder.encode(record) else { continue }
                writes.append(LocalEntityWrite(
                    key: LocalEntityKey(type: Self.entityType, id: id.rawValue),
                    payload: payload, format: Self.format,
                    lifetime: LocalStorePolicy.profileLifetime,
                    tier: id == currentUser ? .retained : .recent
                ))
            }
            if let currentUser {
                writes.append(LocalEntityWrite(
                    key: LocalEntityKey(type: Self.currentUserType, id: "self"),
                    payload: Data(currentUser.rawValue.utf8), format: Self.format,
                    lifetime: LocalStorePolicy.profileLifetime, tier: .retained
                ))
            }
            do {
                try store.write(writes, as: viewer)
            } catch {
                logger.error("profile cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }
}

// MARK: - Record

/// What one profile screen showed, as stored. Mirrors of the screen's types,
/// so a change to those is a decision made here, with a format bump.
struct ProfileDiskRecord: Codable, Equatable {
    var profile: Header?
    var relationship: Relationship?
    var gallery: Gallery?

    struct Header: Codable, Equatable {
        var id: String
        var handle: String
        var displayName: String
        var bio: String
        var avatarURL: URL?
        var websiteURL: URL?
        var links: [Link]
        var isVerified: Bool
        var visibility: String
        var followers: Count
        var following: Count
        var reactions: Count
        var accountType: String
        var businessCategory: String?

        struct Link: Codable, Equatable {
            var label: String
            var url: String
        }
    }

    struct Count: Codable, Equatable {
        var kind: String
        var value: Int64
    }

    struct Relationship: Codable, Equatable {
        var kind: String
        var isFollowing = false
        var isMutual = false
        var isBlocked = false
    }

    struct Gallery: Codable, Equatable {
        var authored: Corpus?
        var tagged: Corpus?
    }

    struct Corpus: Codable, Equatable {
        var posts: [Post]
        var nextToken: String?
        var hasLaterPages: Bool
    }

    struct Post: Codable, Equatable {
        var id: String
        var kind: String
        var isRepost: Bool
        var pages: [Page]
        var caption: String
        var publishedAtMS: Int64
        var authorID: String?
        var authorName: String?
        var authorHandle: String?
        var authorAvatarURL: URL?
        var reactionCount: Int64?
        var commentCount: Int64?
        var likeCountsHidden: Bool

        struct Page: Codable, Equatable {
            var thumbnailURL: URL?
            var videoURL: URL?
            var aspectRatio: Double
        }
    }
}

// MARK: - Conversions

extension ProfileDiskRecord.Header {
    init(_ profile: UserProfile) {
        id = profile.id.rawValue
        handle = profile.handle
        displayName = profile.displayName
        bio = profile.bio
        avatarURL = profile.avatarURL
        websiteURL = profile.websiteURL
        links = profile.customLinks.map { Link(label: $0.label, url: $0.url) }
        isVerified = profile.isVerified
        visibility = switch profile.visibility {
        case .unspecified: "unspecified"
        case .public: "public"
        case .private: "private"
        }
        followers = ProfileDiskRecord.Count(profile.followerCount)
        following = ProfileDiskRecord.Count(profile.followingCount)
        reactions = ProfileDiskRecord.Count(profile.reactionCount)
        accountType = switch profile.accountType {
        case .personal: "personal"
        case .creator: "creator"
        case .business: "business"
        case .bot: "bot"
        }
        businessCategory = profile.businessCategory
    }

    var userProfile: UserProfile {
        let storedVisibility: ProfileVisibility = switch visibility {
        case "public": .public
        case "private": .private
        default: .unspecified
        }
        let storedType: AccountType = switch accountType {
        case "creator": .creator
        case "business": .business
        case "bot": .bot
        default: .personal
        }
        return UserProfile(
            id: ProfileID(id),
            handle: handle,
            displayName: displayName,
            bio: bio,
            avatarURL: avatarURL,
            websiteURL: websiteURL,
            customLinks: links.map { ProfileLink(label: $0.label, url: $0.url) },
            isVerified: isVerified,
            visibility: storedVisibility,
            followerCount: followers.estimate,
            followingCount: following.estimate,
            reactionCount: reactions.estimate,
            accountType: storedType,
            businessCategory: businessCategory
        )
    }
}

extension ProfileDiskRecord.Count {
    init(_ estimate: CountEstimate) {
        switch estimate {
        case .exact(let value): self.init(kind: "exact", value: value)
        case .atLeast(let value): self.init(kind: "atLeast", value: value)
        case .unavailable: self.init(kind: "unavailable", value: 0)
        }
    }

    var estimate: CountEstimate {
        switch kind {
        case "exact": .exact(value)
        case "atLeast": .atLeast(value)
        default: .unavailable
        }
    }
}

extension ProfileDiskRecord.Relationship {
    init(_ relationship: ProfileRelationship) {
        switch relationship {
        case .me: self.init(kind: "me")
        case .requested: self.init(kind: "requested")
        case .cannotFollow: self.init(kind: "cannotFollow")
        case .other(let following, let mutual, let blocked):
            self.init(kind: "other", isFollowing: following, isMutual: mutual, isBlocked: blocked)
        }
    }

    var relationship: ProfileRelationship? {
        switch kind {
        case "me": .me
        case "requested": .requested
        case "cannotFollow": .cannotFollow
        case "other": .other(isFollowing: isFollowing, isMutual: isMutual, isBlocked: isBlocked)
        default: nil
        }
    }
}

extension ProfileDiskRecord.Gallery {
    init(_ corpora: ProfileGalleryStore.Corpora) {
        authored = corpora.authored.map(ProfileDiskRecord.Corpus.init)
        tagged = corpora.tagged.map(ProfileDiskRecord.Corpus.init)
    }

    var corpora: ProfileGalleryStore.Corpora {
        ProfileGalleryStore.Corpora(authored: authored?.corpus, tagged: tagged?.corpus)
    }
}

extension ProfileDiskRecord.Corpus {
    init(_ corpus: ProfileGalleryStore.Corpus) {
        posts = corpus.posts.map(ProfileDiskRecord.Post.init)
        nextToken = corpus.nextToken
        hasLaterPages = corpus.hasLaterPages
    }

    var corpus: ProfileGalleryStore.Corpus {
        ProfileGalleryStore.Corpus(posts: posts.compactMap(\.galleryPost), nextToken: nextToken, hasLaterPages: hasLaterPages)
    }
}

extension ProfileDiskRecord.Post {
    init(_ post: GalleryPost) {
        id = post.id.rawValue
        kind = switch post.kind {
        case .photo: "photo"
        case .video: "video"
        case .text: "text"
        }
        isRepost = post.isRepost
        pages = post.pages.map { Page(thumbnailURL: $0.thumbnailURL, videoURL: $0.videoURL, aspectRatio: $0.aspectRatio) }
        caption = post.caption
        publishedAtMS = post.publishedAtMS
        authorID = post.authorID?.rawValue
        authorName = post.authorName
        authorHandle = post.authorHandle
        authorAvatarURL = post.authorAvatarURL
        reactionCount = post.reactionCount
        commentCount = post.commentCount
        likeCountsHidden = post.likeCountsHidden
    }

    var galleryPost: GalleryPost? {
        let postKind: GalleryPost.Kind
        switch kind {
        case "photo": postKind = .photo
        case "video": postKind = .video
        case "text": postKind = .text
        default: return nil
        }
        var post = GalleryPost(
            id: PostID(id),
            kind: postKind,
            isRepost: isRepost,
            pages: pages.map { GalleryPost.MediaPage(thumbnailURL: $0.thumbnailURL, videoURL: $0.videoURL, aspectRatio: $0.aspectRatio) },
            caption: caption,
            publishedAtMS: publishedAtMS,
            authorID: authorID.map { ProfileID($0) },
            authorName: authorName,
            authorHandle: authorHandle,
            authorAvatarURL: authorAvatarURL,
            reactionCount: reactionCount,
            commentCount: commentCount
        )
        post.likeCountsHidden = likeCountsHidden
        return post
    }
}
