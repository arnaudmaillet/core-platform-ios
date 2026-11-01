import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import LocalStore

public enum CommentsError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    /// CMT-1005: the post's author doesn't take comments from this viewer
    /// (their "Who Can Comment" setting, #397).
    case notAllowed
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension CommentsError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
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
    /// The author's avatar frame (#943), hydrated with the avatar; nil for
    /// none.
    public let authorAvatarFrameID: String?
    public let body: String
    public let createdAt: Date
    /// The parent comment's id when this entry is a level-2 reply
    /// (comment.v1 carries exactly two levels: top-level and replies).
    /// Nil for top-level comments.
    public let parentID: String?
    /// Held for the post owner's review (their temporary interaction limit,
    /// #416): only its author and the post's owner see it until it is
    /// approved.
    public let isHeld: Bool
    /// A top-level comment's replies on the server, held ones included
    /// (comment.v1 `reply_count`, #637) — what "View N more replies" counts
    /// from, since only the most popular two are loaded with the page. Nil
    /// for a reply, and wherever the count is not known (a record from an
    /// older build).
    public var replyCount: Int?

    public init(
        id: String,
        authorID: ProfileID,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: URL? = nil,
        authorAvatarFrameID: String? = nil,
        body: String,
        createdAt: Date,
        parentID: String? = nil,
        isHeld: Bool = false,
        replyCount: Int? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.authorAvatarFrameID = authorAvatarFrameID
        self.body = body
        self.createdAt = createdAt
        self.parentID = parentID
        self.isHeld = isHeld
        self.replyCount = replyCount
    }

    /// This comment once its post's owner approved it: shown to everyone.
    func released() -> CommentEntry {
        CommentEntry(
            id: id, authorID: authorID, authorName: authorName, authorHandle: authorHandle,
            authorAvatarURL: authorAvatarURL, authorAvatarFrameID: authorAvatarFrameID, body: body,
            createdAt: createdAt, parentID: parentID, replyCount: replyCount
        )
    }
}

/// The post owner's review of a comment held for them (#416): approving
/// shows it to everyone, declining removes it. A separate capability rather
/// than a `CommentsProviding` requirement, so read-only providers and test
/// fakes need not answer it.
public protocol HeldCommentReviewing: Sendable {
    /// Throws on failure. A comment that is no longer held — already
    /// reviewed, or deleted — is not an error: there is nothing left to do.
    func reviewHeldComment(_ commentID: String, approve: Bool) async throws
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
    /// The profile this identity IS. Nil from a source that knows only a face
    /// — a conversation signs its viewer "You" before it knows more.
    public let profileID: ProfileID?
    public let handle: String

    public init(name: String, avatarURL: URL?, profileID: ProfileID? = nil, handle: String = "") {
        self.name = name
        self.avatarURL = avatarURL
        self.profileID = profileID
        self.handle = handle
    }

    /// This identity as a post's author: what a post written under this face
    /// is published as. Nil without a profile — a face alone authors nothing.
    public var author: AuthorSummary? {
        profileID.map { AuthorSummary(id: $0, handle: handle, displayName: name, avatarURL: avatarURL) }
    }
}

/// One page of a post's comments, in thread order (each top-level comment
/// followed by its replies), and where the next one starts.
public struct CommentPage: Equatable, Sendable {
    public let entries: [CommentEntry]
    /// The cursor for the next page; nil when the server has no more.
    public let nextPageToken: String?
    /// Where each thread's replies continue after the ones this page carries
    /// (#637), by parent id: what "View N more replies" asks for next. A
    /// thread with nothing more has no entry.
    public let replyTokens: [String: String]

    public init(entries: [CommentEntry], nextPageToken: String?, replyTokens: [String: String] = [:]) {
        self.entries = entries
        self.nextPageToken = nextPageToken
        self.replyTokens = replyTokens
    }
}

