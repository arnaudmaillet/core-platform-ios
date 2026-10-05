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
    /// Posts created this session. None of them existed when the seed was
    /// written, so no stranger has commented on them yet: they open with no
    /// comments, the way a post you have just published does on the fleet.
    private let postStore: MockPostStore?
    private let store = Store()
    /// The words a post's owner hides from their comments (backend #728).
    private let hiddenWords: @Sendable (String) -> [String]
    /// Whether a commenter may comment on a post owner's posts (backend
    /// #714's `CheckInteraction(COMMENT)`): (commenter, owner) → allowed.
    private let mayComment: @Sendable (String, String) -> Bool
    /// Whether the viewer's first three posts carry comments held for their
    /// review (a temporary interaction limit, backend #669).
    private let seedsHeldComments: Bool

    public init(
        dataset: MockSocialDataset,
        postStore: MockPostStore? = nil,
        hiddenWords: @escaping @Sendable (String) -> [String] = { _ in [] },
        mayComment: @escaping @Sendable (String, String) -> Bool = { _, _ in true },
        seedsHeldComments: Bool = false
    ) {
        self.dataset = dataset
        self.postStore = postStore
        self.hiddenWords = hiddenWords
        self.mayComment = mayComment
        self.seedsHeldComments = seedsHeldComments
    }

    /// The post a seeded held comment ("<post>-held-<n>") sits under.
    static func heldCommentPost(_ commentID: String) -> String? {
        guard let range = commentID.range(of: "-held-", options: .backwards) else { return nil }
        return String(commentID[..<range.lowerBound])
    }

    private func owner(of postID: String) -> String? {
        postStore?.record(for: postID)?.profileID ?? dataset.post(for: postID)?.authorProfileID
    }

    /// Drops comments matching the post owner's hidden words, for every
    /// reader but the commenter (the viewer, here). Whole words, case-
    /// insensitive; an entry with no letters or digits (an emoji) matches
    /// anywhere — comment.v1's rules.
    private func filtered(_ comments: [Comment_V1_CommentView], postID: String) -> [Comment_V1_CommentView] {
        guard let owner = postStore?.record(for: postID)?.profileID ?? dataset.post(for: postID)?.authorProfileID else {
            return comments
        }
        let words = hiddenWords(owner)
        guard !words.isEmpty else { return comments }
        return comments.filter { comment in
            comment.authorID == MockSocialDataset.viewerProfileID || !Self.matches(comment.body, any: words)
        }
    }

    static func matches(_ body: String, any words: [String]) -> Bool {
        let text = body.lowercased()
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains { word in
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return text.contains(word) }
            let phrase = word.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard !phrase.isEmpty, phrase.count <= tokens.count else { return false }
            return (0...(tokens.count - phrase.count)).contains { Array(tokens[$0..<($0 + phrase.count)]) == phrase }
        }
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/comment.v1.CommentService/ListTopLevel") { [self] (request: Comment_V1_ListTopLevelRequest) in
            var response = Comment_V1_ListCommentsResponse()
            response.comments = filtered(store.comments(for: request.postID, seed: seedComments(for: request.postID)), postID: request.postID)
            return .success(response)
        }
        // The post's owner approves (it shows to everyone) or declines (it is
        // removed) a held comment. Not found for anyone else, and once
        // reviewed — comment.v1's rules, so a held comment's existence
        // doesn't leak.
        bff.register(path: "/comment.v1.CommentService/ReviewHeldComment") { [self] (request: Comment_V1_ReviewHeldCommentRequest) -> Result<Comment_V1_CommandResponse, ConnectError> in
            guard let postID = Self.heldCommentPost(request.commentID),
                  owner(of: postID) == request.ownerID,
                  seedComments(for: postID).contains(where: { $0.commentID == request.commentID && $0.held }),
                  store.review(request.commentID, approve: request.approve)
            else {
                return .failure(ConnectError(code: .notFound, message: "CMT-1001: comment not found"))
            }
            return .success(Comment_V1_CommandResponse())
        }
        bff.register(path: "/comment.v1.CommentService/ListReplies") { [self] (request: Comment_V1_ListRepliesRequest) in
            var response = Comment_V1_ListCommentsResponse()
            response.comments = filtered(store.replies(
                for: request.commentID,
                postID: request.postID,
                seed: seedReplies(for: request.postID)[request.commentID] ?? []
            ), postID: request.postID)
            return .success(response)
        }
        bff.register(path: "/comment.v1.CommentService/CreateComment") { [self] (request: Comment_V1_CreateCommentRequest) -> Result<Comment_V1_CreateCommentResponse, ConnectError> in
            // Your own post always takes your comments; anyone else's
            // follows its owner's "Who Can Comment".
            if let owner = postStore?.record(for: request.postID)?.profileID ?? dataset.post(for: request.postID)?.authorProfileID,
               owner != request.authorID, !mayComment(request.authorID, owner) {
                return .failure(ConnectError(code: .permissionDenied, message: "CMT-1005: the author doesn't take comments from you"))
            }
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

    /// Media posts seeded with a sparse set of comments that are ALL
    /// reaction-shaped — below the band's `minTickerCount`, so the band
    /// renders nothing and every one of them falls through to the subtitle
    /// zone via its shape-blind pass. The zone then has to render "W" and
    /// "🔥🔥" in a pill sized for sentences, which is the only place that
    /// typography is exercised; without a fixture it can only be reasoned
    /// about, not looked at. Adjacent to the zero-comment pair and in the
    /// same order — post-0012 (video) then post-0013 (image).
    private static let reactionOnlySparsePostIDs: Set<String> = ["post-0012", "post-0013"]

    /// Deliberately the short end of the reaction bank: one grapheme, a bare
    /// emoji run, and a two-letter token. Three is under the band's gate of
    /// six, which is what routes them to the zone.
    private static let reactionOnlySparseBank: [String] = ["W", "🔥🔥", "GG"]

    /// Micro-reaction bodies for the dense seed — the ticker is a reaction
    /// dump, so the bank is emoji runs and short slang, not sentences. The
    /// three entries at indices 20–22 intentionally violate the ticker's
    /// filters (over-length, embedded newline, semantic phrase past the word
    /// cap) so mock mode also proves the filtering; the qualifying remainder
    /// stays well above the band's minimum gate.
    ///
    /// ⚠️ EVERY ENTRY BUT 20–22 MUST STAY A REACTION: at most
    /// `CommentTickerBuilder.maxCharacterCount` (20) GRAPHEMES — Swift's
    /// `count`, so an emoji is one and a `:code:` is its full spelling — and
    /// unique ignoring case. Lengthening one past 20 moves it to the subtitle
    /// zone and breaks `denselySeededPostFeedsBothSurfaces`. Entry 22 stays
    /// emoji-free: an emoji would make it reaction-shaped, and it is the one
    /// proving the word cap.
    ///
    /// Emoji are all from EmoteKit's bundled Noto subset, so they animate;
    /// two entries are a chat-spam run (5 and 7).
    private static let denseCommentBank: [String] = [
        "GG 🔥🔥",
        "W",
        "no way 😭",
        "so clean ✨",
        "POV: perfection 🥹",
        "goated 👑",
        "🔥🔥🔥",
        "LFG :lol:",
        "😭😭😭",
        "certified banger 🎶",
        "sheesh 💀 :lmao:",
        "the colors!! 🌈",
        "frame it.",
        "chef's kiss 🤌",
        "unreal 🔥",
        "instant follow 🫡",
        "this goes hard",
        "sound ON 🎶🔥",
        "😂😂😂😂😂😂😂",
        "im crying 😭😭",
        "Honestly, a whole documentary could be made about this clip :blush: 🍿🍿",
        "no\nway",
        "how is this so good",
        "10/10 🍿",
    ]

    /// The sparse two-comment seed every other post carries, picked by the
    /// post's number so the feed does not repeat one conversation 120 times.
    /// Two comments are under the band's gate whatever their shape, so these
    /// all speak in the subtitle zone.
    ///
    /// ⚠️ ENTRY 1 IS THE ORIGINAL PAIR, and post-0001 — the post the
    /// repository tests load — lands on it. A post id with no numeric suffix
    /// (the arrivals, the viewer's own) takes entry 0.
    private static let sparsePairs: [(String, String)] = [
        ("okay this is gorgeous 😍", "Need to know where this is :blush:"),
        ("Love this shot 🔥", "Where was this taken?"),
        ("The colours 🥹🥹", "Saving this for later"),
        ("Great shot.", "How long did this take you?"),
        ("haha :lol:", "Wait, is this the new place?"),
        ("Stunning ✨", "You always find the best light"),
        ("🔥🔥🔥🔥🔥🔥", "Take me with you next time"),
        ("This is so good", "Instantly my favourite post today 💯"),
        ("Obsessed 😍😍", "Need this as a wallpaper"),
        ("Beautiful.", "Such a vibe, honestly"),
        ("😂😂😂", "The second one :lmao:"),
    ]

    /// Semantic bodies for the subtitle zone's dense seed — full sentences
    /// that must fail the ticker's reaction filter and pass the subtitle
    /// builder's semantic shape (≥ 4 words), so the two surfaces partition
    /// the dense posts' comments deterministically.
    private static let semanticCommentBank: [String] = [
        "The light in this is absolutely something else ✨",
        "I have rewatched this more times than I want to admit 😭😭",
        "Whoever did the edit understood the assignment completely 👏👏👏",
        "This is exactly why I keep coming back to this app 😂",
        "The pacing on that last cut is genuinely perfect.",
        "Feels like a memory I never actually had, somehow 🥹",
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
        let offset = Self.idOffset(postID)
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
            // A POPULAR thread: six replies, so the stream's "view more
            // replies" truncation (threshold 2) has a real pool to expand.
            // The two sentences land in the subtitle zone, the four short
            // reactions in the ticker band — the partition stays exact.
            semParent: [
                reply(semParent, 0, "So true, the framing carries it.", ageMs: 6 * 60_000),
                reply(semParent, 1, "came here to say exactly this :lol:", ageMs: 4 * 60_000),
                reply(semParent, 2, "this.", ageMs: 3 * 60_000),
                reply(semParent, 3, "so real 😭", ageMs: 2 * 60_000),
                reply(semParent, 4, "💯💯", ageMs: 90_000),
                reply(semParent, 5, "not wrong", ageMs: 60_000),
            ],
            denseParent: [
                reply(denseParent, 0, "fr fr 🔥", ageMs: 2 * 60_000),
            ],
        ]
    }

    private func seedComments(for postID: String) -> [Comment_V1_CommentView] {
        guard !Self.zeroCommentPostIDs.contains(postID) else { return [] }
        // Authored this session: no seed, only what CreateComment adds.
        guard postStore?.record(for: postID) == nil else { return [] }
        let authors = dataset.authors
        guard authors.count >= 3 else { return [] }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let raw: [Comment_V1_CommentView]
        if Self.reactionOnlySparsePostIDs.contains(postID) {
            let offset = Self.idOffset(postID)
            raw = Self.reactionOnlySparseBank.indices.map { position in
                makeComment(
                    id: "\(postID)-react-\(position)",
                    postID: postID,
                    author: authors[(offset + position) % authors.count].profileID,
                    body: Self.reactionOnlySparseBank[position],
                    ageMs: Int64(position + 1) * 4 * 60_000
                )
            }
        } else if Self.denselySeededPostIDs.contains(postID) {
            // Rotate the bank by the post's index so each dense post gets a
            // different (but stable) slice, authors cycling the whole cast.
            let offset = Self.idOffset(postID)
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
            let pair = Self.sparsePairs[Self.idOffset(postID) % Self.sparsePairs.count]
            raw = [
                makeComment(id: "\(postID)-c0", postID: postID, author: authors[1].profileID, body: pair.0, ageMs: 20 * 60_000),
                makeComment(id: "\(postID)-c1", postID: postID, author: authors[2].profileID, body: pair.1, ageMs: 5 * 60_000)
            ] + heldSeed(for: postID, authors: authors)
        }
        return raw.map {
            var view = $0
            view.createdAtMs = nowMs - view.createdAtMs
            return view
        }
    }

    /// Two comments held for the owner's review, newest first, on the
    /// viewer's first three posts (video, image, text) — only with `seedsHeldComments`.
    private func heldSeed(for postID: String, authors: [MockSocialDataset.Author]) -> [Comment_V1_CommentView] {
        guard seedsHeldComments, ["post-me-00", "post-me-01", "post-me-02"].contains(postID) else { return [] }
        let bodies = ["Is this for real? Send me the link", "First! Check out my page"]
        return bodies.indices.map { position in
            var view = makeComment(
                id: "\(postID)-held-\(position)",
                postID: postID,
                author: authors[(3 + position) % authors.count].profileID,
                body: bodies[position],
                ageMs: Int64(position + 1) * 2 * 60_000
            )
            view.held = true
            return view
        }
    }

    /// The number a post id ends with — "post-0012" → 12, "post-world-102"
    /// → 102 — what rotates each post's slice of the banks. Never negative:
    /// `Int(postID.suffix(4))` read the world seed's "post-world-102" as -102
    /// and indexed the banks out of range (a crash on opening the post).
    static func idOffset(_ postID: String) -> Int {
        Int(String(postID.suffix(4).reversed().prefix { $0.isNumber }.reversed())) ?? 0
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
        /// Held comments the owner reviewed: true approved, false declined.
        private var reviewed: [String: Bool] = [:]

        func comments(for postID: String, seed: [Comment_V1_CommentView]) -> [Comment_V1_CommentView] {
            // Top-level only, faithfully: created replies surface through
            // ListReplies, never in the top-level page.
            lock.withLock {
                ((created[postID] ?? []).filter { $0.parentID.isEmpty } + seed).compactMap { comment in
                    guard comment.held, let approved = reviewed[comment.commentID] else { return comment }
                    guard approved else { return nil }
                    var released = comment
                    released.held = false
                    return released
                }
            }
        }

        /// Records a review; false when the comment was already reviewed.
        func review(_ commentID: String, approve: Bool) -> Bool {
            lock.withLock {
                guard reviewed[commentID] == nil else { return false }
                reviewed[commentID] = approve
                return true
            }
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
