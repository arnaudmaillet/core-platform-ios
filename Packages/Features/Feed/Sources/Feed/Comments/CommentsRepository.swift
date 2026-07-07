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
    public let body: String
    public let createdAt: Date

    public init(id: String, authorID: ProfileID, authorName: String, authorHandle: String, body: String, createdAt: Date) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.body = body
        self.createdAt = createdAt
    }
}

/// What the comments UI consumes; implemented by `CommentsRepository`, faked in
/// view-model tests.
public protocol CommentsProviding: Sendable {
    func loadComments(for postID: PostID) async throws -> [CommentEntry]
    /// Posts a top-level comment as the viewer and returns the created entry.
    func addComment(_ body: String, to postID: PostID) async throws -> CommentEntry
}

/// Reads/writes top-level comments via comment.v1, hydrating author names via
/// profile.v1.
public actor CommentsRepository: CommentsProviding {
    private let commentClient: any Comment_V1_CommentServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let authSession: any AuthSessionProviding
    private let pageSize: Int32

    private var viewerProfileID: ProfileID?
    private var authorCache: [ProfileID: (name: String, handle: String)] = [:]

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

        await hydrateAuthors(for: views.map { ProfileID($0.authorID) })
        return views.map(makeEntry)
    }

    public func addComment(_ body: String, to postID: PostID) async throws -> CommentEntry {
        let viewer = try await resolveViewerProfileID()

        var request = Comment_V1_CreateCommentRequest()
        request.commentID = UUID().uuidString // client-supplied id for idempotency
        request.postID = postID.rawValue
        request.authorID = viewer.rawValue
        request.body = body
        let response = await commentClient.createComment(request: request, headers: [:])
        switch response.result {
        case .success(let created):
            await hydrateAuthors(for: [viewer])
            let author = authorCache[viewer] ?? (name: "You", handle: "")
            return CommentEntry(
                id: created.commentID.isEmpty ? request.commentID : created.commentID,
                authorID: viewer,
                authorName: author.name,
                authorHandle: author.handle,
                body: body,
                createdAt: Date()
            )
        case .failure(let error):
            throw CommentsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    // MARK: - Hydration

    private func hydrateAuthors(for ids: [ProfileID]) async {
        let missing = Set(ids).filter { authorCache[$0] == nil && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }
        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, String, String)?.self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    guard let view = response.message else { return nil }
                    return (id, view.displayName, view.handle)
                }
            }
            return await group.reduce(into: [(ProfileID, String, String)]()) { partial, triple in
                if let triple { partial.append(triple) }
            }
        }
        for (id, name, handle) in fetched {
            authorCache[id] = (name, handle)
        }
    }

    private func makeEntry(from view: Comment_V1_CommentView) -> CommentEntry {
        let authorID = ProfileID(view.authorID)
        let author = authorCache[authorID] ?? (name: "Someone", handle: "")
        return CommentEntry(
            id: view.commentID,
            authorID: authorID,
            authorName: author.name,
            authorHandle: author.handle,
            body: view.body,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000)
        )
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