/// What the comments UI consumes; implemented by `CommentsRepository`, faked in
/// view-model tests.
public protocol CommentsProviding: Sendable {
    /// The first page's entries — what the snap feed's comment streams carry.
    func loadComments(for postID: PostID) async throws -> [CommentEntry]
    /// A page of top-level comments, with their replies: the first one when
    /// `pageToken` is nil, otherwise the one that token starts (#589).
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage
    /// A page of top-level comments in `order` (#2007): `.recent` is
    /// `loadCommentsPage(for:after:)`; the ranked order is the server's
    /// POPULARITY (#977) — most liked first, ties to the newest. A ranked
    /// page is never the warmed first page: that one is Recent's.
    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage
    /// A page of one thread's replies, most popular first (#637): the first
    /// when `pageToken` is nil, otherwise the one that token starts. The
    /// page's `nextPageToken` is where the thread continues.
    func loadReplies(for postID: PostID, to parentID: String, after pageToken: String?) async throws -> CommentPage
    /// Loads the first page of top-level comments into a cache the panel can
    /// read WITHOUT awaiting, so a post opened later renders its comments on
    /// frame one instead of a skeleton. Idempotent and best-effort.
    func prefetchTopComments(for postID: PostID) async
    /// The prefetched first page, or nil. Synchronous by design: the panel
    /// mounts inside a layout pass, and anything it has to await it renders a
    /// skeleton for.
    nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]?
    /// The first comments of many posts in ONE call (#2003, `ListPreviews`),
    /// held as seeds `cachedTopComments` answers with until a first page is
    /// held. Returns the posts the call covered — those need no request of
    /// their own; an empty set (a failure, or a provider with no batch) leaves
    /// each to `prefetchTopComments`.
    func prefetchPreviews(for postIDs: [PostID]) async -> Set<PostID>
    /// Whether anything is held for `postID` — a first page, or a preview,
    /// even an empty one: what a warm skips.
    nonisolated func holdsComments(for postID: PostID) -> Bool
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
    ///
    /// ⚠️ **`commentID` IS THE IDEMPOTENCY KEY, AND IT BELONGS TO THE DRAFT
    /// (#795).** comment.v1 takes a client-supplied `comment_id`; it used to
    /// be a fresh UUID per CALL, so a retry after a lost answer posted the
    /// comment twice. The caller mints it once per comment the viewer wrote
    /// and sends it again with every retry of that comment
    /// (`PostDetailViewModel.unsent`).
    func addComment(
        _ body: String, to postID: PostID, parentID: String?, commentID: String
    ) async throws -> CommentEntry
    /// The viewer's identity as last resolved, or nil — never a fetch.
    /// Synchronous for the one screen whose bars wear the viewer before
    /// anything has loaded: the Text Post page, whose author IS the viewer.
    nonisolated func cachedViewerIdentity() -> ViewerIdentity?
    /// Records `entries` as `postID`'s first page, exactly as a load would —
    /// for a post whose comments the client knows without asking. A post it
    /// has just published has none.
    nonisolated func seedTopComments(_ entries: [CommentEntry], for postID: PostID)
}

public extension CommentsProviding {
    /// Providers that do not page answer with everything they have, once.
    func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        guard pageToken == nil else { return CommentPage(entries: [], nextPageToken: nil) }
        return CommentPage(entries: try await loadComments(for: postID), nextPageToken: nil)
    }
    /// Providers with no ranking answer every order with Recent's pages.
    func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        try await loadCommentsPage(for: postID, after: pageToken)
    }
    /// Providers that load every reply with its page have no more to give.
    func loadReplies(for postID: PostID, to parentID: String, after pageToken: String?) async throws -> CommentPage {
        CommentPage(entries: [], nextPageToken: nil)
    }
    /// Providers that do not prefetch simply keep the old behaviour: the
    /// panel awaits its load and shows a skeleton meanwhile.
    func prefetchTopComments(for postID: PostID) async {}
    nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { nil }
    /// Default: no batch — every post warms on its own.
    func prefetchPreviews(for postIDs: [PostID]) async -> Set<PostID> { [] }
    nonisolated func holdsComments(for postID: PostID) -> Bool { cachedTopComments(for: postID) != nil }
    /// Default: nothing held — the bars fill in when the identity resolves.
    nonisolated func cachedViewerIdentity() -> ViewerIdentity? { nil }
    /// Default: nowhere to put it; the panel loads as it always did.
    nonisolated func seedTopComments(_ entries: [CommentEntry], for postID: PostID) {}
    /// Default: no viewer. The composer's avatar is an enhancement, so a
    /// provider that doesn't know who is signed in (every test fake, and
    /// any future read-only source) opts out by saying nothing.
    func viewerIdentity() async -> ViewerIdentity? { nil }
    /// Default: nothing to adopt, for providers with no notion of a viewer.
    func setActiveViewer(_ id: ProfileID) async {}
    /// A one-shot comment, with nothing to retry: a key of its own. A
    /// screen that offers a retry mints the key itself and keeps it (#795).
    func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
        try await addComment(body, to: postID, parentID: parentID, commentID: UUID().uuidString)
    }
}

