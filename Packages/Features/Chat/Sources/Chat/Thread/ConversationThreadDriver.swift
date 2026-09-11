import CoreModels
import FeedInterface
import Foundation

/// Drives Feed's conversation screen from the thread's view model.
///
/// A pass-through, deliberately: `ConversationViewModel` keeps every rule it
/// has — sending, replies, the session-local delete, the draft that resolves
/// underneath, mark-read and the inbox callbacks the builder wires on it — and
/// this only re-spells its outputs in the values Feed's screen reads.
@MainActor
final class ConversationThreadDriver: ConversationThreadDriving {
    var onPhaseChange: ((ConversationThreadPhase) -> Void)?
    var onPeerChange: ((ConversationThreadPerson) -> Void)?
    var onViewerChange: ((ConversationThreadPerson) -> Void)?
    var onSendingChange: ((Bool) -> Void)?
    var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
    var onActionNotice: ((String, String) -> Void)?

    /// What the viewer's own rows are signed with.
    ///
    /// ⚠️ NOT the viewer's name, because chat does not know it: it knows the id
    /// it sends as, and nothing else. The comments' active profile does know a
    /// name, but on an account with several profiles it can be a different
    /// profile from the one this conversation sends as — so borrowing it would
    /// sign the viewer's messages with someone the server will not say sent
    /// them.
    static let viewerName = "You"

    private let viewModel: ConversationViewModel
    private let viewer: any ViewerIdentityProviding
    private let avatars: (any PeerAvatarProviding)?

    private var peer = ConversationThreadPerson(id: nil, name: "", avatarURL: nil)
    /// The last transcript, kept so a late peer name re-signs the quotes.
    private var lastMessages: [MessageDisplayModel]?

    init(
        viewModel: ConversationViewModel,
        viewer: any ViewerIdentityProviding,
        avatars: (any PeerAvatarProviding)?
    ) {
        self.viewModel = viewModel
        self.viewer = viewer
        self.avatars = avatars
        viewModel.onPhaseChange = { [weak self] phase in self?.forward(phase) }
        // The name and the id arrive as a pair, name first; both are forwarded
        // synchronously so a warm conversation's header is right on the push's
        // first frame (the directory warm-start the old screen was built on).
        viewModel.onTitleChange = { [weak self] name in self?.adoptPeer(name: name) }
        viewModel.onPeerChange = { [weak self] id in self?.adoptPeer(id: id) }
        viewModel.onSendingChange = { [weak self] sending in self?.onSendingChange?(sending) }
        viewModel.onReplyStateChange = { [weak self] draft in
            self?.onReplyStateChange?(draft.map {
                ConversationThreadReplyDraft(messageID: $0.messageID, author: $0.author, snippet: $0.snippet)
            })
        }
        viewModel.onActionNotice = { [weak self] title, message in self?.onActionNotice?(title, message) }
    }

    func viewDidLoad() {
        // Signed from frame one; the face arrives when the avatar does.
        onViewerChange?(ConversationThreadPerson(id: nil, name: Self.viewerName, avatarURL: nil))
        resolveViewer()
        viewModel.viewDidLoad()
    }

    func refresh() { viewModel.refresh() }
    func send(_ text: String) { viewModel.send(text) }
    func beginReply(to messageID: String) { viewModel.beginReply(to: messageID) }
    func cancelReply() { viewModel.cancelReply() }
    func forward(_ messageID: String) { viewModel.perform(.forward, on: messageID) }
    func delete(_ messageID: String) { viewModel.deleteMessage(messageID) }
    func didTapIdentity() { viewModel.didTapIdentity() }

    // MARK: - Outputs

    private func forward(_ phase: ConversationViewModel.Phase) {
        switch phase {
        case .loading:
            onPhaseChange?(.loading)
        case .failed(let message):
            onPhaseChange?(.failed(message))
        case .content(let models):
            lastMessages = models
            onPhaseChange?(.content(Self.messages(from: models, peerName: peer.name)))
        }
    }

    /// Oldest first, with each reply's quote resolved against the whole set —
    /// a reply can answer a message from any earlier day.
    static func messages(from models: [MessageDisplayModel], peerName: String) -> [ConversationThreadMessage] {
        let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return models.map { model in
            let quote = model.replyToID.flatMap { byID[$0] }.map { original in
                ConversationThreadMessage.Quote(
                    messageID: original.id,
                    author: ChatTranscript.quoteAuthor(isMine: original.isMine, peerName: peerName),
                    snippet: ChatTranscript.snippet(original.body)
                )
            }
            return ConversationThreadMessage(
                id: model.id, senderID: model.senderID, body: model.body,
                sentAt: model.sentAt, isMine: model.isMine, quote: quote
            )
        }
    }

    private func adoptPeer(name: String) {
        peer = ConversationThreadPerson(id: peer.id, name: name, avatarURL: peer.avatarURL)
        onPeerChange?(peer)
        // Quotes of the peer's messages were signed with a placeholder until now.
        if let lastMessages {
            onPhaseChange?(.content(Self.messages(from: lastMessages, peerName: name)))
        }
    }

    private func adoptPeer(id: ProfileID?) {
        guard id != peer.id else { return }
        peer = ConversationThreadPerson(id: id, name: peer.name, avatarURL: nil)
        onPeerChange?(peer)
        guard let id, let avatars else { return }
        Task { [weak self] in
            let url = await avatars.avatarURLs(for: [id])[id]
            guard let self, let url, self.peer.id == id else { return }
            self.peer = ConversationThreadPerson(id: id, name: self.peer.name, avatarURL: url)
            self.onPeerChange?(self.peer)
        }
    }

    private func resolveViewer() {
        let viewer = viewer
        let avatars = avatars
        Task { [weak self] in
            guard let id = try? await viewer.viewerProfileID() else { return }
            let url = await avatars?.avatarURLs(for: [id])[id]
            self?.onViewerChange?(ConversationThreadPerson(id: id, name: Self.viewerName, avatarURL: url))
        }
    }
}
