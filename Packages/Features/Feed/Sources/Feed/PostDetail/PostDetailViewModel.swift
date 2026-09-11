import CoreModels
import CoreNavigation
import Foundation

/// The comments stream's sort orders (the engaged toolbar's selector).
public enum CommentSortOrder: Sendable, Equatable {
    case recent
    case trending
}

/// When the stream's sort control is offered at all.
///
/// A sort over a handful of comments reorders nothing anyone would notice, and
/// a control that visibly does nothing reads as broken — so it waits until
/// there is a thread worth ranking, and gives its width back to the author
/// until then.
enum CommentSortPolicy {
    static let minimumComments = 10

    static func isAvailable(commentCount: Int) -> Bool {
        commentCount >= minimumComments
    }
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
    /// Who is composing — the bar's leading avatar. Fires once per load,
    /// and only when the provider actually knows; a nil viewer simply never
    /// emits, leaving the composer's placeholder disc alone.
    public var onViewerIdentityChange: ((ViewerIdentity) -> Void)?

    /// The draft's first message was published: this screen is that post now,
    /// and every action from here on targets it.
    var onPublished: ((FeedEntry) -> Void)?
    /// Publishing failed. Carries the text, which the composer had already
    /// cleared by the time it was sent.
    var onPublishFailed: ((String) -> Void)?

    /// Internal, not private: the compose bar's boost button spends against
    /// this identity, and the view controller is the one holding the wallet.
    ///
    /// ⚠️ NIL FOR A DRAFT — the "+" menu's Text Post, whose post does not exist
    /// until its first message is sent. Every read says what a draft does
    /// instead, and `adoptPublished` is the one place it is set afterwards.
    private(set) var postID: PostID?
    /// How a draft becomes a post. Nil for every screen showing one that exists.
    private var draft: PostDetailDraft?
    var isDraft: Bool { postID == nil }
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
    /// The face the composer — and, on a draft, the page's bars — is wearing.
    /// A draft publishes as THIS rather than as a fresh lookup, which could
    /// answer with a different profile, or with none.
    private var shownIdentity: ViewerIdentity?

    /// The same face twice is not news: the cached identity and the fetched
    /// one usually agree, and a second push would restart the avatar's fetch
    /// over a picture already on screen.
    private func show(_ identity: ViewerIdentity) {
        guard identity != shownIdentity else { return }
        shownIdentity = identity
        onViewerIdentityChange?(identity)
    }

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

    /// A post that does not exist yet: the "+" menu's Text Post. It fetches
    /// nothing, shows an empty stream from its first frame, and its first send
    /// PUBLISHES the post (`draft`) instead of commenting on one — after which
    /// it is exactly the view model of that post.
    init(
        draft: PostDetailDraft,
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.postID = nil
        self.draft = draft
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.commentsProvider = commentsProvider
        self.router = router
        self.now = now
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        // A DRAFT HAS NOTHING TO LOAD — no post, so no comments — and it shows
        // a LOADED empty stream on its first frame rather than a skeleton: the
        // page is empty because it is new, not because it is waiting. Only the
        // viewer is asked for, because the viewer is the author.
        guard !isDraft else {
            onCommentsChange?(.loaded([]))
            loadViewerIdentity()
            return
        }
        // Comments FIRST, and not chained to the post.
        //
        // `loadComments` used to be called at the end of the post's load task,
        // after `await repository.loadPost` — so a prefetched first page,
        // sitting in the cache and readable synchronously, still could not
        // reach the screen until a network round trip for the POST came back.
        // The panel showed its skeleton throughout, which for a text page
        // opened by a hero flight is the whole transition.
        //
        // Nothing in the comment stream depends on the post entry: it is keyed
        // by `postID` and stamped with `now`. The caption row arrives with the
        // post and introduces itself without animating
        // (`animatesStreamApply(introducesCaption:)`), which is exactly the
        // case that seam already existed for.
        loadComments()
        reload()
        loadViewerIdentity()
    }

    public func refresh() {
        guard load == nil, !isDraft else { return }
        // Explicitly, because the comment load is no longer chained to the
        // post's: a pull-to-refresh that silently stopped refreshing the
        // comments would be the obvious cost of unchaining them.
        loadComments()
        reload()
    }

    public var engagementState: EngagementState { engagement }

