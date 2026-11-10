import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import UIKit
import CoreNavigation
import CoreNetworking

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
    /// The kinds drawn as such (#2215): groups with `-group-chats`, channels
    /// with `-channels`. A kind not here is drawn as it was.
    var kinds: Set<ConversationKind> = [.group]
    /// What the inbox's row knows of a channel (#2215) — its name, photo
    /// and the viewer's place — so its thread is drawn as one from the
    /// push's first frame: a subscriber never sees the composer come and go.
    var knownIdentity: @MainActor (_ id: ConversationID) -> ConversationIdentity? = { _ in nil }
    /// What the inbox's row draws of a group (#2233) — its title and its
    /// faces — so the thread's pill shows the group's picture from the
    /// push's first frame, never the initials of a name made of its members.
    var knownGroupRow: @MainActor (_ id: ConversationID) -> (title: String, faces: [GroupAvatarFace])? = { _ in nil }
    /// A channel's info screen (#2215), as `makeInfo` is a group's.
    var makeChannelInfo: (@MainActor (_ id: ConversationID, _ onChange: @escaping @MainActor () -> Void) -> UIViewController)?
    /// The viewer joined (`left` false) or left a channel from its thread
    /// (#2215): the inbox reads its rows again.
    var onMembershipChange: @MainActor (_ id: ConversationID, _ left: Bool) -> Void = { _, _ in }
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
    /// A channel's identity as last read (#2215): what Join and Leave act on.
    private(set) var channelIdentity: ConversationIdentity?
    /// A group's identity as last read (#2217): where the viewer stands —
    /// member, follower, outsider — and what the audience watch compares.
    private(set) var groupIdentity: ConversationIdentity?
    /// When a public group closed to the viewer reading it from outside
    /// (#2217): its thread keeps what it showed, ends on "This group is
    /// private now", and offers nothing more.
    private(set) var closedAt: Date?
    private var audienceWatch: Task<Void, Never>?
    /// How often a public group's reader checks it is still public (#2217).
    var audienceWatchInterval: Duration = .seconds(5)

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
        if let known, known == .direct || !context.kinds.contains(known) { return }
        // A channel the inbox listed: drawn as one at once (#2215), read
        // again below.
        if known == .channel, group == nil, let identity = context.knownIdentity(id), identity.kind == .channel {
            adoptChannel(identity)
        }
        // A group the viewer follows, from its inbox row (#2217): its bar
        // from the push's first frame — never the composer coming and going.
        // Any group the inbox listed: its picture from the row's (#2233),
        // the pill never a person's face meanwhile.
        if known == .group, group == nil, let identity = context.knownIdentity(id), identity.kind == .group {
            let isReader = Self.groupReaderStanding(for: identity) != nil
            if let row = context.knownGroupRow(id) {
                if isReader { groupIdentity = identity }
                adoptGroup(Self.group(identity: identity, rowTitle: row.title, faces: row.faces))
            } else if isReader {
                groupIdentity = identity
                adoptGroup(Self.group(identity: identity, members: [], profiles: [:], viewer: nil))
            }
        }
        groupLoad?.cancel()
        let service = context.service
        let kinds = context.kinds
        groupLoad = Task { [weak self] in
            let identity: ConversationIdentity
            do {
                identity = try await service.details(of: id)
            } catch {
                guard !Task.isCancelled, let self else { return }
                // A public group read from outside that now answers "not
                // found" has turned private (#2217).
                if Self.isNotFound(error) { self.closeToReader() } else if let shown = self.group { self.adoptGroup(shown) }
                return
            }
            guard kinds.contains(identity.kind) else { return }
            // A channel's posts are its own: no members to sign them (#2215).
            if identity.kind == .channel {
                guard !Task.isCancelled else { return }
                self?.adoptChannel(identity)
                return
            }
            let members = (try? await service.members(of: id)) ?? []
            let viewerID = try? await service.viewerProfileID()
            let profiles = await service.profiles(members.map(\.profileID))
            guard !Task.isCancelled, let self, self.closedAt == nil else { return }
            self.groupIdentity = identity
            self.adoptGroup(Self.group(identity: identity, members: members, profiles: profiles, viewer: viewerID))
            self.watchAudience()
        }
    }

    /// The group as the screen draws it (#2214): its name — or its other
    /// members', for a nameless one — its photo, "N members", and every
    /// member the profiles named; and its faces for the header pill (#2233),
    /// in the inbox row's order (`ConversationMember.groupFaces`).
    ///
    /// A public group's header counts its followers apart, "40 members ·
    /// 2.3K followers", and a viewer who isn't a member gets the reader bar
    /// (#2217). Followers are never members: not listed, not counted, no
    /// presence of theirs drawn.
    static func group(
        identity: ConversationIdentity, members: [ConversationMember], profiles: [ProfileID: ChatProfile], viewer: ProfileID?
    ) -> ConversationThreadGroup {
        let talkers = members.filter(\.role.talks)
        var people: [ProfileID: ConversationThreadPerson] = [:]
        for member in talkers {
            let profile = profiles[member.profileID]
            people[member.profileID] = ConversationThreadPerson(
                id: member.profileID, name: profile?.name ?? "", avatarURL: profile?.avatarURL, handle: profile?.handle
            )
        }
        let count = max(identity.memberCount, talkers.count)
        let others = talkers.filter { $0.profileID != viewer }.compactMap { profiles[$0.profileID]?.name }
        let name = identity.name.isEmpty
            ? ConversationIdentity.memberName(others, total: max(0, count - 1))
            : identity.name
        let faces = ConversationMember.groupFaces(members, viewer: viewer) { id in
            let profile = profiles[id]
            let displayName = profile?.name ?? ""
            return (name: displayName.isEmpty ? profile?.handle ?? "" : displayName, avatarURL: profile?.avatarURL)
        }
        return ConversationThreadGroup(
            name: name, photoURL: identity.photoURL,
            subtitle: GroupCopy.header(memberCount: count, followerCount: identity.subscriberCount, visibility: identity.visibility),
            members: people, readerStanding: groupReaderStanding(for: identity),
            faces: faces, memberCount: count
        )
    }

    /// A group as its inbox row knows it (#2233), while its details are on
    /// their way: the row's title and faces, its photo and its counts — no
    /// members yet to sign the rows.
    static func group(identity: ConversationIdentity, rowTitle: String, faces: [GroupAvatarFace]) -> ConversationThreadGroup {
        ConversationThreadGroup(
            name: identity.name.isEmpty ? rowTitle : identity.name, photoURL: identity.photoURL,
            subtitle: GroupCopy.header(
                memberCount: identity.memberCount, followerCount: identity.subscriberCount, visibility: identity.visibility
            ),
            members: [:], readerStanding: groupReaderStanding(for: identity),
            faces: faces, memberCount: identity.memberCount
        )
    }

    // MARK: - Public groups (#2217)

    /// Who gets a group's composer, and what the others are offered
    /// (#2217): members write (nil); a follower reads, with Join while the
    /// group has room and Following; an outsider of a public group joins or
    /// follows; a private group answers an outsider as a missing one, so
    /// one seen here has closed to them.
    static func groupReaderStanding(for identity: ConversationIdentity) -> ConversationThreadReaderStanding? {
        switch identity.viewerState {
        // An invitation is answered from the inbox (#2214): the thread as it was.
        case .owner, .admin, .member, .invited: return nil
        case .subscriber: return .following(isFull: identity.isFull)
        case .requested: return .requested
        case .banned: return .unavailable
        case .none:
            switch identity.visibility {
            case .public: return .canJoinOrFollow(isFull: identity.isFull)
            case .listedOnRequest: return .canRequest
            case .private: return .closed
            }
        }
    }

    /// Whether the viewer reads this group from its audience (#2217): an
    /// outsider or a follower of a public group — whose reading ends the
    /// moment it turns private.
    static func readsFromAudience(_ identity: ConversationIdentity) -> Bool {
        identity.kind == .group && identity.visibility == .public
            && (identity.viewerState == .subscriber || identity.viewerState == .none)
    }

    /// The server's "no such conversation" — what a private group answers
    /// an outsider, a former follower included.
    static func isNotFound(_ error: Error) -> Bool {
        if case ChatError.refused(let message) = error { return message.contains("CHT-1004") }
        return false
    }

    /// A full group's refusal of a join (CHT-1020).
    static func isFullRefusal(_ error: Error) -> Bool {
        if case ChatError.refused(let message) = error { return message.contains("CHT-1020") }
        return false
    }

    /// Stands in for the audience's stream while chat.v1's live delivery
    /// isn't wired (#2217): the server closes `StreamPublic` when a group
    /// turns private (`chat.conversation.unpublished`); until the app holds
    /// that stream, a reader of a public group asks every few seconds
    /// whether it still is — and only such a reader, only while its thread
    /// lives.
    private func watchAudience() {
        guard closedAt == nil, let identity = groupIdentity, Self.readsFromAudience(identity) else {
            audienceWatch?.cancel()
            audienceWatch = nil
            return
        }
        guard audienceWatch == nil, let context = groupContext, let id = viewModel.currentConversationID else { return }
        let service = context.service
        let interval = audienceWatchInterval
        audienceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                do {
                    let fresh = try await service.details(of: id)
                    guard let self, !Task.isCancelled else { return }
                    // Its counts or the viewer's place moved: read it again.
                    if fresh != self.groupIdentity { self.loadGroup() }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    if Self.isNotFound(error) {
                        self.closeToReader()
                        return
                    }
                }
            }
        }
    }

    /// The group turned private under a reader from its audience (#2217):
    /// the thread keeps what it showed and ends on "This group is private
    /// now"; the bar goes, and a follower's inbox drops the group at once.
    func closeToReader() {
        guard closedAt == nil, let identity = groupIdentity, Self.readsFromAudience(identity), let shown = group,
              let id = viewModel.currentConversationID else { return }
        closedAt = Date()
        audienceWatch?.cancel()
        audienceWatch = nil
        groupLoad?.cancel()
        adoptGroup(ConversationThreadGroup(
            name: shown.name, photoURL: shown.photoURL, subtitle: shown.subtitle, members: shown.members,
            readerStanding: .closed, faces: shown.faces, memberCount: shown.memberCount
        ))
        if identity.viewerState == .subscriber { groupContext?.onMembershipChange(id, true) }
    }

    /// Follow (#2217): subscribed, the group reads along in the viewer's
    /// inbox, muted — chat.v1 has no muted subscription, so the app writes
    /// the mute, and only then has the inbox read its rows again.
    func follow() {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return }
        let service = context.service
        Task { [weak self] in
            do {
                try await service.subscribe(to: id)
                guard let self else { return }
                self.setMuted(true, until: nil) { _ in context.onMembershipChange(id, false) }
                self.loadGroup()
            } catch {
                self?.channelWriteFailed(error, title: "Couldn't follow")
            }
        }
    }

    /// Unfollow, confirmed (#2217): the group leaves the inbox; the thread
    /// stays, read as anyone reads a public group.
    func unfollow() {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return }
        let service = context.service
        Task { [weak self] in
            do {
                try await service.unsubscribe(from: id)
                context.onMembershipChange(id, true)
                self?.loadGroup()
            } catch {
                self?.channelWriteFailed(error, title: "Couldn't unfollow")
            }
        }
    }

    /// The details again after a join or a withdrawal: a group's with its
    /// members (#2217), a channel's alone (#2215).
    private func reloadAfterWrite(_ failure: String) {
        if let group, !group.isChannel { loadGroup() } else { reloadChannel(after: failure) }
    }

    // MARK: - Channels (#2215)

    /// A channel as the screen draws it (#2215): its name, photo and
    /// subscriber count in the header, every post signed by it, and — for a
    /// viewer who doesn't post — where they stand.
    static func channel(identity: ConversationIdentity) -> ConversationThreadGroup {
        ConversationThreadGroup(
            name: identity.name.isEmpty ? "Channel" : identity.name, photoURL: identity.photoURL,
            subtitle: ChannelCopy.subscriberCount(identity.subscriberCount), members: [:],
            isChannel: true, readerStanding: readerStanding(for: identity)
        )
    }

    /// Who gets the composer, and what the others are offered (#2215):
    /// owner and admins post (nil); a subscriber reads, leaving from the ⋯
    /// menu (#2236); an outsider joins a public channel or asks to join one
    /// on request; a pending request waits; a banned viewer is told.
    static func readerStanding(for identity: ConversationIdentity) -> ConversationThreadReaderStanding? {
        if identity.viewerState.publishesInChannel { return nil }
        switch identity.viewerState {
        case .owner, .admin, .member, .subscriber: return .subscribed
        case .requested: return .requested
        case .banned: return .unavailable
        case .none, .invited:
            switch identity.visibility {
            case .public: return .canJoin
            case .listedOnRequest: return .canRequest
            case .private: return .unavailable
            }
        }
    }

    private func adoptChannel(_ identity: ConversationIdentity) {
        channelIdentity = identity
        adoptGroup(Self.channel(identity: identity))
    }

    /// Join or Request to Join (#2215): a public channel subscribes at
    /// once, one on request waits — the details read again say which. A
    /// refusal is said, and the bar comes back as it was.
    ///
    /// A channel the viewer subscribes to joins MUTED (#2230, WhatsApp's
    /// rule): its posts reach Chats without a push until they turn
    /// notifications on, from the row's menu or the info screen. chat.v1
    /// has no muted subscription, so the app writes the mute, as Follow
    /// does (#2217), and only then has the inbox read its rows again.
    func join() {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return }
        let service = context.service
        Task { [weak self] in
            do {
                let standing = try await service.requestToJoin(id)
                guard let self else { return }
                if self.channelIdentity != nil, standing == .subscriber {
                    self.setMuted(true, until: nil) { _ in context.onMembershipChange(id, false) }
                } else {
                    context.onMembershipChange(id, false)
                }
                self.reloadAfterWrite("Couldn't join")
            } catch {
                self?.channelWriteFailed(error, title: "Couldn't join")
            }
        }
    }

    /// Withdraws the viewer's request (#2215).
    func cancelJoinRequest() {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return }
        let service = context.service
        Task { [weak self] in
            do {
                try await service.cancelJoinRequest(id)
                self?.reloadAfterWrite("Couldn't withdraw the request")
            } catch {
                self?.channelWriteFailed(error, title: "Couldn't withdraw the request")
            }
        }
    }

    /// Leaves the channel (#2215): a subscriber unsubscribes, an admin
    /// leaves; the owner hands it over first (chat.v1 refuses their Leave).
    /// Left, the inbox drops its row.
    ///
    /// ⚠️ THE THREAD STAYS WHILE THE CHANNEL IS STILL READABLE (#2236): Leave
    /// is the ⋯ menu's now, and the reader bar comes back with the way in
    /// (Join, Request to Join), as Unfollow leaves a public group on screen
    /// (#2217). A private channel can't be read from outside: its thread
    /// closes, as every Leave did before.
    func leave(from presenter: UIViewController) {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return }
        if let reason = ChannelCopy.leaveBlockedReason(for: channelIdentity?.viewerState.role) {
            onActionNotice?("Make someone else the owner", reason)
            return
        }
        let service = context.service
        let unsubscribes = channelIdentity?.viewerState == .subscriber
        Task { [weak self, weak presenter] in
            do {
                if unsubscribes { try await service.unsubscribe(from: id) } else { try await service.leave(id) }
                context.onMembershipChange(id, true)
                let after: ConversationIdentity? = try? await service.details(of: id)
                if let after, after.visibility != .private {
                    self?.adoptChannel(after)
                    return
                }
                // Nothing left to read: the thread closes — through the
                // stack's arbiter, as every close does.
                guard let presenter, presenter.navigationController?.topViewController === presenter else { return }
                _ = presenter.closeScreen()
            } catch {
                self?.channelWriteFailed(error, title: "Couldn't leave")
            }
        }
    }

    /// The details again after a write; the bar shows the answer.
    private func reloadChannel(after failure: String) {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return }
        let service = context.service
        Task { [weak self] in
            do {
                let identity = try await service.details(of: id)
                self?.adoptChannel(identity)
            } catch {
                self?.channelWriteFailed(error, title: failure)
            }
        }
    }

    private func channelWriteFailed(_ error: Error, title: String) {
        // A group filled up under the viewer (#2217): said, and the bar read
        // again — Follow only now.
        if Self.isFullRefusal(error) {
            onActionNotice?(title, "This group is full.")
            loadGroup()
            return
        }
        onActionNotice?(title, FailureCopy.message(for: error, fallback: "Try again in a moment."))
        // The bar as it was, no longer working: the channel, or the group.
        if let channelIdentity { adoptChannel(channelIdentity) } else if let group { adoptGroup(group) }
    }

    /// Who a reply answers: in a group, the member who wrote the message
    /// (#2214) — the view model knows only the group's name.
    private func replyAuthor(_ draft: ConversationViewModel.ReplyDraft) -> String {
        guard let group, let sender = lastMessages?.first(where: { $0.id == draft.messageID }),
              !sender.isMine, let name = group.members[sender.senderID]?.name, !name.isEmpty else { return draft.author }
        return name
    }

    /// "1 member", "12 members" — the header's subtitle (#2214).
    static func memberCountText(_ count: Int) -> String { GroupCopy.memberCount(count) }

    private func adoptGroup(_ group: ConversationThreadGroup) {
        self.group = group
        onGroupChange?(group)
        // Quotes of members' messages were signed with the group's name.
        if let lastMessages { forward(.content(lastMessages)) }
    }

    func didTapGroupInfo(from presenter: UIViewController) {
        guard let context = groupContext, let shown = group, let id = viewModel.currentConversationID else { return }
        let onChange: @MainActor () -> Void = { [weak self] in self?.loadGroup() }
        let info = shown.isChannel
            ? context.makeChannelInfo?(id, onChange) ?? context.makeInfo(id, onChange)
            : context.makeInfo(id, onChange)
        presenter.navigationController?.pushViewController(info, animated: true)
    }

    func didTapMember(_ profileID: ProfileID) {
        guard let context = groupContext, let member = group?.members[profileID] else { return didTapIdentity() }
        context.openProfile(profileID, member.name)
    }

    /// The system lines a group's thread opens with (#2214): "You created
    /// the group" for one the viewer created this session.
    private func systemLines() -> [ConversationThreadMessage] {
        guard let context = groupContext, let id = viewModel.currentConversationID else { return [] }
        var lines: [ConversationThreadMessage] = []
        if let created = context.createdAt(id) {
            lines.append(ConversationThreadMessage(
                id: Self.createdLineID, senderID: ProfileID(""),
                body: group?.isChannel == true ? "You created the channel" : "You created the group", sentAt: created,
                isMine: false, quote: nil, isSystem: true
            ))
        }
        // A public group turned private under its reader (#2217).
        if let closedAt {
            lines.append(ConversationThreadMessage(
                id: Self.privateNowLineID, senderID: ProfileID(""), body: GroupCopy.privateNow, sentAt: closedAt,
                isMine: false, quote: nil, isSystem: true
            ))
        }
        return lines
    }

    /// The id of the "You created the group" line.
    static let createdLineID = "system.created"
    /// The id of the "This group is private now" line (#2217).
    static let privateNowLineID = "system.private-now"

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
            // A group closed to its reader (#2217) answers every read "not
            // found": what it showed stays, under its last line.
            if closedAt != nil, let lastMessages { return forward(.content(lastMessages)) }
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
