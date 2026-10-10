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

    /// A setting read beside Private Account, each with its own row.
    enum SideSetting: Hashable, CaseIterable {
        case postWindow, commentAudience, interactionAudiences, postSharing
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
    /// Who may mention and message this profile (#397); nil until read or
    /// when the screen can't set them.
    private(set) var mentionAudience: InteractionAudience? {
        didSet { onChange?() }
    }
    private(set) var messageAudience: InteractionAudience? {
        didSet { onChange?() }
    }
    /// Side settings whose read failed with nothing older to show (#799).
    ///
    /// ⚠️ **THEY USED TO VANISH.** Each was read with `try?`, and the screen
    /// draws a row only once its value is known, so a failed read simply
    /// removed "Who Can Comment" or "Allow Downloads" from Privacy: a
    /// screen that read as complete, missing the very setting the viewer came
    /// to check. A failed one now shows a failed row that reloads only it.
    private(set) var failedSides: Set<SideSetting> = [] {
        didSet { if failedSides != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private let visibility: any ProfileVisibilityManaging
    let requests: (any FollowRequestsManaging)?
    let windows: (any PostWindowManaging)?
    let comments: (any CommentAudienceManaging)?
    let sharing: (any PostSharingManaging)?
    let audiences: (any InteractionAudienceManaging)?

    init(
        visibility: any ProfileVisibilityManaging,
        requests: (any FollowRequestsManaging)? = nil,
        windows: (any PostWindowManaging)? = nil,
        comments: (any CommentAudienceManaging)? = nil,
        sharing: (any PostSharingManaging)? = nil,
        audiences: (any InteractionAudienceManaging)? = nil
    ) {
        self.audiences = audiences
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

    /// Not optimistic: the value shown is the server's.
    func setAudience(_ audience: InteractionAudience, for kind: InteractionKind) async throws {
        guard let audiences else { return }
        let current = kind == .mentions ? mentionAudience : messageAudience
        guard audience != current else { return }
        try await audiences.setAudience(audience, for: kind)
        switch kind {
        case .mentions: mentionAudience = audience
        case .messages: messageAudience = audience
        }
    }

    /// Not optimistic: the switches show the server's values.
    func setPostSharing(_ next: PostSharing) async throws {
        guard let sharing, next != postSharing else { return }
        try await sharing.setPostSharing(next)
        postSharing = next
    }

    /// Reads everything the screen shows, side by side. Returns once every
    /// read has settled, so a caller (or a test) sees the whole outcome; each
    /// row still appears as soon as its own value lands.
    ///
    /// The follow-request count is not a side setting: unread it only leaves
    /// the row's badge blank, and the inbox it opens loads, fails and retries
    /// on its own.
    func load() async {
        if case .failed = phase { phase = .loading }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.refreshRequestCount() }
            for side in SideSetting.allCases {
                group.addTask { await self.reload(side) }
            }
            group.addTask { await self.loadVisibility() }
        }
    }

    private func loadVisibility() async {
        do {
            phase = .loaded(isPrivate: try await visibility.activeProfileIsPrivate())
        } catch {
            phase = .failed
        }
    }

    /// Reads one side setting — the failed row's retry. A value already on
    /// screen outlives a failed refresh; with none, the side is marked
    /// failed. Returns false when the read failed (the screen toasts a
    /// retry that fails again). A side the screen can't set reads as done.
    @discardableResult
    func reload(_ side: SideSetting) async -> Bool {
        do {
            switch side {
            case .postWindow:
                guard let windows else { return true }
                postWindow = try await windows.postWindow()
            case .commentAudience:
                guard let comments else { return true }
                commentAudience = try await comments.commentAudience()
            case .interactionAudiences:
                guard let audiences else { return true }
                // One row pair, one read: both or the failed row.
                async let mentions = audiences.audience(for: .mentions)
                async let messages = audiences.audience(for: .messages)
                let (mention, message) = try await (mentions, messages)
                mentionAudience = mention
                messageAudience = message
            case .postSharing:
                guard let sharing else { return true }
                postSharing = try await sharing.postSharing()
            }
            failedSides.remove(side)
            return true
        } catch {
            if !hasValue(side) { failedSides.insert(side) }
            return false
        }
    }

    private func hasValue(_ side: SideSetting) -> Bool {
        switch side {
        case .postWindow: postWindow != nil
        case .commentAudience: commentAudience != nil
        case .interactionAudiences: mentionAudience != nil && messageAudience != nil
        case .postSharing: postSharing != nil
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
