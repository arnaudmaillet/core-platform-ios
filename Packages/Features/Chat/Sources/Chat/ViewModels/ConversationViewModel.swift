import CoreModels
import CoreNavigation
import Foundation

@MainActor
public final class ConversationViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([MessageDisplayModel])
        case failed(message: String)
    }

    /// Bubble context-menu actions the view can request. Copy is absent by
    /// design: it completes in the view layer (pasteboard, no data plane).
    public nonisolated enum MessageAction: Sendable {
        case reply
        case forward
        case delete
    }

    public var onPhaseChange: ((Phase) -> Void)?
    /// True while a message is being sent (disables the send control).
    public var onSendingChange: ((Bool) -> Void)?
    /// Fires once the peer's name resolves; best-effort (no title on failure).
    public var onTitleChange: ((String) -> Void)?
    /// Transient user-facing notice `(title, message)` — the view presents it
    /// modally (same honest-seam surface as the compose bar's media stub).
    public var onActionNotice: ((String, String) -> Void)?

    private let conversationID: ConversationID
    private let repository: any ChatProviding
    private let directory: ConversationDirectory?
    private let router: (any Router)?

    private var messages: [ChatMessage] = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var isSending = false
    private var load: Task<Void, Never>?
    /// The DM correspondent, once known — the header identity's destination.
    private var peerProfileID: ProfileID?

    public init(
        conversationID: ConversationID,
        repository: any ChatProviding,
        directory: ConversationDirectory? = nil,
        router: (any Router)? = nil
    ) {
        self.conversationID = conversationID
        self.repository = repository
        self.directory = directory
        self.router = router
    }

    public func viewDidLoad() {
        reload()
        loadTitle()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// Sends a message and appends it. Empty/whitespace input is ignored.
    public func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        setSending(true)
        Task { [weak self] in
            guard let self else { return }
            if let message = try? await self.repository.send(body, to: self.conversationID) {
                self.messages.append(message)
                self.emit()
                try? await self.repository.markRead(self.conversationID, upTo: message.id)
            }
            self.setSending(false)
        }
    }

    /// The context menu's action funnel. Every case is an honest stub today —
    /// chat.v1's write plane is send + markRead, nothing else — kept as one
    /// exhaustive switch so each branch picks up its repository call without
    /// reshaping the view: swap the notice for the call, keep the signature.
    public func perform(_ action: MessageAction, on messageID: String) {
        switch action {
        case .reply:
            // Needs a reply-to reference on chat.v1 SendMessage.
            onActionNotice?("Reply", "Replying to a specific message isn't available yet.")
        case .forward:
            // Needs a conversation picker and a cross-thread send.
            onActionNotice?("Forward", "Forwarding messages isn't available yet.")
        case .delete:
            // Needs a chat.v1 DeleteMessage; a local-only removal would
            // resurrect on the next refresh, so no optimistic fake here.
            onActionNotice?("Delete", "Deleting messages isn't available yet.")
        }
    }

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.loadMessages(in: self.conversationID)
                self.messages = loaded
                self.emit()
                if let last = loaded.last {
                    try? await self.repository.markRead(self.conversationID, upTo: last.id)
                }
            } catch is CancellationError {
                // Superseded.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load this conversation. Pull to retry.")
                }
            }
            self.load = nil
        }
    }

    /// Tapping the header identity opens the correspondent's profile —
    /// routed, never navigated directly (chat stays Profile-agnostic). A
    /// no-op until the peer resolves, or for group shapes with no single peer.
    public func didTapIdentity() {
        guard let peerProfileID else { return }
        // No identity stub: the thread knows the peer's display name but not
        // their raw @handle, and the stub must not fabricate one (it becomes
        // the profile screen's title). Same semantics as notification rows.
        router?.route(to: .profile(peerProfileID, stub: nil))
    }

    private func loadTitle() {
        // Cache hit binds SYNCHRONOUSLY inside the view's `viewDidLoad`, i.e.
        // before the push transition's first frame — the list-tap path shows
        // the header identity throughout the animation. Any async hop, even a
        // cached one, resolves after the transition has started.
        if let cached = directory?.summary(for: conversationID), !cached.title.isEmpty {
            peerProfileID = cached.directPeerID
            onTitleChange?(cached.title)
            return
        }
        // Cold entry (deep link, push payload): fetch, then ease the identity
        // in — the data genuinely doesn't exist yet.
        Task { [weak self] in
            guard let self else { return }
            if let summary = try? await self.repository.conversationSummary(for: self.conversationID),
               !summary.title.isEmpty {
                self.peerProfileID = summary.directPeerID
                self.onTitleChange?(summary.title)
            }
        }
    }

    private func emit() {
        phase = .content(messages.map(MessageDisplayModel.init))
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        onSendingChange?(sending)
    }
}
