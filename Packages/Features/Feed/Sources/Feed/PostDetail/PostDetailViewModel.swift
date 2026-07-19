import CoreModels
import CoreNavigation
import Foundation

/// The comments stream's sort orders (the engaged toolbar's selector).
public enum CommentSortOrder: Sendable, Equatable {
    case recent
    case trending
}

@MainActor
public final class PostDetailViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content(PostDetailDisplayModel)
        case failed(message: String)
    }

    public struct EngagementState: Equatable, Sendable {
        public var likeCount: Int64
        public var isLiked: Bool
    }

    /// The comments section state.
    public nonisolated enum CommentsState: Equatable, Sendable {
        case loading
        case loaded([CommentDisplayModel])
    }

    public var onPhaseChange: ((Phase) -> Void)?
    public var onEngagementChange: ((EngagementState) -> Void)?
    public var onCommentsChange: ((CommentsState) -> Void)?
    /// True while a comment is being posted (disables the send control).
    public var onComposingChange: ((Bool) -> Void)?

    private let postID: PostID
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let commentsProvider: (any CommentsProviding)?
    private let router: (any Router)?
    private let now: @Sendable () -> Date

    private var comments: [CommentEntry] = []
    /// The stream's sort order — Recent is the repository's chronology,
    /// Trending reorders THREADS by engagement (see `sortedForDisplay`).
    private var commentSort: CommentSortOrder = .recent
    /// Session-local optimistic comment likes (comment.v1 exposes no like
    /// API yet — dev/BACKEND_GAPS.md; swap for the real seam). Living in
    /// the VIEW MODEL, likes are part of the data pipeline: Trending
    /// weighs them, and every consumer reads one truth.
    private var likedComments: Set<String> = []
    private var isComposing = false

    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var engagement = EngagementState(likeCount: 0, isLiked: false)
    private var likeInFlight = false
    private var authorID: ProfileID?
    /// The loaded author's identity slice — attached to the `.profile` route
    /// so the destination composes its chrome synchronously.
    private var authorStub: ProfileIdentityStub?
    private var load: Task<Void, Never>?

    public init(
        postID: PostID,
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.postID = postID
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.commentsProvider = commentsProvider
        self.router = router
        self.now = now
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        reload()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    public var engagementState: EngagementState { engagement }

    /// Optimistic like toggle: flip immediately, roll back if the server
    /// rejects. One in-flight mutation at a time.
    public func toggleLike() {
        guard let engagementProvider, !likeInFlight else { return }
        engagement.isLiked.toggle()
        engagement.likeCount = max(0, engagement.likeCount + (engagement.isLiked ? 1 : -1))
        likeInFlight = true
        onEngagementChange?(engagement)

        let liked = engagement.isLiked
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engagementProvider.setLiked(liked, for: self.postID)
            } catch {
                self.engagement.isLiked = !liked
                self.engagement.likeCount = max(0, self.engagement.likeCount + (liked ? -1 : 1))
                self.onEngagementChange?(self.engagement)
            }
            self.likeInFlight = false
        }
    }

    /// Author tapped — route to their profile (the same cross-feature path the
    /// feed uses). Post detail never imports Profile.
    public func didTapAuthor() {
        guard let authorID else { return }
        router?.route(to: .profile(authorID, stub: authorStub))
    }

    /// Posts a comment. Disables the composer while in flight; on success a
    /// top-level comment is prepended, a reply (non-nil `parentID`) is
    /// inserted at the END of its parent's reply block — the thread reads
    /// downward, oldest reply first, matching the repository's order.
    /// Empty/whitespace input is ignored.
    public func submitComment(_ text: String, parentID: String? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commentsProvider, !body.isEmpty, !isComposing else { return }
        setComposing(true)
        Task { [weak self] in
            guard let self else { return }
            if let entry = try? await commentsProvider.addComment(body, to: self.postID, parentID: parentID) {
                self.insertSubmitted(entry)
                self.emitComments()
            }
            self.setComposing(false)
        }
    }

    private func insertSubmitted(_ entry: CommentEntry) {
        guard let parentID = entry.parentID,
              let parentIndex = comments.firstIndex(where: { $0.id == parentID }) else {
            comments.insert(entry, at: 0)
            return
        }
        var insertAt = parentIndex + 1
        while insertAt < comments.count, comments[insertAt].parentID == parentID {
            insertAt += 1
        }
        comments.insert(entry, at: insertAt)
    }

    /// A comment row's avatar tapped — route to that author's profile,
    /// pre-seeded with the identity the comment already carries (the same
    /// cross-feature path `didTapAuthor` uses; the keep-and-stack outbound
    /// lifecycle needs nothing special from us).
    public func didTapCommentAuthor(commentID: String) {
        guard let entry = comments.first(where: { $0.id == commentID }) else { return }
        router?.route(to: .profile(
            entry.authorID,
            stub: ProfileIdentityStub(handle: entry.authorHandle, displayName: entry.authorName)
        ))
    }

    // MARK: - Loading

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.repository.loadPost(self.postID)
                self.authorID = entry.author.id
                self.authorStub = ProfileIdentityStub(
                    handle: entry.author.handle,
                    displayName: entry.author.displayName
                )
                self.engagement = EngagementState(likeCount: entry.likeCount, isLiked: false)
                self.phase = .content(PostDetailDisplayModel(entry: entry, now: self.now()))
                self.onEngagementChange?(self.engagement)
                self.loadComments()
            } catch is CancellationError {
                // Superseded; leave the phase alone.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load this post. Pull to retry.")
                }
            }
            self.load = nil
        }
    }

    /// Comments are best-effort: a failure just shows an empty section rather
    /// than failing the whole post.
    private func loadComments() {
        guard let commentsProvider else { return }
        onCommentsChange?(.loading)
        Task { [weak self] in
            guard let self else { return }
            let loaded = (try? await commentsProvider.loadComments(for: self.postID)) ?? []
            self.comments = loaded
            self.emitComments()
        }
    }

    private func emitComments() {
        let now = now()
        let ordered = Self.sortedForDisplay(comments, order: commentSort, liked: likedComments)
        onCommentsChange?(.loaded(ordered.map { CommentDisplayModel(entry: $0, now: now) }))
    }

    // MARK: - Comment sorting & likes

    /// Reorders the stream and re-emits — the engaged toolbar's sort
    /// selector lands here.
    public func setCommentSort(_ order: CommentSortOrder) {
        guard order != commentSort else { return }
        commentSort = order
        emitComments()
    }

    /// Toggles the viewer's like on a comment and returns the new state.
    /// Deliberately does NOT re-emit: the row updates in place, and a
    /// Trending re-rank lands on the next sort change or reload — rows
    /// must never jump out from under the finger that just liked them.
    public func toggleCommentLike(commentID: String) -> Bool {
        if likedComments.remove(commentID) != nil {
            return false
        }
        likedComments.insert(commentID)
        return true
    }

    public func isCommentLiked(_ commentID: String) -> Bool {
        likedComments.contains(commentID)
    }

    /// The display order, thread-aware: replies always stay under their
    /// parents in chronological order — sorting moves whole THREADS.
    /// Recent keeps the repository's chronology. Trending ranks threads
    /// by the engagement signals comment.v1 carries today — reply count
    /// plus the session's likes anywhere in the thread — highest first
    /// (stable: ties keep chronology); real like counts slot into the
    /// score when the contract grows them. Pure and static, for tests.
    static func sortedForDisplay(
        _ entries: [CommentEntry],
        order: CommentSortOrder,
        liked: Set<String>
    ) -> [CommentEntry] {
        guard order == .trending else { return entries }
        var threads: [(parent: CommentEntry, replies: [CommentEntry])] = []
        for entry in entries {
            if entry.parentID == nil {
                threads.append((entry, []))
            } else if !threads.isEmpty {
                threads[threads.count - 1].replies.append(entry)
            }
        }
        func score(_ thread: (parent: CommentEntry, replies: [CommentEntry])) -> Int {
            thread.replies.count
                + (liked.contains(thread.parent.id) ? 1 : 0)
                + thread.replies.filter { liked.contains($0.id) }.count
        }
        return threads
            .enumerated()
            .sorted { lhs, rhs in
                let l = score(lhs.element)
                let r = score(rhs.element)
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .flatMap { [$0.element.parent] + $0.element.replies }
    }

    private func setComposing(_ composing: Bool) {
        isComposing = composing
        onComposingChange?(composing)
    }
}
