import Connect
import CoreContracts
import Foundation

/// Fake of comment.v1.CommentService over the shared dataset. Seeds a couple of
/// top-level comments per post (authored by dataset authors, so profile
/// hydration resolves) and accepts CreateComment.
public final class MockCommentService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    private let store = Store()

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/comment.v1.CommentService/ListTopLevel") { [self] (request: Comment_V1_ListTopLevelRequest) in
            var response = Comment_V1_ListCommentsResponse()
            response.comments = store.comments(for: request.postID, seed: seedComments(for: request.postID))
            return .success(response)
        }
        bff.register(path: "/comment.v1.CommentService/CreateComment") { [self] (request: Comment_V1_CreateCommentRequest) in
            let created = store.append(request)
            var response = Comment_V1_CreateCommentResponse()
            response.commentID = created.commentID
            response.postID = created.postID
            return .success(response)
        }
    }

    private func seedComments(for postID: String) -> [Comment_V1_CommentView] {
        let authors = dataset.authors
        guard authors.count >= 3 else { return [] }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            makeComment(id: "\(postID)-c0", postID: postID, author: authors[1].profileID, body: "Love this shot 🔥", ageMs: 20 * 60_000),
            makeComment(id: "\(postID)-c1", postID: postID, author: authors[2].profileID, body: "Where was this taken?", ageMs: 5 * 60_000)
        ].map {
            var view = $0
            view.createdAtMs = nowMs - view.createdAtMs
            return view
        }
    }

    private func makeComment(id: String, postID: String, author: String, body: String, ageMs: Int64) -> Comment_V1_CommentView {
        var view = Comment_V1_CommentView()
        view.commentID = id
        view.postID = postID
        view.authorID = author
        view.body = body
        view.createdAtMs = ageMs // turned into an absolute timestamp by the caller
        return view
    }

    /// Holds newly-created comments so they persist across ListTopLevel calls.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [String: [Comment_V1_CommentView]] = [:]

        func comments(for postID: String, seed: [Comment_V1_CommentView]) -> [Comment_V1_CommentView] {
            lock.withLock { (created[postID] ?? []) + seed }
        }

        func append(_ request: Comment_V1_CreateCommentRequest) -> (commentID: String, postID: String) {
            lock.withLock {
                var view = Comment_V1_CommentView()
                view.commentID = request.commentID
                view.postID = request.postID
                view.authorID = request.authorID
                view.body = request.body
                view.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                created[request.postID, default: []].insert(view, at: 0)
                return (request.commentID, request.postID)
            }
        }
    }
}
