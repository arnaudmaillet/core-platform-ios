import CoreModels
import CoreNavigation
import CoreNetworking
import Foundation
import UIKit

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

    /// Message context-menu actions the view can request. Copy is absent by
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
    /// A photo or video was uploaded and sent: the picture the viewer picked
    /// and the URL it now lives at (a video's still's), for the image cache —
    /// so a reopened thread draws it without a fetch (#681).
    public var onDidUploadMedia: ((UIImage, URL) -> Void)?
    /// True while a message is being sent (disables the send control).
    public var onSendingChange: ((Bool) -> Void)?
    /// Fires once the peer's name resolves; best-effort (no title on failure).
    /// The header's name changed. Carries the peer id alongside it so the
    /// host can fetch a face — a DM resolves its correspondent at the same
    /// moment it resolves the name, and a group passes `nil` and keeps
    /// initials.
    public var onTitleChange: ((String) -> Void)?
    /// Fired with `onTitleChange`, for the avatar. Separate so the existing
    /// title path stays untouched for callers that only want the name.
    public var onPeerChange: ((ProfileID?) -> Void)?
    /// The active reply target (or `nil` when cleared) — drives the compose
    /// bar's reply preview.
    public var onReplyStateChange: ((ReplyDraft?) -> Void)?
    /// Transient user-facing notice `(title, message)` — the view presents it
    /// modally (same honest-seam surface as the compose bar's media stub).
    public var onActionNotice: ((String, String) -> Void)?
    /// A draft's conversation now exists. The inbox listens so a thread the
    /// viewer started from the compose picker appears in the list behind them.
    public var onDidResolveConversation: ((ConversationID) -> Void)?
    /// An older page of history is on its way (true) or has answered (false)
    /// — the thread says so at its top (#600).
    public var onLoadingOlderChange: ((Bool) -> Void)?

    private let target: ConversationTarget
    private let repository: any ChatProviding
    private let directory: ConversationDirectory?
    private let router: (any Router)?

    /// `nil` for a draft until its conversation resolves. Everything that
    /// writes — sending, marking read — goes through `resolveConversation()`
    /// rather than reading this, so none of them can act on a half-open thread.
    private var conversationID: ConversationID?

    /// The conversation on screen, once there is one — nil for a draft until
    /// it resolves. For inbox state keyed by conversation (its pin), which
    /// waits for a real one rather than creating it.
    public var currentConversationID: ConversationID? { conversationID }
    /// Single-flight find-or-create. Started when the screen loads and awaited
    /// again by the first send, so a viewer who types faster than the network
    /// waits exactly once and nobody creates two conversations.
    private var resolution: Task<ConversationID?, Never>?

    private var messages: [ChatMessage] = []
    /// Where the next OLDER page of history starts; nil when there is none,
    /// or before the newest page has answered (#600).
    private var olderPageToken: String?
    /// The older page being fetched — one at a time.
    private var olderLoad: Task<Void, Never>?
    /// Pages older than the newest are on screen: a reload merges its page
    /// under them rather than cutting the transcript back to one page.
    private var hasOlderPages = false
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var recovery: RecoveryObservation?
    /// The monitor whose recoveries reload this store — the shared one; a
    /// test hands its own (the shared one is process-wide).
    var connectivity: ConnectivityMonitor = .shared
    private var isSending = false
    private var load: Task<Void, Never>?
    /// The DM correspondent, once known — the header identity's destination.
    private var peerProfileID: ProfileID?
    /// The correspondent's display name, once resolved — labels reply drafts.
    private var peerName = ""
    /// The message currently being replied to; folded into the next send.
    private var replyingToID: String?
    /// The viewer's messages on their way (or failed) — photos and videos
    /// (#681) and text (#719) — drawn after the transcript in the order sent.
    private var pendingSends: [PendingSend] = []
    private var pendingCount = 0
    /// Pending sends being delivered now — never twice at once.
    private var delivering: Set<String> = []
    /// The picture each sent media message was picked as, so the viewer's
    /// own bubble keeps drawing it instead of waiting on the network.
    private var localPreviews: [String: UIImage] = [:]
    /// The profile this conversation sends as — signs a pending bubble.
    private var senderID = ProfileID("")

    private struct PendingSend {
        let id: String
        /// What is sent: a photo or video, or text.
        let payload: Payload
        let replyTo: String?
        let createdAt: Date
        var failed = false

        enum Payload {
            /// The picture or clip, and the media.v1 idempotency key its
            /// upload goes under (#795).
            ///
            /// ⚠️ **MINTED WITH THE BUBBLE, NOT WITH THE ATTEMPT.** `retry`
            /// sends the same payload again, key included, so a message whose
            /// first answer was lost replays its upload instead of storing
            /// the picture a second time. (Text has no key: chat.v1
            /// `SendMessage` carries none — see `ChatRepository.sendMessage`.)
            case media(ChatMediaUpload, uploadKey: String)
            case text(String)
        }

        var isText: Bool {
            if case .text = payload { return true }
            return false
        }
    }

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
        armRecovery()
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

    /// Sends a message, carrying the active reply reference if any.
    /// Empty/whitespace input is ignored. The reply state clears up front, so
    /// the compose preview collapses as the message flies out.
    ///
    /// ⚠️ OPTIMISTIC SINCE #719: the message is drawn at once as a pending
    /// one, on its way (`delivery == .sending`), and turns into the delivered
    /// message — or into a failed one with a retry (`retry`) — rather than
    /// appearing only once the server has answered.
    public func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        let replyTo = replyingToID
        cancelReply()
        pendingCount += 1
        let pendingID = "pending-\(pendingCount)"
        pendingSends.append(PendingSend(id: pendingID, payload: .text(body), replyTo: replyTo, createdAt: Date()))
        emit()
        setSending(true)
        Task { [weak self] in
            guard let self else { return }
            if self.senderID.rawValue.isEmpty, let me = try? await self.repository.viewerProfileID() {
                self.senderID = me
                self.emit()
            }
            await self.deliver(pendingID)
            self.setSending(false)
        }
    }

    /// Sends photos and videos, one message each, in the order picked
    /// (#681). Each appears at once as a pending bubble, wearing the picture
    /// picked, and turns into the delivered message — or into a failed one
    /// with a retry (`retry`).
    public func send(media uploads: [ChatMediaUpload]) {
        guard !uploads.isEmpty else { return }
        let replyTo = replyingToID
        cancelReply()
        var ids: [String] = []
        for (index, upload) in uploads.enumerated() {
            pendingCount += 1
            let id = "pending-\(pendingCount)"
            ids.append(id)
            pendingSends.append(PendingSend(
                id: id, payload: .media(upload, uploadKey: UUID().uuidString),
                replyTo: index == 0 ? replyTo : nil, createdAt: Date()
            ))
        }
        emit()
        Task { [weak self] in
            guard let self else { return }
            if self.senderID.rawValue.isEmpty, let me = try? await self.repository.viewerProfileID() {
                self.senderID = me
                self.emit()
            }
            // One at a time, so they land in the order they were picked.
            for id in ids { await self.deliver(id) }
        }
    }

    /// Sends a failed message again — text or a photo or video.
    public func retry(_ messageID: String) {
        guard let index = pendingSends.firstIndex(where: { $0.id == messageID }), pendingSends[index].failed else { return }
        pendingSends[index].failed = false
        emit()
        Task { [weak self] in await self?.deliver(messageID) }
    }

    private func deliver(_ pendingID: String) async {
        guard let pending = pendingSends.first(where: { $0.id == pendingID }), !pending.failed,
              !delivering.contains(pendingID) else { return }
        delivering.insert(pendingID)
        defer { delivering.remove(pendingID) }
        // A draft's conversation may still be being created. The send joins
        // the resolution the screen already started rather than beginning one
        // of its own — the wait lands on a message the viewer has committed to.
        guard let id = await resolveConversation().value else {
            markFailed(pendingID)
            return
        }
        do {
            let message: ChatMessage
            switch pending.payload {
            case .text(let body):
                message = try await repository.send(body, to: id, replyingTo: pending.replyTo)
            case .media(let upload, let uploadKey):
                message = try await repository.send(
                    media: upload, caption: "", to: id, replyingTo: pending.replyTo, idempotencyKey: uploadKey
                )
                if let preview = upload.preview {
                    localPreviews[message.id] = preview
                    if let media = message.media, let url = media.kind == .video ? media.posterURL : media.url {
                        onDidUploadMedia?(preview, url)
                    }
                }
            }
            pendingSends.removeAll { $0.id == pendingID }
            messages.append(message)
            emit()
            onDidSendMessage?(id, message)
            await markRead(id, upTo: message.id)
        } catch {
            markFailed(pendingID)
            // A refusal is said; a failed text says so too, as it always did
            // — the failed row offers the retry. A failed photo or video
            // says so only when the connection is why (#794): its bubble
            // reads "Not sent", which cannot tell the viewer they're offline.
            if (error as? ChatError) == .messagesRefused || pending.isText || Self.isConnectionFailure(error) {
                let notice = Self.sendFailureNotice(error, isMedia: !pending.isText)
                onActionNotice?(notice.title, notice.message)
            }
        }
    }

    private func markFailed(_ pendingID: String) {
        guard let index = pendingSends.firstIndex(where: { $0.id == pendingID }) else { return }
        pendingSends[index].failed = true
        emit()
    }

    /// What a message that didn't go says: the recipient takes none (#397),
    /// or it simply failed — titled "You’re offline" or "That took too long"
    /// when that is why (#794), the media upload's failure included.
    static func sendFailureNotice(_ error: Error, isMedia: Bool = false) -> (title: String, message: String) {
        if (error as? ChatError) == .messagesRefused {
            return ("Can't Send Message", "This account doesn't take messages.")
        }
        let title = FailureCopy.title(for: error, fallback: "Couldn't send")
        return isMedia
            ? (title, "Your photo or video wasn\u{2019}t sent. Tap it to try again.")
            : (title, "Your message wasn\u{2019}t sent. Check your connection and try again.")
    }

    /// Whether a send failed for want of a connection: offline or out of
    /// time — the causes worth a word beyond the failed bubble (#794).
    static func isConnectionFailure(_ error: Error) -> Bool {
        switch NetworkFailure.of(error) {
        case .offline, .timeout: true
        default: false
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
            snippet: ChatTranscript.snippet(message.summary)
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
        // A failed photo or video is discarded, not deleted: it never left.
        if pendingSends.contains(where: { $0.id == messageID }) {
            pendingSends.removeAll { $0.id == messageID }
            emit()
            return
        }
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
                let page = try await self.repository.loadMessagesPage(in: conversationID, before: nil)
                let loaded = page.messages
                if self.hasOlderPages {
                    // Older pages are on screen: the fresh newest page goes
                    // over the old one and everything older stays, so a
                    // refresh never yanks the reader out of the past.
                    self.messages = Self.merging(newestPage: loaded, over: self.messages)
                } else {
                    self.messages = loaded
                    self.olderPageToken = page.olderPageToken
                }
                self.emit()
                if let last = loaded.last {
                    await self.markRead(conversationID, upTo: last.id)
                }
            } catch is CancellationError {
                // Superseded.
            } catch {
                if case .content = self.phase {} else {
                    // "You're offline" when that is why (#794).
                    self.phase = .failed(message: FailureCopy.message(
                        for: error, fallback: "Couldn't load this conversation"
                    ))
                }
            }
            self.load = nil
        }
    }

    /// The reader neared the top of the thread: the page of history before
    /// the oldest message shown, if there is one and none is on its way
    /// (#600). Prepended — the thread reads downward — and a failure is
    /// retried on the next approach.
    public func loadOlder() {
        guard olderLoad == nil, let conversationID, let token = olderPageToken else { return }
        olderLoad = Task { [weak self] in
            await self?.prependOlder(in: conversationID, before: token)
        }
        onLoadingOlderChange?(true)
    }

    private func prependOlder(in conversationID: ConversationID, before token: String) async {
        let page = try? await repository.loadMessagesPage(in: conversationID, before: token)
        // ⚠️ The slot frees BEFORE the rows render: a page that lands wholly
        // on screen asks for the next one while it renders (#596).
        olderLoad = nil
        // Said before the rows land, so the indicator is gone the moment they
        // are there to read.
        onLoadingOlderChange?(false)
        // A failure waits for the next approach; a reload that replaced the
        // transcript meanwhile owns the cursor now.
        guard let page, self.conversationID == conversationID, olderPageToken == token else { return }
        olderPageToken = page.olderPageToken
        // A message can sit on both sides of a page boundary.
        let known = Set(messages.map(\.id))
        let fresh = page.messages.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        hasOlderPages = true
        messages = fresh + messages
        emit()
    }

    /// A reloaded newest page over a transcript that runs further back: the
    /// page replaces every message at least as recent as its oldest, and every
    /// older message stays. History lists newest first, so a message missing
    /// from the fresh page either slid back (older: kept) or went away (newer:
    /// dropped). Pure, for tests.
    static func merging(newestPage: [ChatMessage], over shown: [ChatMessage]) -> [ChatMessage] {
        guard let oldest = newestPage.map(\.createdAt).min() else { return shown }
        let fresh = Set(newestPage.map(\.id))
        return shown.filter { !fresh.contains($0.id) && $0.createdAt < oldest } + newestPage
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
            onPeerChange?(peerProfileID)
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
            onPeerChange?(peerProfileID)
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
                self.onPeerChange?(self.peerProfileID)
                // Re-render so quotes from the peer pick up their now-known
                // author name (content may have landed before the title did).
                if case .content = self.phase { self.emit() }
            }
        }
    }

    private func emit() {
        let previews = localPreviews
        let shown = deletedMessageIDs.isEmpty ? messages : messages.filter { !deletedMessageIDs.contains($0.id) }
        let models = shown.map { MessageDisplayModel(message: $0, preview: previews[$0.id]) }
        let pending = pendingSends.map { send -> MessageDisplayModel in
            switch send.payload {
            case .media(let upload, _):
                MessageDisplayModel(pending: send.id, upload: upload, sender: senderID, sentAt: send.createdAt, failed: send.failed)
            case .text(let body):
                MessageDisplayModel(
                    pending: send.id, text: body, replyTo: send.replyTo, sender: senderID,
                    sentAt: send.createdAt, failed: send.failed
                )
            }
        }
        phase = .content(models + pending)
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        onSendingChange?(sending)
    }
}
