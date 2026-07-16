import CoreModels
import CoreNavigation
import Foundation

@MainActor
public final class ConversationListViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([ConversationDisplayModel])
        case empty
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    private let repository: any ChatProviding
    private let router: (any Router)?
    private let directory: ConversationDirectory?
    private let now: @Sendable () -> Date

    private var conversations: [Conversation] = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var load: Task<Void, Never>?

    // Inbox management state. IN-SESSION ONLY by design: chat.v1 has no
    // pin/mute/delete plane yet — when it grows one, these become optimistic
    // mirrors of server calls and survive relaunch; the UI contract is final.
    private var pinned: Set<ConversationID> = []
    private var muted: Set<ConversationID> = []
    private var deleted: Set<ConversationID> = []

    public init(
        repository: any ChatProviding,
        router: (any Router)? = nil,
        directory: ConversationDirectory? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.router = router
        self.directory = directory
        self.now = now
    }

    public func viewWillAppear() {
        // Reload each time it appears so a just-sent message updates the preview.
        reload()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// Opens the tapped conversation via routing (the resolver pushes the
    /// thread). Chat never navigates directly.
    public func didSelect(_ id: ConversationID) {
        router?.route(to: .conversation(id))
    }

    /// The compose (new message) entry point, same seam as `didSelect`: emit
    /// the route and let the resolver own the contact-selection flow.
    public func didTapCompose() {
        router?.route(to: .newMessage)
    }

    // MARK: - Inbox management

    public func isPinned(_ id: ConversationID) -> Bool { pinned.contains(id) }
    public func isMuted(_ id: ConversationID) -> Bool { muted.contains(id) }

    public func togglePin(_ id: ConversationID) {
        pinned.formSymmetricDifference([id])
        emit()
    }

    public func toggleMute(_ id: ConversationID) {
        muted.formSymmetricDifference([id])
        emit()
    }

    /// Removes conversations from the inbox (single swipe or batch edit).
    /// Local until the backend grows a leave/delete RPC — the filter is
    /// re-applied across reloads so deleted rows never resurface mid-session.
    public func delete(_ ids: Set<ConversationID>) {
        deleted.formUnion(ids)
        emit()
    }

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.loadConversations()
                self.conversations = loaded
                // Warm the thread screens' identity cache: a row tap must
                // show its header context at push-frame zero, synchronously.
                self.directory?.remember(loaded)
                self.emit()
            } catch is CancellationError {
                // Superseded.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load your messages. Pull to retry.")
                }
            }
            self.load = nil
        }
    }

    /// One projection of loaded conversations through the management state:
    /// deleted rows filtered out, pinned rows first (recency order preserved
    /// within each group — the repository sorts), flags onto display models.
    private func emit() {
        let visible = conversations.filter { !deleted.contains($0.id) }
        guard !visible.isEmpty else {
            phase = .empty
            return
        }
        let now = now()
        let ordered = visible.filter { pinned.contains($0.id) } + visible.filter { !pinned.contains($0.id) }
        phase = .content(ordered.map {
            ConversationDisplayModel(
                conversation: $0,
                now: now,
                isPinned: pinned.contains($0.id),
                isMuted: muted.contains($0.id)
            )
        })
    }
}
