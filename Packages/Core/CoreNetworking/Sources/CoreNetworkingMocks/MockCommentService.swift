import Connect
import CoreContracts
import Foundation

/// Fake of comment.v1.CommentService over the shared dataset. Seeds a couple of
/// top-level comments per post (authored by dataset authors, so profile
/// hydration resolves; a few posts are deliberately dense or empty — see the
/// seed sets below), level-2 replies on the dense posts (ListReplies), and
/// accepts CreateComment (parentID included, persisted at the right level).
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
        bff.register(path: "/comment.v1.CommentService/ListReplies") { [self] (request: Comment_V1_ListRepliesRequest) in
            var response = Comment_V1_ListCommentsResponse()
            response.comments = store.replies(
                for: request.commentID,
                postID: request.postID,
                seed: seedReplies(for: request.postID)[request.commentID] ?? []
            )
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

    /// Posts deliberately seeded with a dense comment set (18 micro-reactions
    /// + 6 semantic sentences), so both snap-feed comment surfaces — the
    /// conveyor band and the subtitle zone — can be exercised
    /// deterministically in mock mode, covering every media kind: video,
    /// image (whose bright synthesized fills are the legibility worst case
    /// the surfaces' contrast treatments exist for), and text-only. Every
    /// other post keeps the sparse two-comment seed — both surfaces'
    /// minimum-engagement gates must keep them hidden there. post-0001 stays
    /// sparse on purpose: repository tests pin its two-comment seed.
    private static let denselySeededPostIDs: Set<String> = [
        "post-0000", "post-0003", "post-0006", // video pages (index % 3 == 0)
        "post-0004", "post-0007", // image pages (index % 3 == 1; post-0001 stays sparse)
        "post-0002", "post-0005", "post-0008", // text-only pages (index % 3 == 2)
    ]

    /// Media posts seeded with NO comments at all (not even the sparse
    /// pair): the snap feed's comments empty state ("No comments yet")
    /// needs known-zero posts to render against. Adjacent and early —
    /// post-0009 (video) then post-0010 (image) — so a few swipes verify
    /// the pill over both media kinds back to back. Text-only pages render
    /// the empty shell, so a zero-comment text post would prove nothing.
    /// Comments composed via CreateComment still persist on these posts
    /// (the store prepends to the seed), which also exercises the empty
    /// state's exit once the composer exists.
    private static let zeroCommentPostIDs: Set<String> = ["post-0009", "post-0010"]

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

    /// Semantic bodies for the subtitle zone's dense seed — full sentences
    /// that must fail the ticker's reaction filter and pass the subtitle
    /// builder's semantic shape (≥ 4 words), so the two surfaces partition
    /// the dense posts' comments deterministically.
    private static let semanticCommentBank: [String] = [
        "The light in this is absolutely something else.",
        "I have rewatched this more times than I want to admit.",
        "Whoever did the edit understood the assignment completely.",
        "This is exactly why I keep coming back to this app.",
        "The pacing on that last cut is genuinely perfect.",
        "Feels like a memory I never actually had, somehow.",
    ]

    /// Level-2 seeds for the dense posts: a couple of replies under the
    /// first semantic comment and one under the first reaction, so the
    /// stream's 2-level rendering (indented reply rows directly under
    /// their parents) is verifiable on every dense page. Sparse posts
    /// carry none — post-0001's two-comment seed is pinned by repository
    /// tests and stays byte-identical.
    private func seedReplies(for postID: String) -> [String: [Comment_V1_CommentView]] {
        guard Self.denselySeededPostIDs.contains(postID) else { return [:] }
        let authors = dataset.authors
        guard authors.count >= 5 else { return [:] }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let offset = Int(postID.suffix(4)) ?? 0
        func reply(_ parent: String, _ position: Int, _ body: String, ageMs: Int64) -> Comment_V1_CommentView {
            var view = makeComment(
                id: "\(parent)-r\(position)",
                postID: postID,
                author: authors[(offset + position + 5) % authors.count].profileID,
                body: body,
                ageMs: 0
            )
            view.parentID = parent
            view.createdAtMs = nowMs - ageMs
            return view
        }
        let semParent = "\(postID)-sem-0"
        let denseParent = "\(postID)-dense-0"
        return [
            semParent: [
                reply(semParent, 0, "So true, the framing carries it.", ageMs: 6 * 60_000),
                reply(semParent, 1, "came here to say exactly this", ageMs: 4 * 60_000),
            ],
            denseParent: [
                reply(denseParent, 0, "fr fr 🔥", ageMs: 2 * 60_000),
            ],
        ]
    }

    private func seedComments(for postID: String) -> [Comment_V1_CommentView] {
        guard !Self.zeroCommentPostIDs.contains(postID) else { return [] }
        let authors = dataset.authors
        guard authors.count >= 3 else { return [] }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let raw: [Comment_V1_CommentView]
        if Self.denselySeededPostIDs.contains(postID) {
            // Rotate the bank by the post's index so each dense post gets a
            // different (but stable) slice, authors cycling the whole cast.
            let offset = Int(postID.suffix(4)) ?? 0
            let bank = Self.denseCommentBank
            let reactions = (0..<18).map { position in
                makeComment(
                    id: "\(postID)-dense-\(position)",
                    postID: postID,
                    author: authors[(offset + position) % authors.count].profileID,
                    body: bank[(offset + position) % bank.count],
                    ageMs: Int64(position + 1) * 3 * 60_000
                )
            }
            // The subtitle slice, appended after the reactions so the band's
            // seed (and the slices tests pin) stays byte-identical. Rotated
            // like the reaction bank so each post's cue order differs.
            let semantic = Self.semanticCommentBank
            let subtitles = semantic.indices.map { position in
                makeComment(
                    id: "\(postID)-sem-\(position)",
                    postID: postID,
                    author: authors[(offset + position + 3) % authors.count].profileID,
                    body: semantic[(offset + position) % semantic.count],
                    ageMs: Int64(position + 1) * 7 * 60_000
                )
            }
            raw = reactions + subtitles
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
            // Top-level only, faithfully: created replies surface through
            // ListReplies, never in the top-level page.
            lock.withLock { (created[postID] ?? []).filter { $0.parentID.isEmpty } + seed }
        }

        func replies(for commentID: String, postID: String, seed: [Comment_V1_CommentView]) -> [Comment_V1_CommentView] {
            lock.withLock { (created[postID] ?? []).filter { $0.parentID == commentID } + seed }
        }

        func append(_ request: Comment_V1_CreateCommentRequest) -> (commentID: String, postID: String) {
            lock.withLock {
                var view = Comment_V1_CommentView()
                view.commentID = request.commentID
                view.postID = request.postID
                view.authorID = request.authorID
                view.parentID = request.parentID
                view.body = request.body
                view.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                created[request.postID, default: []].insert(view, at: 0)
                return (request.commentID, request.postID)
            }
        }
    }
}
