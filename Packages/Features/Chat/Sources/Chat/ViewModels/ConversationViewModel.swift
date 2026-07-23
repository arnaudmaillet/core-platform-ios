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

    /// The active reply target, surfaced to the compose bar's preview: who is
    /// being answered and a one-line excerpt of their message.
    public nonisolated struct ReplyDraft: Equatable, Sendable {
        public let messageID: String
        public let author: String
        public let snippet: String
    }

    public var onPhaseChange: ((Phase) -> Void)?
    /// True while a message is being sent (disables the send control).
    public var onSendingChange: ((Bool) -> Void)?
    /// Fires once the peer's name resolves; best-effort (no title on failure).
    public var onTitleChange: ((String) -> Void)?
    /// The active reply target (or `nil` when cleared) — drives the compose
    /// bar's reply preview.
    public var onReplyStateChange: ((ReplyDraft?) -> Void)?
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
    /// The correspondent's display name, once resolved — labels reply drafts.
    private var peerName = ""
    /// The message currently being replied to; folded into the next send.
    private var replyingToID: String?
    /// Messages deleted this session. chat.v1 has no DeleteMessage RPC
    /// (`dev/BACKEND_GAPS.md`), so removal is local — this set filters them
    /// back out of every reload, exactly as the conversation list does.
    private var deletedMessageIDs: Set<String> = []

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

    /// Sends a message and appends it, carrying the active reply reference if
    /// any. Empty/whitespace input is ignored. The reply state clears up front,
    /// so the compose preview collapses as the bubble flies out.
    public func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        let replyTo = replyingToID
        cancelReply()
        setSending(true)
        Task { [weak self] in
            guard let self else { return }
            if let message = try? await self.repository.send(body, to: self.conversationID, replyingTo: replyTo) {
                self.messages.append(message)
                self.emit()
                try? await self.repository.markRead(self.conversationID, upTo: message.id)
            }
            self.setSending(false)
        }
    }

    /// The context menu's action funnel. Reply and Delete are wired; Forward
    /// remains an honest stub (needs a conversation picker + cross-thread
    /// send). Delete here is unconfirmed — the view gates it behind a native
    /// confirmation before calling.
    public func perform(_ action: MessageAction, on messageID: String) {
        switch action {
        case .reply:
            beginReply(to: messageID)
        case .forward:
            onActionNotice?("Forward", "Forwarding messages isn't available yet.")
        case .delete:
            deleteMessage(messageID)
        }
    }

    /// Enters reply mode for `messageID`, publishing the draft the compose bar
    /// previews. A no-op if the message isn't in the loaded transcript.
    public func beginReply(to messageID: String) {
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        replyingToID = messageID
        onReplyStateChange?(ReplyDraft(
            messageID: messageID,
            author: ChatTranscript.quoteAuthor(isMine: message.isMine, peerName: peerName),
            snippet: ChatTranscript.snippet(message.body)
        ))
    }

    /// Leaves reply mode. Idempotent — silent when not replying.
    public func cancelReply() {
        guard replyingToID != nil else { return }
        replyingToID = nil
        onReplyStateChange?(nil)
    }

    /// Removes a message from the thread. Session-local (no DeleteMessage RPC):
    /// `deletedMessageIDs` keeps it out of subsequent reloads. Re-emits so the
    /// diffable data source animates the row out.
    public func deleteMessage(_ messageID: String) {
        guard messages.contains(where: { $0.id == messageID }) else { return }
        deletedMessageIDs.insert(messageID)
        if replyingToID == messageID { cancelReply() }
        emit()
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
            peerName = cached.title
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
                self.peerName = summary.title
                self.onTitleChange?(summary.title)
                // Re-render so quotes from the peer pick up their now-known
                // author name (content may have landed before the title did).
                if case .content = self.phase { self.emit() }
            }
        }
    }

    private func emit() {
        // One pass; skip the filter entirely in the common no-deletions case.
        let models = deletedMessageIDs.isEmpty
            ? messages.map(MessageDisplayModel.init)
            : messages.compactMap { deletedMessageIDs.contains($0.id) ? nil : MessageDisplayModel(message: $0) }
        phase = .content(models)
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        onSendingChange?(sending)
    }
}
