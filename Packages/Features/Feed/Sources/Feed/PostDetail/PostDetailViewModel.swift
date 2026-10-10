import CoreModels
import CoreNavigation
import CoreNetworking
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
        /// The author hides like counts from this reader (#397): the screen
        /// shows none, the heart still works.
        public var countHidden = false
    }

    /// The comments section state.
    public nonisolated enum CommentsState: Equatable, Sendable {
        case loading
        case loaded([CommentDisplayModel])
        /// The FIRST page failed and there is nothing on screen to keep (#798).
        /// `retryComments()` asks for it again.
        ///
        /// ⚠️ Never sent over comments already shown — a prefetched page, a
        /// refresh, pages below the first: a failure leaves those as they are.
        /// Only an empty stream that never got an answer reads as failed,
        /// because that is the one case where the alternative — `.loaded([])`
        /// — says "No comments yet" about a post that may have hundreds.
        case failed(message: String)
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
    /// Why the last publish failed, when the error says (a refused mention,
    /// #397); nil for a plain failure.
    private(set) var publishFailureReason: String?
    /// A comment the server didn't take: its text, and whether it was
    /// refused by the author's setting (rather than failed).
    var onCommentFailed: ((_ text: String, _ refused: Bool) -> Void)?
    /// Approving or declining a held comment failed; the comment stays held.
    var onReviewFailed: ((_ approve: Bool) -> Void)?

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
    /// Where the next page of comments starts; nil when there is none, or
    /// before the first page has answered (#589).
    private var nextPageToken: String?
    /// The page being fetched — one at a time.
    private var pageLoad: Task<Void, Never>?
    /// Bumped by every reset, so a page from before it neither lands nor
    /// frees the slot a newer fetch holds.
    private var pagingGeneration = 0
    /// The first page's load is out: a near-end reached meanwhile is honoured
    /// as soon as it says whether there is more.
    /// Internal-readable for the test that overlaps two first-page loads.
    private(set) var isLoadingFirstPage = false
    /// Bumped by every first-page load (#798). First-page loads OVERLAP — a
    /// pull while the first is out, the check after a review — and without a
    /// token whichever ended first cleared `isLoadingFirstPage` for the one
    /// still out, and a late failure could cover an answer that had landed.
    /// Only the latest load clears the flag or reports a failure.
    private var firstPageGeneration = 0
    /// The newest first-page load whose answer has landed: an OLDER answer
    /// arriving after it is stale and dropped.
    private var appliedFirstPageGeneration = 0
    /// The view is showing an answer — a loaded stream, empty or not — rather
    /// than its skeleton or the failed row. What a failure must never cover.
    private var showsAnswer = false
    /// The last first-page load failed with nothing on screen (`.failed`):
    /// what `retryComments()` answers to.
    private var firstPageFailed = false
    /// What the failed stream says (#798).
    nonisolated static let commentsFailureMessage = "Couldn't load comments"
    private var wantsNextPage = false
    /// Pages beyond the first are on screen: a refresh merges its first page
    /// over them rather than replacing the stream.
    private var hasLaterPages = false
    /// The first top-level comment of each page appended after the first —
    /// Trending ranks threads WITHIN a page, so rows already on screen never
    /// move when one lands.
    private var pageStarts: Set<String> = []
    /// A page filtered down to nothing still carries a token; this many in a
    /// row are walked through before giving up until the next approach.
    static let maxEmptyPagesInARow = 5
    /// The stream's sort order — Recent is the repository's chronology,
    /// Trending reorders THREADS by engagement (see `sortedForDisplay`).
    private var commentSort: CommentSortOrder = .recent
    /// Session-local optimistic comment likes (comment.v1 exposes no like
    /// API yet — dev/BACKEND_GAPS.md; swap for the real seam). Living in
    /// the VIEW MODEL, likes are part of the data pipeline: Trending
    /// weighs them, and every consumer reads one truth.
    private var likedComments: Set<String> = []
    /// Held comments whose review is on its way to the server.
    private var reviewing: Set<String> = []
    private var isComposing = false

    private var recovery: RecoveryObservation?
    /// The monitor whose recoveries reload this store — the shared one; a
    /// test hands its own (the shared one is process-wide).
    var connectivity: ConnectivityMonitor = .shared
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
        let couldReview = isViewerPostOwner
        shownIdentity = identity
        onViewerIdentityChange?(identity)
        // Who may review held comments follows the viewer.
        if isViewerPostOwner != couldReview, comments.contains(where: \.isHeld) { emitComments() }
    }

    /// The viewer is the post's author — the one who reviews its held comments.
    private var isViewerPostOwner: Bool {
        guard let authorID, let viewer = shownIdentity?.profileID else { return false }
        return authorID == viewer
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
        armRecovery()
        // A DRAFT HAS NOTHING TO LOAD — no post, so no comments — and it shows
        // a LOADED empty stream on its first frame rather than a skeleton: the
        // page is empty because it is new, not because it is waiting. Only the
        // viewer is asked for, because the viewer is the author.
        guard !isDraft else {
            showsAnswer = true
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

    /// Reloads after an outage (#793): what failed while the network was gone
    /// comes back on its own when it returns — the viewer no longer has to
    /// find a way to retry, screen by screen.
    private func armRecovery() {
        guard recovery == nil else { return }
        recovery = connectivity.onRecovery { [weak self] in self?.recoverFromOutage() }
    }

    private func recoverFromOutage() {
        guard case .failed = phase else { return }
        refresh()
    }

    public func refresh() {
        guard load == nil, !isDraft else { return }
        // Explicitly, because the comment load is no longer chained to the
        // post's: a pull-to-refresh that silently stopped refreshing the
        // comments would be the obvious cost of unchaining them.
        loadComments()
        reload()
    }

    /// The failed stream's Try Again (#798): the first page, asked again. A
    /// no-op unless the stream is showing `.failed` and nothing is already out.
    public func retryComments() {
        guard firstPageFailed, !isLoadingFirstPage else { return }
        loadComments()
    }

    public var engagementState: EngagementState { engagement }

    /// Optimistic like: one point on the post (#676), shown at once, taken
    /// back if it does not land. Final — there is no unlike. One in flight
    /// at a time.
    public func like() {
        guard let engagementProvider, let postID, !likeInFlight else { return }
        let wasLiked = engagement.isLiked
        engagement.isLiked = true
        engagement.likeCount += 1
        likeInFlight = true
        onEngagementChange?(engagement)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await engagementProvider.like(postID)
            } catch {
                self.engagement.isLiked = wasLiked
                self.engagement.likeCount = max(0, self.engagement.likeCount - 1)
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
            do {
                let entry = try await commentsProvider.addComment(body, to: postID, parentID: parentID)
                self.insertSubmitted(entry)
                self.emitComments()
                self.setComposing(false)
            } catch {
                self.setComposing(false)
                self.onCommentFailed?(body, (error as? CommentsError) == .notAllowed)
            }
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
                self?.publishFailureReason = (error as? LocalizedError)?.errorDescription
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
        engagement = EngagementState(likeCount: entry.likeCount, isLiked: false, countHidden: entry.post.likeCountsHidden)
        phase = .content(PostDetailDisplayModel(entry: entry, now: now()))
        comments = []
        resetPaging()
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
        // ⚠️ THE WARM CACHE IS READ FIRST, SYNCHRONOUSLY (charter P7). A post
        // opened from a feed is in the repository's mirror already, and this
        // screen used to open on a spinner and fetch it again. `peekPost` is
        // the same read the pin-opened feed seeds from: nil on a miss, never
        // a fetch. The fetch then confirms it, and re-renders only if the
        // post changed underneath.
        var seeded: FeedEntry?
        if case .loading = phase, let cached = repository.peekPost(postID) {
            seeded = cached
            show(cached)
        }
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.repository.loadPost(postID)
                if entry != seeded { self.show(entry) }
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

    private func show(_ entry: FeedEntry) {
        let couldReview = isViewerPostOwner
        authorID = entry.author.id
        if isViewerPostOwner != couldReview, comments.contains(where: \.isHeld) { emitComments() }
        authorStub = ProfileIdentityStub(
            handle: entry.author.handle,
            displayName: entry.author.displayName
        )
        engagement = EngagementState(likeCount: entry.likeCount, isLiked: false, countHidden: entry.post.likeCountsHidden)
        phase = .content(PostDetailDisplayModel(entry: entry, now: now()))
        onEngagementChange?(engagement)
    }

    /// Comments are best-effort: a failure never fails the whole post. It
    /// leaves comments already on screen as they are, and an empty stream that
    /// never got an answer shows `.failed` with a retry — not the empty
    /// section it used to, which read as "No comments yet" (#798).
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
        isLoadingFirstPage = true
        firstPageFailed = false
        firstPageGeneration += 1
        let generation = firstPageGeneration
        // Refreshed regardless: the cache is a head start, not the truth. A
        // page prefetched a minute ago can have missed a comment since.
        Task { [weak self] in
            guard let self else { return }
            let page = try? await commentsProvider.loadCommentsPage(for: postID, after: nil)
            // A load another one has superseded neither clears the flag the
            // newer one holds nor reports a failure; its answer, if it has
            // one, still lands unless a newer answer already has (#798).
            let isCurrent = generation == self.firstPageGeneration
            if isCurrent { self.isLoadingFirstPage = false }
            // ⚠️ A FAILURE IS NOT AN EMPTY PAGE (#798). With nothing on screen
            // — the view sitting in `.loading` — it is said as `.failed`, with
            // a retry; with anything on screen (a prefetched page, the stream
            // a refresh is checking, a published draft's, an answer an
            // overlapping load landed), it changes nothing. Decided before the
            // later-pages branch below on purpose: that branch only runs with
            // comments shown, and keeps them too.
            guard let page else {
                if isCurrent, !didShowPrefetch, self.comments.isEmpty, !self.showsAnswer {
                    self.firstPageFailed = true
                    self.onCommentsChange?(.failed(message: Self.commentsFailureMessage))
                }
                return
            }
            guard generation > self.appliedFirstPageGeneration else { return }
            self.appliedFirstPageGeneration = generation
            defer {
                if isCurrent, self.wantsNextPage {
                    self.wantsNextPage = false
                    self.loadMoreComments()
                }
            }
            // Pages below the first are on screen: the fresh first page goes
            // over the old one and the rest stays — a refresh, or the check
            // after a review, must not cut the stream under the viewer. A
            // failure leaves it all as it is.
            if self.hasLaterPages {
                let merged = Self.merging(firstPage: page.entries, over: self.comments)
                guard merged != self.comments else { return }
                self.comments = merged
                self.emitComments()
                return
            }
            let loaded = page.entries
            self.nextPageToken = page.nextPageToken
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

    /// The viewer neared the end of the stream: the next page, if there is
    /// one and none is already on its way (#589). Appended, never reordering
    /// what is on screen; a failure is retried on the next approach.
    func loadMoreComments() {
        guard let commentsProvider, let postID, pageLoad == nil else { return }
        guard let token = nextPageToken else {
            if isLoadingFirstPage { wantsNextPage = true }
            return
        }
        let generation = pagingGeneration
        pageLoad = Task { [weak self] in
            await self?.appendPages(after: token, for: postID, from: commentsProvider, generation: generation)
        }
    }

    private func appendPages(
        after token: String, for postID: PostID, from provider: any CommentsProviding, generation: Int
    ) async {
        var token = token
        var fresh: [CommentEntry] = []
        for _ in 0..<Self.maxEmptyPagesInARow {
            guard let page = try? await provider.loadCommentsPage(for: postID, after: token),
                  // A refresh replaced the stream while this was out.
                  pagingGeneration == generation, self.postID == postID, nextPageToken == token
            else {
                // A reset already emptied the slot, and may have refilled it.
                if pagingGeneration == generation { pageLoad = nil }
                return
            }
            nextPageToken = page.nextPageToken
            // A comment can sit on both sides of a page boundary.
            let known = Set(comments.map(\.id))
            fresh = page.entries.filter { !known.contains($0.id) }
            // Filtered down to nothing: nothing new to display means no row
            // reaches the end to ask again, so the next one is asked now.
            guard !fresh.contains(where: { $0.parentID == nil }), let next = page.nextPageToken else { break }
            token = next
        }
        // ⚠️ THE SLOT FREES BEFORE THE ROWS RENDER. A page that lands wholly on
        // screen (a short, filtered one) asks for the next from its rows'
        // `willDisplay` inside the apply — freed afterwards, that ask found the
        // slot taken and was dropped, and with every row already displayed the
        // stream stopped there (found on the inbox, #593).
        pageLoad = nil
        guard let head = fresh.first(where: { $0.parentID == nil }) else { return }
        pageStarts.insert(head.id)
        hasLaterPages = true
        comments += fresh
        emitComments()
    }

    /// Internal, not private, for the one test that races a page against it:
    /// in the app only a draft becoming a post resets, and a draft pages
    /// nothing before that.
    func resetPaging() {
        pagingGeneration += 1
        pageLoad?.cancel()
        pageLoad = nil
        nextPageToken = nil
        hasLaterPages = false
        pageStarts = []
        wantsNextPage = false
    }

    /// A refreshed first page over a stream that runs past it: the page
    /// replaces every thread at least as new as its oldest, and every older
    /// thread stays where it is. The server lists newest first, so an old
    /// first-page thread missing from the new page either slid down (older:
    /// kept) or went away (newer: dropped). Pure, for tests.
    static func merging(firstPage: [CommentEntry], over shown: [CommentEntry]) -> [CommentEntry] {
        guard let oldest = firstPage.filter({ $0.parentID == nil }).map(\.createdAt).min() else { return shown }
        let fresh = Set(firstPage.map(\.id))
        var kept: [CommentEntry] = []
        var keepsThread = false
        for entry in shown {
            if entry.parentID == nil { keepsThread = !fresh.contains(entry.id) && entry.createdAt < oldest }
            if keepsThread, !fresh.contains(entry.id) { kept.append(entry) }
        }
        return firstPage + kept
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

    /// The viewer became someone else (a guest signed in, an account
    /// signed out): the composer's face is re-read from the new viewer.
    public func reloadViewerIdentity() {
        loadViewerIdentity()
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
        let ordered = Self.sortedForDisplay(comments, order: commentSort, liked: likedComments, pageStarts: pageStarts)
        let canReview = isViewerPostOwner && commentsProvider is any HeldCommentReviewing
        showsAnswer = true
        onCommentsChange?(.loaded(ordered.map {
            CommentDisplayModel(entry: $0, now: now, canReview: canReview && !reviewing.contains($0.id))
        }))
    }

    // MARK: - Held comments

    /// The post's owner approves (`approve`) or declines a comment held for
    /// their review (#416). Not optimistic: the comment stays as it is until
    /// the server answers, then shows to everyone or goes; a failure leaves
    /// it held and says so.
    public func reviewHeldComment(_ commentID: String, approve: Bool) {
        guard let reviewer = commentsProvider as? any HeldCommentReviewing, let postID,
              isViewerPostOwner, !reviewing.contains(commentID),
              comments.contains(where: { $0.id == commentID && $0.isHeld })
        else { return }
        reviewing.insert(commentID)
        emitComments()
        Task { [weak self] in
            do {
                try await reviewer.reviewHeldComment(commentID, approve: approve)
                guard let self else { return }
                self.reviewing.remove(commentID)
                self.comments = approve
                    ? self.comments.map { $0.id == commentID ? $0.released() : $0 }
                    : self.comments.filter { $0.id != commentID && $0.parentID != commentID }
                self.commentsProvider?.seedTopComments(self.comments, for: postID)
                self.emitComments()
                // The server has the last word — another device may have
                // reviewed it the other way first.
                self.loadComments(showing: self.comments)
            } catch {
                guard let self else { return }
                self.reviewing.remove(commentID)
                self.emitComments()
                self.onReviewFailed?(approve)
            }
        }
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
    ///
    /// `pageStarts`: the first thread of each page loaded after the first.
    /// Threads are ranked within their page, never across: a page landing
    /// at the bottom must not lift a thread above rows already on screen.
    static func sortedForDisplay(
        _ entries: [CommentEntry],
        order: CommentSortOrder,
        liked: Set<String>,
        pageStarts: Set<String> = []
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
        var pages: [[(parent: CommentEntry, replies: [CommentEntry])]] = []
        for thread in threads {
            if pages.isEmpty || pageStarts.contains(thread.parent.id) { pages.append([]) }
            pages[pages.count - 1].append(thread)
        }
        return pages.flatMap { page in
            page
                .enumerated()
                .sorted { lhs, rhs in
                    let l = score(lhs.element)
                    let r = score(rhs.element)
                    return l == r ? lhs.offset < rhs.offset : l > r
                }
                .flatMap { [$0.element.parent] + $0.element.replies }
        }
    }

    private func setComposing(_ composing: Bool) {
        isComposing = composing
        onComposingChange?(composing)
    }
}
