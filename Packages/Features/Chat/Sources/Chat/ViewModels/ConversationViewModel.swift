import CoreModels
import CoreNavigation
import Foundation

/// What thread a screen is showing.
///
/// `.draft` is the compose path: the viewer picked a person, and whether a
/// conversation with them exists is a question the *network* answers. Finding
/// out costs a `ListSubscriptions` plus a `ListMembers` per conversation, which
/// is far too much to spend between a finger going down and a screen appearing
/// — so the thread opens on the identity alone and resolves underneath itself.
public enum ConversationTarget: Equatable, Sendable {
    case existing(ConversationID)
    /// A conversation with `peer`, to be found-or-created. `displayName` is
    /// whatever the origin already knew; empty means "look it up once there is
    /// a conversation to look it up from".
    case draft(peer: ProfileID, displayName: String)
}

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
    /// Fired the moment this thread counts as read — before the server write,
    /// so the inbox underneath is already correct by the time anyone can
    /// navigate back to it.
    public var onDidMarkRead: ((ConversationID) -> Void)?
    /// Fired if that write then failed, so the inbox can put the row back.
    public var onMarkReadDidFail: ((ConversationID) -> Void)?
    /// Fired when the viewer's own message has been accepted by the server.
    /// The inbox listens so the row's preview, time and position are already
    /// right underneath this screen — sending changes all three.
    public var onDidSendMessage: ((ConversationID, ChatMessage) -> Void)?
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
    /// A draft's conversation now exists. The inbox listens so a thread the
    /// viewer started from the compose picker appears in the list behind them.
    public var onDidResolveConversation: ((ConversationID) -> Void)?

    private let target: ConversationTarget
    private let repository: any ChatProviding
    private let directory: ConversationDirectory?
    private let router: (any Router)?

    /// `nil` for a draft until its conversation resolves. Everything that
    /// writes — sending, marking read — goes through `resolveConversation()`
    /// rather than reading this, so none of them can act on a half-open thread.
    private var conversationID: ConversationID?
    /// Single-flight find-or-create. Started when the screen loads and awaited
    /// again by the first send, so a viewer who types faster than the network
    /// waits exactly once and nobody creates two conversations.
    private var resolution: Task<ConversationID?, Never>?

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
        target: ConversationTarget,
        repository: any ChatProviding,
        directory: ConversationDirectory? = nil,
        router: (any Router)? = nil
    ) {
        self.target = target
        self.repository = repository
        self.directory = directory
        self.router = router
        if case .existing(let id) = target { conversationID = id }
    }

    /// The ordinary entry: a thread that already exists.
    public convenience init(
        conversationID: ConversationID,
        repository: any ChatProviding,
        directory: ConversationDirectory? = nil,
        router: (any Router)? = nil
    ) {
        self.init(
            target: .existing(conversationID),
            repository: repository,
            directory: directory,
            router: router
        )
    }

    public func viewDidLoad() {
        loadTitle()
        switch target {
        case .existing:
            reload()
        case .draft:
            // Stay on the skeleton until the resolution answers. Publishing an
            // empty transcript here would be asserting something not yet known
            // — and when the peer turns out to have history (a thread sitting
            // in Requests, or an inbox that hadn't finished loading when they
            // were picked) the screen said "No messages yet" and then filled
            // itself in, which reads as a glitch. The clean empty state is
            // still what a genuinely new contact lands on; it just waits until
            // that is true.
            phase = .loading
            _ = resolveConversation()
        }
    }

    public func refresh() {
        guard load == nil, conversationID != nil else { return }
        reload()
    }

    /// Finds-or-creates this thread's conversation, exactly once.
    ///
    /// Returns the same task to every caller, so the screen's own resolution
    /// and a send racing it converge on one id — two `directConversation`
    /// calls would create two conversations, and `chat.v1` cannot merge them.
    @discardableResult
    private func resolveConversation() -> Task<ConversationID?, Never> {
        if let resolution { return resolution }
        let task = Task<ConversationID?, Never> { [weak self] in
            guard let self else { return nil }
            guard case .draft(let peer, _) = self.target else { return self.conversationID }
            guard let id = try? await self.repository.directConversation(with: peer) else {
                // Drop the cached task so a later send can try again rather
                // than inheriting this failure forever, and let the viewer type
                // into an empty thread in the meantime.
                self.resolution = nil
                if case .loading = self.phase { self.emit() }
                return nil
            }
            self.adopt(id, peer: peer)
            return id
        }
        resolution = task
        return task
    }

    /// Binds a freshly resolved conversation to this screen.
    private func adopt(_ id: ConversationID, peer: ProfileID) {
        conversationID = id
        // Only when nothing better is known: an existing conversation the
        // inbox has already summarised carries a real preview and timestamp,
        // and overwriting that with a blank draft would degrade the list.
        if directory?.summary(for: id) == nil {
            directory?.remember([
                Conversation(
                    id: id,
                    title: peerName,
                    lastMessage: "",
                    lastActivityAt: nil,
                    otherMemberIDs: [peer]
                )
            ])
        }
        onDidResolveConversation?(id)
        // The origin may not have known who this is (a deep link, a map pin);
        // now that there is a conversation, its summary can say.
        if peerName.isEmpty { loadTitle() }
        // Adopt whatever history the peer already had. Failures stay silent —
        // `reload` only reports one when there is no content, and the empty
        // transcript published at load counts.
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
            // A draft's conversation may still be being created. The send joins
            // the resolution the screen already started rather than beginning
            // one of its own — the wait lands here, on a message the viewer has
            // committed to, instead of on the tap that opened the screen.
            guard let id = await self.resolveConversation().value else {
                self.setSending(false)
                self.onActionNotice?(
                    "Couldn't send",
                    "This conversation couldn't be started. Please try again."
                )
                return
            }
            if let message = try? await self.repository.send(body, to: id, replyingTo: replyTo) {
                self.messages.append(message)
                self.emit()
                // Only reached when the send succeeded, so there is nothing to
                // roll back — an optimistic bubble the server rejected never
                // gets this far.
                self.onDidSendMessage?(id, message)
                await self.markRead(id, upTo: message.id)
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

    /// Announces the read FIRST, then moves the cursor server-side.
    ///
    /// The order is the point. The inbox has to be correct *underneath* this
    /// screen, not after it closes: a back swipe reveals the list
    /// progressively, so anything that lands after the transition is a
    /// visible jump. Announcing before the `await` means the inbox has already
    /// dropped this row — and possibly retired its Unread tab — while the
    /// viewer is still reading, leaving nothing to update on the way out.
    ///
    /// The write can still fail, so it reports that too and the inbox rolls
    /// the row back.
    private func markRead(_ id: ConversationID, upTo messageID: String) async {
        onDidMarkRead?(id)
        do {
            try await repository.markRead(id, upTo: messageID)
        } catch {
            onMarkReadDidFail?(id)
        }
    }

    private func reload() {
        guard let conversationID else { return }
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.loadMessages(in: conversationID)
                self.messages = loaded
                self.emit()
                if let last = loaded.last {
                    await self.markRead(conversationID, upTo: last.id)
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
        // A draft arrives with the identity the origin was already rendering —
        // the picker row, the suggestion, the map pin — so the header is right
        // at frame zero without consulting anything. This is what lets the
        // whole screen open instantly rather than assembling itself on screen.
        if case .draft(let peer, let displayName) = target, !displayName.isEmpty {
            peerProfileID = peer
            peerName = displayName
            onTitleChange?(displayName)
            return
        }
        guard let conversationID else { return }
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
            if let summary = try? await self.repository.conversationSummary(for: conversationID),
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
