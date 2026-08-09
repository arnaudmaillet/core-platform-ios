import AuthInterface
import CoreContracts
import CoreModels
import Foundation

public enum CommentsError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    case transport(message: String)
}

/// One top-level comment, hydrated with its author's display name (the
/// comment.v1 view carries only ids).
public struct CommentEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let authorID: ProfileID
    public let authorName: String
    public let authorHandle: String
    /// The author's avatar, hydrated from profile.v1 alongside the name/handle.
    /// Optional — an unresolved author (or one with no avatar) carries nil.
    public let authorAvatarURL: URL?
    public let body: String
    public let createdAt: Date
    /// The parent comment's id when this entry is a level-2 reply
    /// (comment.v1 carries exactly two levels: top-level and replies).
    /// Nil for top-level comments.
    public let parentID: String?

    public init(
        id: String,
        authorID: ProfileID,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: URL? = nil,
        body: String,
        createdAt: Date,
        parentID: String? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.body = body
        self.createdAt = createdAt
        self.parentID = parentID
    }
}

/// The signed-in viewer's display identity — what the composer needs to
/// render "you" BEFORE you have written anything. A comment carries its
/// author on the way back; the empty composer has no entry to read from,
/// so it asks for this directly.
public struct ViewerIdentity: Equatable, Sendable {
    public let name: String
    /// Optional at every step, exactly like a comment author's: no avatar,
    /// an unresolved profile, and a failed fetch all leave the monogram
    /// standing.
    public let avatarURL: URL?