/// Reads/writes top-level comments via comment.v1, hydrating author names via
/// profile.v1.
public actor CommentsRepository: CommentsProviding {
    private let commentClient: any Comment_V1_CommentServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let authSession: any AuthSessionProviding
    private let pageSize: Int32
    /// Replies per thread with a page of comments: its most popular (#637).
    static let repliesShownWithAPage: Int32 = 2
    /// Replies per "View more replies" page.
    private let replyPageSize: Int32

    /// Who is signed in, and as which profile — shared with every other
    /// repository (`ViewerSession`), so a switch or a sign-out reaches all of them.
    private let viewer: any ViewerProviding
    private var authorCache: [ProfileID: (name: String, handle: String, avatarURL: URL?, frameID: String?)] = [:]
    /// Where the comments' authors are reported, so a person seen in a thread
    /// is known when opened from anywhere (#1858).
    private let people: (any PeopleSightings)?
    /// The prefetched first pages, OUTSIDE this actor's isolation so the panel
    /// can read one synchronously while it mounts. Locked rather than
    /// isolated for exactly that reason — an `await` here would put a
    /// skeleton on screen, which is the thing being removed.
    private nonisolated let topPages: TopCommentsCache
    /// The previews (#2003): a page of tiles' first comments, one call per
    /// page. Filtered for one viewer, so wiped on a viewer change, and never
    /// written to the device.
    private nonisolated let previews = CommentPreviewCache()
    /// Bumped by every viewer change: a batch that left before it lands
    /// nothing.
    private var viewerGeneration = 0

    /// `localStore` keeps the first pages on the device too (#893): a post
    /// opened in an earlier session opens on its last comments. Nil keeps
    /// them in memory.
    public init(
        commentClient: any Comment_V1_CommentServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        authSession: any AuthSessionProviding,
        viewer: (any ViewerProviding)? = nil,
        pageSize: Int32 = 50,
        replyPageSize: Int32 = 20,
        localStore: LocalStore? = nil,
        people: (any PeopleSightings)? = nil
    ) {
        self.people = people
        self.topPages = TopCommentsCache(disk: localStore.map(CommentsDiskTier.init(store:)))
        self.commentClient = commentClient
        self.profileClient = profileClient
        self.authSession = authSession
        // Nil only outside the app (tests, previews): a session of its own,
        // resolving through this repository's profile client.
        self.viewer = viewer ?? ViewerSession(authSession: authSession) { [profileClient] account in
            try await AccountProfilesReader.profileIDs(ofAccount: account.rawValue, using: profileClient)
                .map { ProfileID($0) }
        }
        self.pageSize = pageSize
        self.replyPageSize = replyPageSize
    }

    // MARK: - CommentsProviding

    /// Best-effort: a failed prefetch leaves the cache empty and the panel
    /// falls back to loading with a skeleton, exactly as before.
    public func prefetchTopComments(for postID: PostID) async {
        guard topPages.value(for: postID) == nil else { return }
        _ = try? await loadComments(for: postID)
    }

    /// The first page when one is held, otherwise a NON-EMPTY preview: a
    /// preview is a seed, never a page, so it never says "no comments" (#2003).
    public nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? {
        if let page = topPages.value(for: postID) { return page }
        guard let preview = previews.value(for: postID), !preview.isEmpty else { return nil }
        return preview
    }

    public nonisolated func holdsComments(for postID: PostID) -> Bool {
        topPages.value(for: postID) != nil || previews.value(for: postID) != nil
    }

    /// How many comments a preview carries per post (#2003): enough for the
    /// subtitle zone's first cue and a text page's first rows.
    static let previewLimit: Int32 = 5
    /// `ListPreviews` takes at most this many posts.
    static let previewBatch = 50

    /// ⚠️ ONE CALL PER PAGE OF TILES (#2003), beside the posts and their
    /// counters, instead of one request per tile racing the viewer's tap.
    /// A post is covered when its preview decides the subtitle zone's first
    /// cue (`SubtitleCommentBuilder.previewDecidesFirstCue`) — a post left
    /// out of the answer is one the viewer may not read, an empty preview.
    /// The others, and a failed batch, warm on their own.
    public func prefetchPreviews(for postIDs: [PostID]) async -> Set<PostID> {
        var seen = Set<PostID>()
        let wanted = postIDs.filter { !holdsComments(for: $0) && seen.insert($0).inserted }
        guard !wanted.isEmpty else { return [] }
        let generation = viewerGeneration
        var covered = Set<PostID>()
        for start in stride(from: 0, to: wanted.count, by: Self.previewBatch) {
            let batch = Array(wanted[start..<min(start + Self.previewBatch, wanted.count)])
            var request = Comment_V1_ListPreviewsRequest()
            request.postIds = batch.map(\.rawValue)
            request.limit = Self.previewLimit
            guard case .success(let body) = await commentClient.listPreviews(request: request, headers: [:]).result
            else { continue }
            await hydrateAuthors(for: body.previews.flatMap { $0.comments.map { ProfileID($0.authorID) } })
            // A viewer change while it was out: the answer was filtered for
            // someone else.
            guard generation == viewerGeneration else { return [] }
            let byPost = Dictionary(
                body.previews.map { (PostID($0.postID), $0.comments.map(makeEntry)) },
                uniquingKeysWith: { first, _ in first }
            )
            for id in batch {
                // A preview that cannot tell the zone's first cue is no seed:
                // the post warms its first page on its own, as before.
                let preview = byPost[id] ?? []
                guard SubtitleCommentBuilder.previewDecidesFirstCue(
                    preview, isWholeTopLevel: preview.count < Int(Self.previewLimit)
                ) else { continue }
                previews.set(preview, for: id)
                covered.insert(id)
            }
        }
        return covered
    }

    public func loadComments(for postID: PostID) async throws -> [CommentEntry] {
        try await loadCommentsPage(for: postID, after: nil).entries
    }

    /// ⚠️ FOLLOW THE TOKEN, NEVER THE COUNT: comment.v1 filters each page
    /// after reading it (blocks, hidden words, held comments), so a page can
    /// come back short, or empty, with more behind it.
    public func loadCommentsPage(for postID: PostID, after pageToken: String?) async throws -> CommentPage {
        try await loadCommentsPage(for: postID, after: pageToken, order: .recent)
    }

    public func loadCommentsPage(for postID: PostID, after pageToken: String?, order: CommentSortOrder) async throws -> CommentPage {
        let ranked = order != .recent
        // ⚠️ ONE PAGINATION FOR THE BAND AND THE PANEL (#2005): a page past
        // the first that either already loaded is not asked for again.
        if let pageToken, let kept = laterPages[Self.laterPageKey(postID, pageToken, ranked: ranked)] { return kept }
        // Whose page this is, asked before the fetch (#893).
        let writer = topPages.viewer
        var request = Comment_V1_ListTopLevelRequest()
        request.postID = postID.rawValue
        request.limit = pageSize
        request.pageToken = pageToken ?? ""
        // The ranked stream (#2007, #977); a token belongs to the order that
        // minted it.
        if ranked { request.sort = .popularity }
        let response = await commentClient.listTopLevel(request: request, headers: [:])
        let views: [Comment_V1_CommentView]
        let nextToken: String
        switch response.result {
        case .success(let body):
            views = body.comments
            nextToken = body.nextToken
        case .failure(let error): throw CommentsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }

        // Level 2 (#637): each thread's two most popular replies, and where
        // the rest continue — asked only of threads that have any, so a post
        // opens on two replies per thread plus their count, never fifty.
        // Replies are an enhancement: a failed fetch yields none for that
        // parent, never a sunk thread.
        let client = commentClient
        let postIDValue = postID.rawValue
        let limit = Self.repliesShownWithAPage
        let replies: [String: (views: [Comment_V1_CommentView], next: String)] = await withTaskGroup(
            of: (String, [Comment_V1_CommentView], String).self
        ) { group in
            for top in views where top.replyCount > 0 {
                group.addTask {
                    var request = Comment_V1_ListRepliesRequest()
                    request.postID = postIDValue
                    request.commentID = top.commentID
                    request.limit = limit
                    request.sort = .popularity
                    let response = await client.listReplies(request: request, headers: [:])
                    switch response.result {
                    case .success(let body): return (top.commentID, body.comments, body.nextToken)
                    case .failure: return (top.commentID, [], "")
                    }
                }
            }
            var result: [String: (views: [Comment_V1_CommentView], next: String)] = [:]
            for await (parent, replies, next) in group where !replies.isEmpty {
                result[parent] = (replies, next)
            }
            return result
        }
        let repliesByParent = replies.mapValues(\.views)
        let replyTokens = replies.compactMapValues { $0.next.isEmpty ? nil : $0.next }

        let thread = Self.threaded(topLevel: views, repliesByParent: repliesByParent)
        await hydrateAuthors(for: thread.map { ProfileID($0.authorID) })
        let entries = thread.map(makeEntry)
        // Every first-page load fills the cache, not just an explicit
        // prefetch: a page opened once and returned to should render
        // instantly the second time for the same reason it should the first.
        // Recent's alone: the warmed first page is what a post opens on.
        if pageToken == nil, !ranked { topPages.set(entries, for: postID, persistingAs: writer) }
        let page = CommentPage(
            entries: entries, nextPageToken: nextToken.isEmpty ? nil : nextToken, replyTokens: replyTokens
        )
        // Kept for this viewer's session, for whichever surface asks next —
        // and only while the viewer that asked is still the one signed in.
        if let pageToken, writer == topPages.viewer {
            laterPages[Self.laterPageKey(postID, pageToken, ranked: ranked)] = page
        }
        return page
    }

    /// Pages past the first, by post and token, for this viewer (#2005).
    private var laterPages: [String: CommentPage] = [:]

    private static func laterPageKey(_ postID: PostID, _ token: String, ranked: Bool) -> String {
        "\(ranked ? "popular" : "recent")|\(postID.rawValue)|\(token)"
    }

    /// ⚠️ THE ORDER IS READ AGAIN PER PAGE (comment.v1): a reply whose likes
    /// moved between two pages can come back twice or be passed over. The
    /// caller drops what it already shows (`PostDetailViewModel`).
    public func loadReplies(for postID: PostID, to parentID: String, after pageToken: String?) async throws -> CommentPage {
        var request = Comment_V1_ListRepliesRequest()
        request.postID = postID.rawValue
        request.commentID = parentID
        request.limit = replyPageSize
        request.pageToken = pageToken ?? ""
        request.sort = .popularity
        let response = await commentClient.listReplies(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            await hydrateAuthors(for: body.comments.map { ProfileID($0.authorID) })
            return CommentPage(
                entries: body.comments.map(makeEntry),
                nextPageToken: body.nextToken.isEmpty ? nil : body.nextToken
            )
        case .failure(let error):
            throw CommentsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func addComment(
        _ body: String, to postID: PostID, parentID: String?, commentID: String
    ) async throws -> CommentEntry {
        let viewer = try await resolveViewerProfileID(forWrite: "addComment")

        var request = Comment_V1_CreateCommentRequest()
        // Client-supplied, and the caller's: the same id on every retry of
        // one comment is what lets the server recognise the replay (#795).
        request.commentID = commentID
        request.postID = postID.rawValue
        request.authorID = viewer.rawValue
        request.parentID = parentID ?? ""
        request.body = body
        let response = await commentClient.createComment(request: request, headers: [:])
        switch response.result {
        case .success(let created):
            await hydrateAuthors(for: [viewer])
            let author = authorCache[viewer] ?? (name: "You", handle: "", avatarURL: nil, frameID: nil)
            return CommentEntry(
                id: created.commentID.isEmpty ? request.commentID : created.commentID,
                authorID: viewer,
                authorName: author.name,
                authorHandle: author.handle,
                authorAvatarURL: author.avatarURL,
                authorAvatarFrameID: author.frameID,
                body: body,
                createdAt: Date(),
                parentID: parentID
            )
        case .failure(let error):
            if error.code == .permissionDenied, (error.message ?? "").contains("CMT-1005") {
                throw CommentsError.notAllowed
            }
            throw CommentsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
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
        let identity = ViewerIdentity(
            name: author.name, avatarURL: author.avatarURL, profileID: viewer, handle: author.handle
        )
        // Mirrored only if nobody switched while this was in flight: a peek
        // must never answer with a face the viewer has already left.
        if await activeProfile() == viewer { viewerMirror.set(identity) }
        return identity
    }

    public nonisolated func cachedViewerIdentity() -> ViewerIdentity? {
        viewerMirror.value
    }

    public nonisolated func seedTopComments(_ entries: [CommentEntry], for postID: PostID) {
        topPages.set(entries, for: postID)
    }

    /// Waits until every first page so far is on the device. Tests only.
    nonisolated func waitForDeviceWrites() {
        topPages.waitForPendingWrites()
    }

    /// Adopts `id` through the shared viewer — idempotent next to
    /// `ProfileRepository.setActiveProfile`, which makes the same move for the
    /// same switch. The author cache is keyed by profile id, so the new
    /// identity's name and avatar are already there if that profile has
    /// appeared in any thread.
    public func setActiveViewer(_ id: ProfileID) async {
        // Against the mirror itself, not the viewer: `ProfileRepository` has
        // usually switched the shared viewer already, and the face held here
        // is still the old one.
        if viewerMirror.value?.profileID != id { viewerMirror.set(nil) }
        await viewer.setActiveProfile(id)
    }

    /// The active profile as already resolved, or nil — never a fetch.
    private func activeProfile() async -> ProfileID? {
        guard case .member(_, let profile) = await viewer.current() else { return nil }
        return profile
    }

    /// The last resolved identity, readable without awaiting — the one read a
    /// screen makes while it is being BUILT, which cannot await. Locked rather
    /// than isolated for the reason `topPages` is.
    private nonisolated let viewerMirror = ViewerMirror()

    private final class ViewerMirror: @unchecked Sendable {
        private let lock = NSLock()
        private var identity: ViewerIdentity?

        var value: ViewerIdentity? { lock.withLock { identity } }
        func set(_ identity: ViewerIdentity?) { lock.withLock { self.identity = identity } }
    }

    // MARK: - Hydration

    private func hydrateAuthors(for ids: [ProfileID]) async {
        let missing = Set(ids).filter { authorCache[$0] == nil && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }
        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, Profile_V1_ProfileView)?.self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    guard let view = response.message else { return nil }
                    return (id, view)
                }
            }
            return await group.reduce(into: [(ProfileID, Profile_V1_ProfileView)]()) { partial, pair in
                if let pair { partial.append(pair) }
            }
        }
        for (id, view) in fetched {
            let frame: String? = view.avatarFrameID.isEmpty ? nil : view.avatarFrameID
            authorCache[id] = (view.displayName, view.handle, URL(string: view.avatarURL), frame)
        }
        people?.saw(fetched.map { AuthorSummary(profileView: $0.1) })
    }

    private func makeEntry(from view: Comment_V1_CommentView) -> CommentEntry {
        let authorID = ProfileID(view.authorID)
        let author = authorCache[authorID] ?? (name: "Someone", handle: "", avatarURL: nil, frameID: nil)
        return CommentEntry(
            id: view.commentID,
            authorID: authorID,
            authorName: author.name,
            authorHandle: author.handle,
            authorAvatarURL: author.avatarURL,
            authorAvatarFrameID: author.frameID,
            body: view.body,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000),
            parentID: view.parentID.isEmpty ? nil : view.parentID,
            isHeld: view.held,
            // Filled for a top-level comment only (ListTopLevel).
            replyCount: view.parentID.isEmpty ? Int(clamping: view.replyCount) : nil
        )
    }

    /// The 2-level thread order the stream renders: each top-level comment
    /// in its listed order, immediately followed by its replies in the
    /// server's order — most popular first (#637). Replies whose parent never
    /// arrived (a truncated top-level page) are dropped rather than
    /// stranded at the wrong depth. Pure and static — the threading
    /// contract is unit-tested without a network.
    static func threaded(
        topLevel: [Comment_V1_CommentView],
        repliesByParent: [String: [Comment_V1_CommentView]]
    ) -> [Comment_V1_CommentView] {
        topLevel.flatMap { top in
            [top] + (repliesByParent[top.commentID] ?? [])
        }
    }

    /// `write` names the caller when it is a write, so a guest reaching it is
    /// reported (`GateAudit`): the member gate should have stopped them first.
    private func resolveViewerProfileID(forWrite write: String? = nil) async throws -> ProfileID {
        do {
            return try await viewer.activeProfileID()
        } catch ViewerError.requiresMember {
            if let write { GateAudit.ungatedWrite(write) }
            throw CommentsError.notAuthenticated
        } catch ViewerError.noProfileForAccount {
            throw CommentsError.noProfileForAccount
        } catch let error as AccountProfilesReader.ReadError {
            throw CommentsError.transport(message: error.message, failure: error.networkFailure)
        }
    }
}


