import Foundation

/// State for Settings → Privacy's Private Account switch (#388).
///
/// Not optimistic. The switch shows what the server holds: it is disabled
/// while a change is in flight and snaps back if the change fails, because a
/// privacy switch that shows "on" while the profile is still public is the
/// one kind of wrong this screen cannot afford.
@MainActor
final class PrivacySectionViewModel {
    enum Phase: Equatable {
        case loading
        case loaded(isPrivate: Bool)
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    private(set) var isSaving = false {
        didSet { onChange?() }
    }
    /// Pending follow requests (#396); nil until read, or when the screen
    /// has no requests inbox.
    private(set) var pendingRequestCount: Int? {
        didSet { onChange?() }
    }
    /// How far back others see this profile's posts (#411); nil until read
    /// or when the screen can't set it.
    private(set) var postWindow: PostWindow? {
        didSet { onChange?() }
    }
    /// Who may comment on this profile's posts (#397); nil until read or
    /// when the screen can't set it.
    private(set) var commentAudience: CommentAudience? {
        didSet { onChange?() }
    }
    /// Like counts and downloads of this profile's posts (#397); nil until
    /// read or when the screen can't set them.
    private(set) var postSharing: PostSharing? {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let visibility: any ProfileVisibilityManaging
    let requests: (any FollowRequestsManaging)?
    let windows: (any PostWindowManaging)?
    let comments: (any CommentAudienceManaging)?
    let sharing: (any PostSharingManaging)?

    init(
        visibility: any ProfileVisibilityManaging,
        requests: (any FollowRequestsManaging)? = nil,
        windows: (any PostWindowManaging)? = nil,
        comments: (any CommentAudienceManaging)? = nil,
        sharing: (any PostSharingManaging)? = nil
    ) {
        self.visibility = visibility
        self.requests = requests
        self.windows = windows
        self.comments = comments
        self.sharing = sharing
    }

    /// Re-read when the screen comes back from the inbox.
    func refreshRequestCount() async {
        guard let requests else { return }
        pendingRequestCount = (try? await requests.pendingFollowRequestCount()) ?? pendingRequestCount
    }

    /// Not optimistic: the value shown is the server's.
    func setPostWindow(_ window: PostWindow) async throws {
        guard let windows, window != postWindow else { return }
        try await windows.setPostWindow(window)
        postWindow = window
    }

    /// Not optimistic: the value shown is the server's.
    func setCommentAudience(_ audience: CommentAudience) async throws {
        guard let comments, audience != commentAudience else { return }
        try await comments.setCommentAudience(audience)
        commentAudience = audience
    }

    /// Not optimistic: the switches show the server's values.
    func setPostSharing(_ next: PostSharing) async throws {
        guard let sharing, next != postSharing else { return }
        try await sharing.setPostSharing(next)
        postSharing = next
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        if let sharing {
            Task { self.postSharing = (try? await sharing.postSharing()) ?? self.postSharing }
        }
        Task { await refreshRequestCount() }
        if let windows {
            Task { self.postWindow = (try? await windows.postWindow()) ?? self.postWindow }
        }
        if let comments {
            Task { self.commentAudience = (try? await comments.commentAudience()) ?? self.commentAudience }
        }
        do {
            phase = .loaded(isPrivate: try await visibility.activeProfileIsPrivate())
        } catch {
            phase = .failed
        }
    }

    func setPrivate(_ isPrivate: Bool) async throws {
        guard case .loaded(let current) = phase, current != isPrivate, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        try await visibility.setActiveProfilePrivate(isPrivate)
        phase = .loaded(isPrivate: isPrivate)
    }
}