    public init(name: String, avatarURL: URL?) {
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// What the comments UI consumes; implemented by `CommentsRepository`, faked in
/// view-model tests.
public protocol CommentsProviding: Sendable {
    func loadComments(for postID: PostID) async throws -> [CommentEntry]
    /// Who the viewer is, for the composer's avatar. Nil when nobody is
    /// signed in or the profile can't be resolved — the composer then shows
    /// its neutral placeholder rather than someone else's face.
    func viewerIdentity() async -> ViewerIdentity?
    /// Adopts `id` as the account profile that comments are posted AS.
    ///
    /// The account can hold several profiles and the viewer switches between
    /// them; without this the repository resolves the account's FIRST profile
    /// once and keeps it forever, so a switch would change the composer's
    /// face while the comment still arrived from the old identity.
    func setActiveViewer(_ id: ProfileID) async
    /// Posts a comment as the viewer and returns the created entry.
    /// `parentID` nil posts top-level; non-nil posts a level-2 reply under
    /// that top-level comment (comment.v1's two-depth contract).
    func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry
}

public extension CommentsProviding {
    /// Default: no viewer. The composer's avatar is an enhancement, so a
    /// provider that doesn't know who is signed in (every test fake, and
    /// any future read-only source) opts out by saying nothing.
    func viewerIdentity() async -> ViewerIdentity? { nil }
    /// Default: nothing to adopt, for providers with no notion of a viewer.
    func setActiveViewer(_ id: ProfileID) async {}
}

/// Reads/writes top-level comments via comment.v1, hydrating author names via
/// profile.v1.
public actor CommentsRepository: CommentsProviding {
    private let commentClient: any Comment_V1_CommentServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let authSession: any AuthSessionProviding
    private let pageSize: Int32

    private var viewerProfileID: ProfileID?
    private var authorCache: [ProfileID: (name: String, handle: String, avatarURL: URL?)] = [:]

    public init(
        commentClient: any Comment_V1_CommentServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        authSession: any AuthSessionProviding,
        pageSize: Int32 = 50
    ) {
        self.commentClient = commentClient
        self.profileClient = profileClient
        self.authSession = authSession
        self.pageSize = pageSize
    }

    // MARK: - CommentsProviding

    public func loadComments(for postID: PostID) async throws -> [CommentEntry] {
        var request = Comment_V1_ListTopLevelRequest()
        request.postID = postID.rawValue
        request.limit = pageSize
        let response = await commentClient.listTopLevel(request: request, headers: [:])
        let views: [Comment_V1_CommentView]
        switch response.result {
        case .success(let body): views = body.comments
        case .failure(let error): throw CommentsError.transport(message: error.message ?? "code \(error.code)")
        }

        // Level 2: fan out ListReplies per top-level comment, concurrently.
        // Replies are an enhancement — a failed (or unimplemented) replies
        // fetch yields an empty set for that parent, never a sunk thread.
        let client = commentClient
        let postIDValue = postID.rawValue
        let limit = pageSize
        let repliesByParent: [String: [Comment_V1_CommentView]] = await withTaskGroup(
            of: (String, [Comment_V1_CommentView]).self
        ) { group in
            for top in views {
                group.addTask {
                    var request = Comment_V1_ListRepliesRequest()
                    request.postID = postIDValue
                    request.commentID = top.commentID
                    request.limit = limit
                    let response = await client.listReplies(request: request, headers: [:])
                    switch response.result {
                    case .success(let body): return (top.commentID, body.comments)
                    case .failure: return (top.commentID, [])
                    }
                }
            }
            var result: [String: [Comment_V1_CommentView]] = [:]
            for await (parent, replies) in group where !replies.isEmpty {
                result[parent] = replies
            }
            return result
        }

        let thread = Self.threaded(topLevel: views, repliesByParent: repliesByParent)
        await hydrateAuthors(for: thread.map { ProfileID($0.authorID) })
        return thread.map(makeEntry)
    }

    public func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
        let viewer = try await resolveViewerProfileID()

        var request = Comment_V1_CreateCommentRequest()
        request.commentID = UUID().uuidString // client-supplied id for idempotency
        request.postID = postID.rawValue
        request.authorID = viewer.rawValue
        request.parentID = parentID ?? ""
        request.body = body
        let response = await commentClient.createComment(request: request, headers: [:])
        switch response.result {
        case .success(let created):
            await hydrateAuthors(for: [viewer])
            let author = authorCache[viewer] ?? (name: "You", handle: "", avatarURL: nil)
            return CommentEntry(
                id: created.commentID.isEmpty ? request.commentID : created.commentID,
                authorID: viewer,
                authorName: author.name,
                authorHandle: author.handle,
                authorAvatarURL: author.avatarURL,
                body: body,
                createdAt: Date(),
                parentID: parentID
            )
        case .failure(let error):
            throw CommentsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// The viewer's own profile, through the SAME hydration path and cache
    /// every comment author takes — so the composer's avatar and the
    /// viewer's own comment rows can never disagree about their face, and a
    /// second engagement costs no fetch. Best-effort: not signed in, no
    /// profile for the account, or a failed read all return nil.
    public func viewerIdentity() async -> ViewerIdentity? {
        guard let viewer = try? await resolveViewerProfileID() else { return nil }
        await hydrateAuthors(for: [viewer])
        guard let author = authorCache[viewer] else { return nil }
        return ViewerIdentity(name: author.name, avatarURL: author.avatarURL)
    }

    /// Overrides the resolved viewer — the same one-line move
    /// `ProfileRepository.setActiveProfile` makes, because the two actors
    /// hold SEPARATE caches of "who am I" and only the profile side hears
    /// about a switch. The author cache is keyed by profile id, so the new
    /// identity's name and avatar are already there if that profile has
    /// appeared in any thread.
    public func setActiveViewer(_ id: ProfileID) async {
        viewerProfileID = id
    }

    // MARK: - Hydration

    private func hydrateAuthors(for ids: [ProfileID]) async {
        let missing = Set(ids).filter { authorCache[$0] == nil && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }
        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, String, String, URL?)?.self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    guard let view = response.message else { return nil }
                    return (id, view.displayName, view.handle, URL(string: view.avatarURL))
                }
            }
            return await group.reduce(into: [(ProfileID, String, String, URL?)]()) { partial, tuple in
                if let tuple { partial.append(tuple) }
            }
        }
        for (id, name, handle, avatarURL) in fetched {
            authorCache[id] = (name, handle, avatarURL)
        }
    }

    private func makeEntry(from view: Comment_V1_CommentView) -> CommentEntry {
        let authorID = ProfileID(view.authorID)
        let author = authorCache[authorID] ?? (name: "Someone", handle: "", avatarURL: nil)
        return CommentEntry(
            id: view.commentID,
            authorID: authorID,
            authorName: author.name,
            authorHandle: author.handle,
            authorAvatarURL: author.avatarURL,
            body: view.body,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000),
            parentID: view.parentID.isEmpty ? nil : view.parentID
        )
    }

    /// The 2-level thread order the stream renders: each top-level comment
    /// in its listed order, immediately followed by its replies oldest-
    /// first (a conversation reads downward). Replies whose parent never
    /// arrived (a truncated top-level page) are dropped rather than
    /// stranded at the wrong depth. Pure and static — the threading
    /// contract is unit-tested without a network.
    static func threaded(
        topLevel: [Comment_V1_CommentView],
        repliesByParent: [String: [Comment_V1_CommentView]]
    ) -> [Comment_V1_CommentView] {
        topLevel.flatMap { top in
            [top] + (repliesByParent[top.commentID] ?? [])
                .sorted { $0.createdAtMs < $1.createdAtMs }
        }
    }

    private func resolveViewerProfileID() async throws -> ProfileID {
        if let viewerProfileID {
            return viewerProfileID
        }
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw CommentsError.notAuthenticated
        }
        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            guard let profile = body.profiles.first else { throw CommentsError.noProfileForAccount }
            let id = ProfileID(profile.profileID)
            viewerProfileID = id
            return id
        case .failure(let error):
            throw CommentsError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