    /// Optimistic like toggle: flip immediately, roll back if the server
    /// rejects. One in-flight mutation at a time.
    public func toggleLike() {
        guard let engagementProvider, let postID, !likeInFlight else { return }
        engagement.isLiked.toggle()
        engagement.likeCount = max(0, engagement.likeCount + (engagement.isLiked ? 1 : -1))
        likeInFlight = true
        onEngagementChange?(engagement)

        let liked = engagement.isLiked
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engagementProvider.setLiked(liked, for: postID)
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
    ///
    /// On a DRAFT the text is not a comment: it is the post, and sending it
    /// publishes it (`publish(_:through:)`).
    public func submitComment(_ text: String, parentID: String? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isComposing else { return }
        if let draft { return publish(body, through: draft) }
        guard let commentsProvider, let postID else { return }
        setComposing(true)
        Task { [weak self] in
            guard let self else { return }
            if let entry = try? await commentsProvider.addComment(body, to: postID, parentID: parentID) {
                self.insertSubmitted(entry)
                self.emitComments()
            }
            self.setComposing(false)
        }
    }

    /// Publishes the draft's first message as the post, authored by the face
    /// the composer is wearing at the moment of sending — the doctrine
    /// `adoptActiveViewer` states for comments: what you see is who it is by.
    ///
    /// ⚠️ THE TASK HOLDS THE DRAFT, NOT THE SCREEN. Closing the page while it
    /// publishes must not cancel a post the viewer has already sent: it lands
    /// with nobody here to become it, and the feed still receives it.
    private func publish(_ body: String, through draft: PostDetailDraft) {
        setComposing(true)
        let commentsProvider = commentsProvider
        let shown = shownIdentity?.author
        Task { [weak self] in
            // The face on screen; asked for only when none has been shown yet.
            // And NEVER nil: an author-less publish goes out as the account's
            // first profile — a post by someone the viewer did not see named.
            var author = shown
            if author == nil { author = await commentsProvider?.viewerIdentity()?.author }
            // On a failure, composing ends BEFORE the text comes back: a host
            // deciding from both (the Text Post page's swipe guard) must see
            // writing to lose, not a post still on its way.
            guard let author else {
                self?.setComposing(false)
                self?.onPublishFailed?(body)
                return
            }
            do {
                let entry = try await draft.publish(body, author)
                self?.adoptPublished(entry)
                self?.setComposing(false)
            } catch {
                self?.setComposing(false)
                self?.onPublishFailed?(body)
            }
        }
    }

    /// Becomes the post the draft just published — in ONE turn, so nothing can
    /// observe a screen that is half draft and half post.
    ///
    /// ⚠️ THE POST FIRST, then the comments: the caption row has to exist before
    /// the empty stream re-applies, or the empty page is sized as though there
    /// were no caption above it and the published page scrolls.
    private func adoptPublished(_ entry: FeedEntry) {
        draft = nil
        postID = entry.post.id
        authorID = entry.author.id
        authorStub = ProfileIdentityStub(handle: entry.author.handle, displayName: entry.author.displayName)
        engagement = EngagementState(likeCount: entry.likeCount, isLiked: false)
        phase = .content(PostDetailDisplayModel(entry: entry, now: now()))
        comments = []
        emitComments()
        onEngagementChange?(engagement)
        onPublished?(entry)
        // Refreshed as any post's comments are, but WITHOUT a skeleton: the
        // empty stream on screen is already the answer, and the refresh only
        // speaks if it finds a different one.
        loadComments(showing: comments)
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
        // A draft has no post to load — see `postID`.
        guard let postID else { return }
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.repository.loadPost(postID)
                self.authorID = entry.author.id
                self.authorStub = ProfileIdentityStub(
                    handle: entry.author.handle,
                    displayName: entry.author.displayName
                )
                self.engagement = EngagementState(likeCount: entry.likeCount, isLiked: false)
                self.phase = .content(PostDetailDisplayModel(entry: entry, now: self.now()))
                self.onEngagementChange?(self.engagement)
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
    ///
    /// `shown`: comments already on screen, treated exactly like a prefetched
    /// page — no skeleton, and silence unless the refresh finds different ones.
    /// A just-published draft's empty stream is the one caller.
    private func loadComments(showing shown: [CommentEntry]? = nil) {
        guard let commentsProvider, let postID else { return }
        // A prefetched first page renders NOW, with no skeleton in between.
        //
        // This is the whole point of the cache being synchronous: the panel
        // mounts inside a layout pass — during a hero flight, inside
        // `prepareForHeroPresentation` — and anything it awaits is a skeleton
        // on screen. With the page already in hand the destination is
        // complete before the flight starts, so the transition carries real
        // comments rather than placeholders that swap after landing.
        let prefetched = shown ?? commentsProvider.cachedTopComments(for: postID)
        if shown == nil, let prefetched {
            comments = prefetched
            emitComments()
        } else if prefetched == nil {
            onCommentsChange?(.loading)
        }
        let didShowPrefetch = prefetched != nil
        // Refreshed regardless: the cache is a head start, not the truth. A
        // page prefetched a minute ago can have missed a comment since.
        Task { [weak self] in
            guard let self else { return }
            let loaded = (try? await commentsProvider.loadComments(for: postID)) ?? []
            // The equality skip applies ONLY when a prefetched page is already
            // on screen. Without one the view is sitting in `.loading` and has
            // to be told, even when the answer is the empty list it started
            // with — skipping there left the stream on its skeleton forever,
            // which the suite caught as a 120-second poll.
            guard !didShowPrefetch || loaded != self.comments else { return }
            self.comments = loaded
            self.emitComments()
        }
    }

    /// The composer's avatar identity — its own task, not chained to the
    /// comments load: the bar is on screen and typable long before (and
    /// regardless of whether) the stream resolves.
    private func loadViewerIdentity() {
        guard let commentsProvider else { return }
        // The face already resolved this session, on frame one. A composer that
        // reads "Add a comment…" over a blank disc for a beat before naming the
        // viewer is a flicker — most visibly on the page a published Text Post
        // becomes, which mounts under a panel already showing the face.
        if let cached = commentsProvider.cachedViewerIdentity() {
            show(cached)
        }
        Task { [weak self] in
            guard let identity = await commentsProvider.viewerIdentity() else { return }
            self?.show(identity)
        }
    }

    /// The viewer switched which of their profiles is active (from this
    /// screen's composer menu, or anywhere else while it is open).
    ///
    /// Tells the comments provider FIRST and re-reads the identity second,
    /// in that order: the re-read resolves through the value just adopted,
    /// so the face the composer ends up wearing is by construction the one
    /// the next comment will be posted as.
    public func adoptActiveViewer(_ id: ProfileID) {
        guard let commentsProvider else { return }
        Task { [weak self] in
            await commentsProvider.setActiveViewer(id)
            guard let identity = await commentsProvider.viewerIdentity() else { return }
            self?.show(identity)
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
