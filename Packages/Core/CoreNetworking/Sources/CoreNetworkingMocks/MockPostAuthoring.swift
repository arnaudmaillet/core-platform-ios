import Connect
import CoreContracts
import Foundation

/// Mutable store of client-authored posts, shared between the authoring mock
/// (writes) and MockSocialServices (reads), so a post created this session is
/// retrievable by GetPost and appears at the top of a refreshed feed — the
/// same coherence the real services provide.
public final class MockPostStore: @unchecked Sendable {
    struct DraftRecord {
        var postID: String
        var profileID: String
        var caption: String
        var media: (url: String, width: Int, height: Int)?
        var createdAtMS: Int64
        var published: Bool
    }

    /// The viewer's own profile, so hydration of their authored posts resolves.
    public struct ViewerProfile: Sendable {
        public let profileID: String
        public let handle: String
        public let displayName: String
        public let avatarURL: String
        public let bio: String
        public let websiteURL: String

        public init(
            profileID: String,
            handle: String,
            displayName: String,
            avatarURL: String,
            bio: String = "",
            websiteURL: String = ""
        ) {
            self.profileID = profileID
            self.handle = handle
            self.displayName = displayName
            self.avatarURL = avatarURL
            self.bio = bio
            self.websiteURL = websiteURL
        }
    }

    public static let viewer = ViewerProfile(
        profileID: MockSocialDataset.viewerProfileID,
        handle: "you",
        displayName: "Demo Viewer",
        // A real landscape photograph, so the viewer's own profile wears a
        // band — never a flat colour (see `syntheticAvatarURL`).
        avatarURL: MockSocialDataset.syntheticViewerAvatarURL,
        bio: "Kicking the tires. Everything here is mock data. 🤖",
        websiteURL: "https://www.example.com/demo/"
    )

    private let lock = NSLock()
    private var drafts: [String: DraftRecord] = [:]
    private var publishedNewestFirst: [String] = []

    public init() {}

    func create(profileID: String, caption: String, media: (url: String, width: Int, height: Int)?) -> String {
        let postID = "post-authored-\(UUID().uuidString.prefix(8))"
        lock.withLock {
            drafts[postID] = DraftRecord(
                postID: postID, profileID: profileID, caption: caption,
                media: media, createdAtMS: Int64(Date().timeIntervalSince1970 * 1000), published: false
            )
        }
        return postID
    }

    func publish(postID: String) -> Bool {
        lock.withLock {
            guard drafts[postID] != nil else { return false }
            drafts[postID]?.published = true
            publishedNewestFirst.removeAll { $0 == postID }
            publishedNewestFirst.insert(postID, at: 0)
            return true
        }
    }

    func record(for postID: String) -> DraftRecord? {
        lock.withLock { drafts[postID] }
    }

    /// Published authored posts, newest first — prepended to the feed.
    var publishedRecords: [DraftRecord] {
        lock.withLock { publishedNewestFirst.compactMap { drafts[$0] } }
    }
}

/// Fake of the post.v1 authoring path (CreatePost draft → PublishPost).
public final class MockPostAuthoringService: @unchecked Sendable {
    private let store: MockPostStore

    /// Whether `author` may mention the profile a handle names (backend
    /// #656): a post mentioning anyone who doesn't take it is refused
    /// (PST-1009) and nothing is stored.
    private let mayMention: @Sendable (_ author: String, _ handle: String) -> Bool

    public convenience init(store: MockPostStore) {
        self.init(store: store, mayMention: { _, _ in true })
    }

    public init(store: MockPostStore, mayMention: @escaping @Sendable (_ author: String, _ handle: String) -> Bool) {
        self.mayMention = mayMention
        self.store = store
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/post.v1.PostService/CreatePost") { [self] (request: Post_V1_CreatePostRequest) in
            createPost(request)
        }
        bff.register(path: "/post.v1.PostService/PublishPost") { [self] (request: Post_V1_PublishPostRequest) in
            publishPost(request)
        }
    }

    private func createPost(_ request: Post_V1_CreatePostRequest) -> Result<Post_V1_CreatePostResponse, ConnectError> {
        guard !request.profileID.isEmpty else {
            return .failure(ConnectError(code: .invalidArgument, message: "profile_id required"))
        }
        if let refused = Self.mentionedHandles(in: request.caption).first(where: { !mayMention(request.profileID, $0) }) {
            return .failure(ConnectError(code: .permissionDenied, message: "PST-1009: @\(refused) doesn't allow mentions from you"))
        }
        let attachment = request.attachments.first
        let media = attachment.map { (url: $0.cdnURL, width: Int($0.width), height: Int($0.height)) }
        let postID = store.create(profileID: request.profileID, caption: request.caption, media: media)

        var response = Post_V1_CreatePostResponse()
        response.postID = postID
        response.profileID = request.profileID
        return .success(response)
    }

    /// The `@handle`s in a caption, without the `@`.
    public static func mentionedHandles(in caption: String) -> [String] {
        var handles: [String] = []
        var scanner = caption[...]
        while let at = scanner.firstIndex(of: "@") {
            let rest = caption[caption.index(after: at)...]
            let handle = rest.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
            let trimmed = handle.hasSuffix(".") ? String(handle.dropLast()) : String(handle)
            if !trimmed.isEmpty { handles.append(trimmed) }
            scanner = rest
        }
        return handles
    }

    private func publishPost(_ request: Post_V1_PublishPostRequest) -> Result<Post_V1_CommandResponse, ConnectError> {
        guard store.publish(postID: request.postID) else {
            return .failure(ConnectError(code: .notFound, message: "draft \(request.postID) not found"))
        }
        var response = Post_V1_CommandResponse()
        response.success = true
        return .success(response)
    }
}
