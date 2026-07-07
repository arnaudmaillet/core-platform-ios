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

    public var onPhaseChange: ((Phase) -> Void)?
    public var onEngagementChange: ((EngagementState) -> Void)?

    private let postID: PostID
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let router: (any Router)?
    private let now: @Sendable () -> Date

    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var engagement = EngagementState(likeCount: 0, isLiked: false)
    private var likeInFlight = false
    private var authorID: ProfileID?
    private var load: Task<Void, Never>?

    public init(
        postID: PostID,
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.postID = postID
        self.repository = repository
        self.engagementProvider = engagementProvider
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
        router?.route(to: .profile(authorID))
    }

    // MARK: - Loading

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.repository.loadPost(self.postID)
                self.authorID = entry.author.id
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
}
