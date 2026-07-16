import CoreModels
import CoreNavigation
import Foundation

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

    /// Posts a comment. Disables the composer while in flight; on success the
    /// new comment is prepended. Empty/whitespace input is ignored.
    public func submitComment(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commentsProvider, !body.isEmpty, !isComposing else { return }
        setComposing(true)
        Task { [weak self] in
            guard let self else { return }
            if let entry = try? await commentsProvider.addComment(body, to: self.postID) {
                self.comments.insert(entry, at: 0)
                self.emitComments()
            }
            self.setComposing(false)
        }
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
        onCommentsChange?(.loaded(comments.map { CommentDisplayModel(entry: $0, now: now) }))
    }

    private func setComposing(_ composing: Bool) {
        isComposing = composing
        onComposingChange?(composing)
    }
}