/// The prefetched first pages, readable without awaiting.
///
/// A lock rather than actor isolation, deliberately: the comments panel mounts
/// inside a layout pass and cannot await anything — whatever it has to await,
/// it renders a skeleton for. This is the one piece of the repository that has
/// to answer synchronously.
///
/// Memory first; behind it, when the app hands one in, the device (#893): a
/// memory miss reads it synchronously, once per post.
private final class TopCommentsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [PostID: [CommentEntry]] = [:]
    /// Posts the device was asked for and did not have.
    private var missingOnDisk: Set<PostID> = []
    private let disk: CommentsDiskTier?

    init(disk: CommentsDiskTier?) {
        self.disk = disk
    }

    var viewer: LocalStoreViewer? { disk?.viewer }

    func value(for postID: PostID) -> [CommentEntry]? {
        let known: (entries: [CommentEntry]?, askDisk: Bool) = lock.withLock {
            (pages[postID], pages[postID] == nil && !missingOnDisk.contains(postID))
        }
        if let entries = known.entries { return entries }
        guard known.askDisk, let disk else { return nil }
        // Read outside the lock: the store has its own.
        let stored = disk.firstPage(for: postID)
        lock.withLock {
            if let stored {
                if pages[postID] == nil { pages[postID] = stored }
            } else {
                missingOnDisk.insert(postID)
            }
        }
        return stored
    }

    /// `persistingAs`: also keeps the page on the device, as that viewer's.
    func set(_ entries: [CommentEntry], for postID: PostID, persistingAs viewer: LocalStoreViewer? = nil) {
        lock.withLock {
            pages[postID] = entries
            missingOnDisk.remove(postID)
        }
        if let viewer { disk?.save(entries, for: postID, as: viewer) }
    }

    /// Memory only: the device tier is wiped by the cache coordinator on the
    /// same viewer change.
    func removeAll() {
        lock.withLock {
            pages.removeAll()
            missingOnDisk.removeAll()
        }
    }

    func waitForPendingWrites() { disk?.waitForPendingWrites() }
}

