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

        public init(profileID: String, handle: String, displayName: String, avatarURL: String) {
            self.profileID = profileID
            self.handle = handle
            self.displayName = displayName
            self.avatarURL = avatarURL
        }
    }

    public static let viewer = ViewerProfile(
        profileID: MockSocialDataset.viewerProfileID,
        handle: "you",
        displayName: "Demo Viewer",
        avatarURL: "mock://avatar/viewer?w=128&h=128"
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

    public init(store: MockPostStore) {
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
        let attachment = request.attachments.first
        let media = attachment.map { (url: $0.cdnURL, width: Int($0.width), height: Int($0.height)) }
        let postID = store.create(profileID: request.profileID, caption: request.caption, media: media)

        var response = Post_V1_CreatePostResponse()
        response.postID = postID
        response.profileID = request.profileID
        return .success(response)
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
