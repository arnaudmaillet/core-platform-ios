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

    /// Posts deliberately seeded with a dense set of short comments (18), so
    /// the snap feed's comment ticker (3-lane density, staggered speeds,
    /// infinite wrap-around) can be exercised deterministically in mock mode:
    /// the dataset's first three video posts and first three text-only posts.
    /// Every other post keeps the sparse two-comment seed — the ticker's
    /// minimum-engagement gate must keep the band hidden there.
    private static let denselySeededPostIDs: Set<String> = [
        "post-0000", "post-0003", "post-0006", // video pages (index % 3 == 0)
        "post-0002", "post-0005", "post-0008", // text-only pages (index % 3 == 2)
    ]

    /// Micro-reaction bodies for the dense seed — the ticker is a reaction
    /// dump, so the bank is emoji runs and short slang, not sentences. The
    /// three entries at indices 20–22 intentionally violate the ticker's
    /// filters (over-length, embedded newline, semantic phrase past the word
    /// cap) so mock mode also proves the filtering; the qualifying remainder
    /// stays well above the band's minimum gate.
    private static let denseCommentBank: [String] = [
        "GG 🔥🔥",
        "W",
        "no way 😭",
        "so clean",
        "POV: perfection",
        "goated 🐐",
        "🔥🔥🔥",
        "LFG!!",
        "😭😭😭",
        "certified banger",
        "sheesh 💀",
        "the colors!!",
        "frame it.",
        "chef's kiss 🤌",
        "unreal 🔥",
        "instant follow",
        "this goes hard",
        "sound ON 🔊",
        "🐐🐐🐐🐐",
        "im crying 😭😭",
        "Honestly, a whole documentary could be made about this clip.",
        "no\nway",
        "how is this so good",
        "10/10 🍿",
    ]

    private func seedComments(for postID: String) -> [Comment_V1_CommentView] {
        let authors = dataset.authors
        guard authors.count >= 3 else { return [] }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let raw: [Comment_V1_CommentView]
        if Self.denselySeededPostIDs.contains(postID) {
            // Rotate the bank by the post's index so each dense post gets a
            // different (but stable) slice, authors cycling the whole cast.
            let offset = Int(postID.suffix(4)) ?? 0
            let bank = Self.denseCommentBank
            raw = (0..<18).map { position in
                makeComment(
                    id: "\(postID)-dense-\(position)",
                    postID: postID,
                    author: authors[(offset + position) % authors.count].profileID,
                    body: bank[(offset + position) % bank.count],
                    ageMs: Int64(position + 1) * 3 * 60_000
                )
            }
        } else {
            raw = [
                makeComment(id: "\(postID)-c0", postID: postID, author: authors[1].profileID, body: "Love this shot 🔥", ageMs: 20 * 60_000),
                makeComment(id: "\(postID)-c1", postID: postID, author: authors[2].profileID, body: "Where was this taken?", ageMs: 5 * 60_000)
            ]
        }
        return raw.map {
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