/// The previews a page of tiles brought (#2003), readable synchronously as
/// the first pages are. Memory only, one viewer's.
private final class CommentPreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PostID: [CommentEntry]] = [:]

    func value(for postID: PostID) -> [CommentEntry]? { lock.withLock { entries[postID] } }
    func set(_ preview: [CommentEntry], for postID: PostID) { lock.withLock { entries[postID] = preview } }
    func removeAll() { lock.withLock { entries.removeAll() } }
}

extension CommentsRepository: HeldCommentReviewing {
    public func reviewHeldComment(_ commentID: String, approve: Bool) async throws {
        let owner = try await resolveViewerProfileID(forWrite: "reviewHeldComment")
        var request = Comment_V1_ReviewHeldCommentRequest()
        request.commentID = commentID
        request.ownerID = owner.rawValue
        request.approve = approve
        let response = await commentClient.reviewHeldComment(request: request, headers: [:])
        switch response.result {
        case .success:
            return
        // Already reviewed (here or on another device) or deleted: the
        // server answers not found, and the comment is gone from the held
        // state either way.
        case .failure(let error) where error.code == .notFound:
            return
        case .failure(let error):
            throw CommentsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}

extension CommentsRepository: ViewerScoped {
    /// The composer's face belongs to whoever was signed in: another account,
    /// a sign-out or a switch drops it until the new viewer resolves.
    ///
    /// The prefetched first pages go too (#892): the server filters each one
    /// for its reader — their blocks, their hidden words, the comments held
    /// for them — so the next viewer's panel must not open on them.
    public func viewerDidChange(_ state: ViewerState) async {
        viewerMirror.set(nil)
        topPages.removeAll()
        laterPages.removeAll()
        // The previews were filtered for that viewer too (#2003).
        previews.removeAll()
        viewerGeneration += 1
    }
}
