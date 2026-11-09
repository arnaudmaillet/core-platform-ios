import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import UIKit
import CoreNavigation

/// Makes the sheet a message's photo or video is picked (or captured) in:
/// the upload flow's own (#681), built by the app. It calls back with what
/// was picked, in order; the caller dismisses the sheet.
public typealias ChatMediaPickerFactory = @MainActor (
    _ source: ConversationThreadMediaSource,
    _ completion: @escaping @MainActor ([ChatMediaUpload]) -> Void
) -> UIViewController

/// What a GROUP's thread needs beyond a DM's (#2214), from the feature
/// builder; nil with `-group-chats` off, and every thread is drawn as it was.
@MainActor
struct GroupThreadContext {
    /// The group's identity, members and their profiles.
    let service: any GroupChatServicing
    /// The info screen for a group; the callback runs when it changed the
    /// group (renamed, a member removed), so the thread reads it again.
    let makeInfo: @MainActor (_ id: ConversationID, _ onChange: @escaping @MainActor () -> Void) -> UIViewController
    /// A member's profile, pushed: their id and the name the row showed.
    let openProfile: @MainActor (_ id: ProfileID, _ name: String) -> Void
    /// When the viewer created this group in this session: the thread opens
    /// with "You created the group" (client-side until chat.v1 carries
    /// system events).
    let createdAt: @MainActor (_ id: ConversationID) -> Date?
    /// What the inbox already knows the conversation is; nil when it doesn't
    /// (a cold entry). A known DM never asks for a group's details.
    let knownKind: @MainActor (_ id: ConversationID) -> ConversationKind?
}

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
    var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
    var onActionNotice: ((String, String) -> Void)?
    var onPinnedChange: ((Bool?) -> Void)?
    var onMutedChange: ((Bool?) -> Void)?
    var onLoadingOlderChange: ((Bool) -> Void)?
    var onGroupChange: ((ConversationThreadGroup?) -> Void)?

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

    /// The thread's last-known shape, per conversation (#1774).
    var presenceKey: String? { viewModel.currentConversationID.map { "thread.\($0.rawValue)" } }
    private let mediaPicker: ChatMediaPickerFactory?
    private let viewer: any ViewerIdentityProviding
    private let avatars: (any PeerAvatarProviding)?
    /// The INBOX's pins — the screen's pin writes the very set the list reads,
    /// so the row behind the thread is already where it belongs when the
    /// viewer swipes back. Nil for a screen with no inbox (a peek, a test).
    private let pins: InboxCatalog?
    private var pinObservation: InboxCatalog.ObservationToken?
    /// What `onPinnedChange` last said, so a catalog change that leaves this
    /// conversation alone (another row read, a reload) says nothing.
    private var forwardedPin: Bool?
    private var hasForwardedPin = false
    /// What `onMutedChange` last said (#719), on the same rule.
    private var forwardedMute: Bool?
    private var hasForwardedMute = false

    private var peer = ConversationThreadPerson(id: nil, name: "", avatarURL: nil)
    /// The last transcript, kept so a late peer name re-signs the quotes.
    private var lastMessages: [MessageDisplayModel]?

    /// A group's needs (#2214); nil: every conversation is drawn as a DM.
    private let groupContext: GroupThreadContext?
    /// The group on show, once its details answered (#2214).
    private(set) var group: ConversationThreadGroup?
    private var groupLoad: Task<Void, Never>?

    init(
        viewModel: ConversationViewModel,
        viewer: any ViewerIdentityProviding,
        avatars: (any PeerAvatarProviding)?,
        pins: InboxCatalog? = nil,
        mediaPicker: ChatMediaPickerFactory? = nil,
        groupContext: GroupThreadContext? = nil
    ) {
        self.groupContext = groupContext
        self.viewModel = viewModel
        self.mediaPicker = mediaPicker
        self.viewer = viewer
        self.avatars = avatars
        self.pins = pins
        viewModel.onPhaseChange = { [weak self] phase in self?.forward(phase) }
        // The name and the id arrive as a pair, name first; both are forwarded
        // synchronously so a warm conversation's header is right on the push's
        // first frame (the directory warm-start the old screen was built on).
        viewModel.onTitleChange = { [weak self] name in self?.adoptPeer(name: name) }
        viewModel.onPeerChange = { [weak self] id in self?.adoptPeer(id: id) }
        viewModel.onReplyStateChange = { [weak self] draft in
            guard let self else { return }
            self.onReplyStateChange?(draft.map {
                ConversationThreadReplyDraft(messageID: $0.messageID, author: self.replyAuthor($0), snippet: $0.snippet)
            })
        }
        viewModel.onActionNotice = { [weak self] title, message in self?.onActionNotice?(title, message) }
        viewModel.onLoadingOlderChange = { [weak self] loading in self?.onLoadingOlderChange?(loading) }
        // Every catalog change re-reads this conversation's pin — a toggle
        // from here or from the inbox's own menu, and a draft resolving into
        // a conversation (the builder refreshes the catalog when it does).
        pinObservation = pins?.observe { [weak self] _ in
            self?.forwardPinned()
            self?.forwardMuted()
        }
    }

    func viewDidLoad() {
        // Signed from frame one; the face arrives when the avatar does.
        onViewerChange?(ConversationThreadPerson(id: nil, name: Self.viewerName, avatarURL: nil))
        // The pin from frame one too: the observation above answered before
        // the screen was listening.
        hasForwardedPin = false
        forwardPinned()
        hasForwardedMute = false
        forwardMuted()
        resolveViewer()
        viewModel.viewDidLoad()
        loadGroup()
    }

    // MARK: - Groups (#2214)

    /// Reads the group — identity, members, their profiles — and tells the
    /// screen: its header becomes the group's, and each row is signed by its
    /// sender. A conversation the inbox knows as a DM asks nothing; one it
    /// doesn't know is asked, and a DM answers with no details.
    func loadGroup() {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return }
        let known = context.knownKind(id)
        guard known == nil || known == .group else { return }
        groupLoad?.cancel()
        let service = context.service
        groupLoad = Task { [weak self] in
            guard let identity = try? await service.details(of: id) else { return }
            let members = (try? await service.members(of: id)) ?? []
            let viewerID = try? await service.viewerProfileID()
            let profiles = await service.profiles(members.map(\.profileID))
            guard !Task.isCancelled, let self else { return }
            self.adoptGroup(Self.group(identity: identity, members: members, profiles: profiles, viewer: viewerID))
        }
    }

    /// The group as the screen draws it (#2214): its name — or its other
    /// members', for a nameless one — its photo, "N members", and every
    /// member the profiles named.
    static func group(
        identity: ConversationIdentity, members: [ConversationMember], profiles: [ProfileID: ChatProfile], viewer: ProfileID?
    ) -> ConversationThreadGroup {
        var people: [ProfileID: ConversationThreadPerson] = [:]
        for member in members {
            let profile = profiles[member.profileID]
            people[member.profileID] = ConversationThreadPerson(
                id: member.profileID, name: profile?.name ?? "", avatarURL: profile?.avatarURL, handle: profile?.handle
            )
        }
        let count = max(identity.memberCount, members.count)
        let others = members.filter { $0.profileID != viewer }.compactMap { profiles[$0.profileID]?.name }
        let name = identity.name.isEmpty
            ? ConversationIdentity.memberName(others, total: max(0, count - 1))
            : identity.name
        return ConversationThreadGroup(
            name: name, photoURL: identity.photoURL, subtitle: memberCountText(count), members: people
        )
    }

    /// Who a reply answers: in a group, the member who wrote the message
    /// (#2214) — the view model knows only the group's name.
    private func replyAuthor(_ draft: ConversationViewModel.ReplyDraft) -> String {
        guard let group, let sender = lastMessages?.first(where: { $0.id == draft.messageID }),
              !sender.isMine, let name = group.members[sender.senderID]?.name, !name.isEmpty else { return draft.author }
        return name
    }

    /// "1 member", "12 members" — the header's subtitle (#2214).
    static func memberCountText(_ count: Int) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }

    private func adoptGroup(_ group: ConversationThreadGroup) {
        self.group = group
        onGroupChange?(group)
        // Quotes of members' messages were signed with the group's name.
        if let lastMessages { forward(.content(lastMessages)) }
    }

    func didTapGroupInfo(from presenter: UIViewController) {
        guard let context = groupContext, group != nil, let id = viewModel.currentConversationID else { return }
        let info = context.makeInfo(id) { [weak self] in self?.loadGroup() }
        presenter.navigationController?.pushViewController(info, animated: true)
    }

    func didTapMember(_ profileID: ProfileID) {
        guard let context = groupContext, let member = group?.members[profileID] else { return didTapIdentity() }
        context.openProfile(profileID, member.name)
    }

    /// The system lines a group's thread opens with (#2214): "You created
    /// the group" for one the viewer created this session.
    private func systemLines() -> [ConversationThreadMessage] {
        guard let context = groupContext, let id = viewModel.currentConversationID,
              let created = context.createdAt(id) else { return [] }
        return [ConversationThreadMessage(
            id: Self.createdLineID, senderID: ProfileID(""), body: "You created the group", sentAt: created,
            isMine: false, quote: nil, isSystem: true
        )]
    }

    /// The id of the "You created the group" line.
    static let createdLineID = "system.created"

    /// `messages` with `lines` in place by time, oldest first — a line at
    /// the same time as a message goes before it.
    static func inserting(_ lines: [ConversationThreadMessage], into messages: [ConversationThreadMessage]) -> [ConversationThreadMessage] {
        var merged = messages
        for line in lines {
            let index = merged.firstIndex { $0.sentAt >= line.sentAt } ?? merged.endIndex
            merged.insert(line, at: index)
        }
        return merged
    }

    func togglePinned() {
        guard let pins, let id = viewModel.currentConversationID else { return }
        pins.togglePin(id)
    }

    /// This conversation's pin, or nil while there is no conversation (a
    /// draft) or no inbox to pin it in.
    private func forwardPinned() {
        let pinned = viewModel.currentConversationID.flatMap { id in pins.map { $0.isPinned(id) } }
        guard !hasForwardedPin || pinned != forwardedPin else { return }
        hasForwardedPin = true
        forwardedPin = pinned
        onPinnedChange?(pinned)
    }

    /// Mutes the conversation, or unmutes it (#719). A no-op while there is
    /// nothing to mute (`onMutedChange` said nil).
    /// Mutes until `until` (nil: until turned back on), or unmutes (#729).
    /// Answers once the server has (#802) — see the protocol.
    func setMuted(_ muted: Bool, until: Date?, completion: @escaping @MainActor (_ confirmed: Bool) -> Void) {
        guard let pins, let id = viewModel.currentConversationID else { return completion(false) }
        pins.setMute(id, muted: muted, until: until, completion: completion)
    }

    func toggleMuted() {
        guard let pins, let id = viewModel.currentConversationID else { return }
        pins.toggleMute(id)
    }

    /// This conversation's mute, or nil while there is no conversation.
    private func forwardMuted() {
        let muted = viewModel.currentConversationID.flatMap { id in pins.map { $0.isMuted(id) } }
        guard !hasForwardedMute || muted != forwardedMute else { return }
        hasForwardedMute = true
        forwardedMute = muted
        onMutedChange?(muted)
    }

    func refresh() { viewModel.refresh() }
    func loadOlder() { viewModel.loadOlder() }
    func send(_ text: String) { viewModel.send(text) }

    /// Voice messages (#2102): the conversation's composer records — the
    /// thread's own sends, the one place a take becomes a message (#2103).
    var sendsVoice: Bool { true }

    func send(voice take: ConversationThreadVoiceTake) {
        viewModel.send(voice: ChatVoiceUpload(fileURL: take.fileURL, duration: take.duration, waveform: take.waveform))
    }
    func beginReply(to messageID: String) { viewModel.beginReply(to: messageID) }
    func cancelReply() { viewModel.cancelReply() }
    func forward(_ messageID: String) { viewModel.perform(.forward, on: messageID) }
    func delete(_ messageID: String) { viewModel.deleteMessage(messageID) }
    func didTapIdentity() { viewModel.didTapIdentity() }
    func didTapIdentityPill() { viewModel.didTapIdentityPill() }
    func peerProfileDestination() -> UIViewController? { viewModel.peerProfileDestination() }

    // MARK: - Media (#681)

    var sendsMedia: Bool { mediaPicker != nil }

    func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController) {
        guard let mediaPicker, presenter.presentedViewController == nil else { return }
        weak var shown: UIViewController?
        let picker = mediaPicker(source) { [weak self, weak presenter] uploads in
            // The picker only, if it is still up (#1144): after a cancel or a
            // swipe-down, `dismiss` on the presenter would close the thread.
            if let picker = shown { presenter?.dismiss(presented: picker) }
            self?.viewModel.send(media: uploads)
        }
        shown = picker
        presenter.present(picker, animated: true)
    }

    func retry(_ messageID: String) { viewModel.retry(messageID) }

    // MARK: - Outputs

    private func forward(_ phase: ConversationViewModel.Phase) {
        switch phase {
        case .loading:
            onPhaseChange?(.loading)
        case .failed(let message):
            onPhaseChange?(.failed(message))
        case .content(let models):
            lastMessages = models
            let names = group?.members.compactMapValues { $0.name.isEmpty ? nil : $0.name } ?? [:]
            let messages = Self.messages(from: models, peerName: peer.name, names: names)
            onPhaseChange?(.content(Self.inserting(systemLines(), into: messages)))
        }
    }

    /// Oldest first, with each reply's quote resolved against the whole set —
    /// a reply can answer a message from any earlier day.
    ///
    /// `names`: a group's members (#2214) — a quote of one of theirs is
    /// signed with their name, not the group's.
    static func messages(
        from models: [MessageDisplayModel], peerName: String, names: [ProfileID: String] = [:]
    ) -> [ConversationThreadMessage] {
        let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return models.map { model in
            let quote = model.replyToID.flatMap { byID[$0] }.map { original in
                ConversationThreadMessage.Quote(
                    messageID: original.id,
                    author: ChatTranscript.quoteAuthor(
                        isMine: original.isMine, peerName: names[original.senderID] ?? peerName
                    ),
                    snippet: ChatTranscript.snippet(original.summary)
                )
            }
            return ConversationThreadMessage(
                id: model.id, senderID: model.senderID, body: model.body,
                sentAt: model.sentAt, isMine: model.isMine, quote: quote,
                media: model.media.map { media in
                    ConversationThreadMedia(
                        kind: Self.kind(media.kind), url: media.url,
                        posterURL: media.posterURL, preview: media.preview,
                        aspectRatio: media.aspectRatio, duration: media.duration,
                        waveform: media.waveform, assetID: media.assetID, localFileURL: media.localFileURL
                    )
                },
                delivery: Self.delivery(model.delivery)
            )
        }
    }

    private static func kind(_ kind: ChatMedia.Kind) -> ConversationThreadMedia.Kind {
        switch kind {
        case .image: .image
        case .video: .video
        case .voice: .voice
        }
    }

    private static func delivery(_ delivery: MessageDisplayModel.Delivery) -> ConversationThreadDelivery {
        switch delivery {
        case .sent: .sent
        case .sending: .sending
        case .failed: .failed
        }
    }

    private func adoptPeer(name: String) {
        peer = ConversationThreadPerson(id: peer.id, name: name, avatarURL: peer.avatarURL, handle: peer.handle)
        onPeerChange?(peer)
        // Quotes of the peer's messages were signed with a placeholder until now.
        if let lastMessages { forward(.content(lastMessages)) }
    }

    private func adoptPeer(id: ProfileID?) {
        guard id != peer.id else { return }
        peer = ConversationThreadPerson(id: id, name: peer.name, avatarURL: nil)
        onPeerChange?(peer)
        guard let id, let avatars else { return }
        // The face and the @handle (#752) come from the same profile read —
        // one after the other, so the second is the first's cache: together,
        // both missed it and the profile was read twice.
        Task { [weak self] in
            let url = await avatars.avatarURLs(for: [id])[id]
            let handle = await avatars.handles(for: [id])[id]
            guard let self, url != nil || handle != nil, self.peer.id == id else { return }
            self.peer = ConversationThreadPerson(id: id, name: self.peer.name, avatarURL: url, handle: handle)
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
