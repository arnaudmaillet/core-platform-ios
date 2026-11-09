import CoreModels
import CoreNetworking
import Foundation

/// A channel's info screen (#2215): its photo, name, description,
/// visibility and subscriber count; its admins; for owner and admins its
/// join requests and its subscribers; mute and leave. What the viewer may
/// do is decided here, in one place (`actions(by:viewer:on:)`, `canEdit`…) —
/// the screen draws what it is told.
///
/// Every write goes through `ConversationManaging`, then the channel is read
/// again: the server's answer is the screen, never a local guess at it.
///
/// ⚠️ The subscribers are `ListMembers`' subscribers — every one, which a
/// real audience outgrows; the backend's paging (#995) is what a big channel
/// will need here.
@MainActor
final class ChannelInfoViewModel {
    /// What an owner or an admin may do to someone in the channel.
    nonisolated enum MemberAction: Equatable, Sendable, CaseIterable {
        case makeAdmin
        case removeAdmin
        case transferOwnership
        case remove
        case ban

        var title: String {
            switch self {
            case .makeAdmin: "Make Admin"
            case .removeAdmin: "Remove as Admin"
            case .transferOwnership: "Make Owner"
            case .remove: "Remove from Channel"
            case .ban: "Remove and Ban"
            }
        }

        var isDestructive: Bool { self == .remove || self == .ban }
    }

    nonisolated struct MemberRow: Equatable, Sendable, Identifiable {
        let id: ProfileID
        /// "You" for the viewer.
        let name: String
        let handle: String?
        let avatarURL: URL?
        let role: ConversationRole
        let isViewer: Bool
        let actions: [MemberAction]

        var roleLabel: String? {
            switch role {
            case .owner: "Owner"
            case .admin: "Admin"
            default: nil
            }
        }
    }

    nonisolated enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    nonisolated struct State: Equatable, Sendable {
        var phase: Phase = .loading
        var name = ""
        var photoURL: URL?
        var description = ""
        var visibility: ConversationVisibility = .public
        var subscriberCount = 0
        var viewerState: ConversationViewerState = .none
        /// The owner, then the admins.
        var admins: [MemberRow] = []
        var subscribers: [MemberRow] = []
        /// Pending join requests, for owner and admins.
        var requestCount = 0
        var isMuted = false
        var isWorking = false

        var viewerRole: ConversationRole? { viewerState.role }
        /// Owner and admins edit the identity and the visibility, and see
        /// requests and subscribers.
        var canEdit: Bool { viewerState.runsChannel }
        /// The owner names and unnames admins.
        var canManageAdmins: Bool { viewerRole == .owner }
        /// Anyone in it mutes and leaves it.
        var isIn: Bool { viewerRole != nil }
        var subtitle: String { ChannelCopy.subscriberCount(subscriberCount) }
    }

    var onStateChange: ((State) -> Void)?
    /// A notice: `(title, message)` — the owner's "hand it over first".
    var onNotice: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// The viewer left: the host takes them back.
    var onLeft: (() -> Void)?
    /// The channel changed: the thread and the tab read it again.
    var onChange: (() -> Void)?

    private(set) var state = State() { didSet { if state != oldValue { onStateChange?(state) } } }

    let conversationID: ConversationID
    private let service: any GroupChatServicing
    private let isMuted: @MainActor () -> Bool
    private let setMuted: @MainActor (_ muted: Bool, _ completion: @escaping @MainActor (Bool) -> Void) -> Void
    private var viewerID: ProfileID?
    private var members: [ConversationMember] = []

    init(
        conversationID: ConversationID,
        service: any GroupChatServicing,
        isMuted: @escaping @MainActor () -> Bool = { false },
        setMuted: @escaping @MainActor (_ muted: Bool, _ completion: @escaping @MainActor (Bool) -> Void) -> Void = { _, done in
            done(false)
        }
    ) {
        self.conversationID = conversationID
        self.service = service
        self.isMuted = isMuted
        self.setMuted = setMuted
        state.isMuted = isMuted()
    }

    // MARK: - Roles

    /// What `viewerRole` may do to `member` in a channel (#2215):
    ///
    /// - the OWNER manages everyone: names or unnames admins, hands the
    ///   channel to an admin, removes, bans;
    /// - an ADMIN manages subscribers only: removes, bans — never another
    ///   admin, never the owner, and names no admin;
    /// - a subscriber manages no one, and nobody manages themselves.
    nonisolated static func actions(
        by viewerRole: ConversationRole?, viewer: ProfileID?, on member: ConversationMember
    ) -> [MemberAction] {
        guard let viewerRole, viewerRole.manages, member.profileID != viewer, member.role != .owner else { return [] }
        let isAdmin = member.role == .admin
        switch viewerRole {
        case .owner: return isAdmin ? [.removeAdmin, .transferOwnership, .remove, .ban] : [.makeAdmin, .remove, .ban]
        case .admin: return isAdmin ? [] : [.remove, .ban]
        default: return []
        }
    }

    // MARK: - Reads

    func load() {
        let channelService = service
        let id = conversationID
        Task { [weak self] in
            do {
                let identity = try await channelService.details(of: id)
                let viewer = try? await channelService.viewerProfileID()
                // A channel the viewer isn't in shows itself, not its people.
                let list = identity.viewerState.role == nil ? [] : (try? await channelService.members(of: id)) ?? []
                let requests = identity.viewerState.runsChannel
                    ? (try? await channelService.joinRequests(to: id).count) ?? 0 : 0
                let profiles = await channelService.profiles(list.map(\.profileID))
                self?.adopt(identity, list, requests: requests, profiles: profiles, viewer: viewer)
            } catch {
                guard let self, self.state.phase != .loaded else { return }
                self.state.phase = .failed(FailureCopy.message(for: error, fallback: "Couldn't load this channel."))
            }
        }
    }

    private func adopt(
        _ identity: ConversationIdentity, _ list: [ConversationMember], requests: Int,
        profiles: [ProfileID: ChatProfile], viewer: ProfileID?
    ) {
        viewerID = viewer
        members = list
        var next = state
        next.phase = .loaded
        next.name = identity.name
        next.photoURL = identity.photoURL
        next.description = identity.description
        next.visibility = identity.visibility
        next.subscriberCount = identity.subscriberCount
        next.viewerState = identity.viewerState
        next.requestCount = requests
        let rows = Self.rows(list, profiles: profiles, viewer: viewer, viewerRole: identity.viewerState.role)
        next.admins = rows.filter { $0.role == .owner || $0.role == .admin }
        // Subscribers are the managers' to see.
        next.subscribers = identity.viewerState.runsChannel ? rows.filter { $0.role != .owner && $0.role != .admin } : []
        next.isMuted = isMuted()
        state = next
    }

    /// The owner first, then admins, then subscribers; by name within each,
    /// the viewer signed "You".
    nonisolated static func rows(
        _ list: [ConversationMember], profiles: [ProfileID: ChatProfile], viewer: ProfileID?, viewerRole: ConversationRole?
    ) -> [MemberRow] {
        list.map { member in
            let profile = profiles[member.profileID]
            let isViewer = member.profileID == viewer
            let named = profile.flatMap { $0.name.isEmpty ? $0.handle : $0.name } ?? "Subscriber"
            return MemberRow(
                id: member.profileID, name: isViewer ? "You" : named, handle: profile?.handle,
                avatarURL: profile?.avatarURL, role: member.role, isViewer: isViewer,
                actions: actions(by: viewerRole, viewer: viewer, on: member)
            )
        }
        .sorted { lhs, rhs in
            if lhs.role != rhs.role { return lhs.role < rhs.role }
            if lhs.isViewer != rhs.isViewer { return lhs.isViewer }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Writes

    func perform(_ action: MemberAction, on profileID: ProfileID) {
        guard let member = members.first(where: { $0.profileID == profileID }),
              Self.actions(by: state.viewerRole, viewer: viewerID, on: member).contains(action) else { return }
        let channelService = service
        let id = conversationID
        write(failure: Self.failureWords(for: action)) {
            switch action {
            case .makeAdmin: try await channelService.setRole(.admin, of: profileID, in: id)
            case .removeAdmin: try await channelService.setRole(.subscriber, of: profileID, in: id)
            case .transferOwnership: try await channelService.transferOwnership(of: id, to: profileID)
            case .remove: try await channelService.remove(profileID, from: id, ban: false)
            case .ban: try await channelService.remove(profileID, from: id, ban: true)
            }
        }
    }

    nonisolated static func failureWords(for action: MemberAction) -> String {
        switch action {
        case .makeAdmin, .removeAdmin: "Couldn't change their role"
        case .transferOwnership: "Couldn't hand over the channel"
        case .remove, .ban: "Couldn't remove them"
        }
    }

    /// The name and the description, from the edit sheet. A channel keeps
    /// a name: an empty one changes nothing.
    func editIdentity(name: String, description: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.canEdit, !trimmedName.isEmpty else { return }
        let channelService = service
        let id = conversationID
        let photo = state.photoURL
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        write(failure: "Couldn't save the changes") {
            try await channelService.editIdentity(of: id, name: trimmedName, photoURL: photo, description: trimmedDescription)
        }
    }

    /// Public or On request (#2215), owner and admins.
    func setVisibility(_ visibility: ConversationVisibility) {
        guard state.canEdit, visibility != state.visibility, ChannelCopy.choosableVisibilities.contains(visibility) else { return }
        let channelService = service
        let id = conversationID
        write(failure: "Couldn't change who can join") {
            try await channelService.setVisibility(visibility, of: id)
        }
    }

    /// The join requests were answered elsewhere (the requests list): read
    /// again.
    func requestsChanged() {
        onChange?()
        load()
    }

    func toggleMute() {
        let muting = !state.isMuted
        state.isMuted = muting
        setMuted(muting) { [weak self] confirmed in
            guard let self else { return }
            self.state.isMuted = self.isMuted()
            if !confirmed {
                self.onFailure?(ConversationListViewModel.muteAnswer(muting: muting, confirmed: false))
            }
        }
    }

    /// Leaves the channel — a subscriber unsubscribes, an admin leaves — or,
    /// for the owner, says why they can't yet.
    func leave() {
        if let reason = ChannelCopy.leaveBlockedReason(for: state.viewerRole) {
            onNotice?("Make someone else the owner", reason)
            return
        }
        let channelService = service
        let id = conversationID
        let unsubscribes = state.viewerState == .subscriber
        state.isWorking = true
        Task { [weak self] in
            do {
                if unsubscribes { try await channelService.unsubscribe(from: id) } else { try await channelService.leave(id) }
                self?.state.isWorking = false
                self?.onLeft?()
            } catch {
                self?.state.isWorking = false
                self?.onFailure?(FailureCopy.message(for: error, fallback: "Couldn't leave the channel"))
            }
        }
    }

    private func write(failure: String, _ body: @escaping @Sendable () async throws -> Void) {
        state.isWorking = true
        Task { [weak self] in
            do {
                try await body()
                guard let self else { return }
                self.state.isWorking = false
                self.onChange?()
                self.load()
            } catch {
                guard let self else { return }
                self.state.isWorking = false
                self.onFailure?(FailureCopy.message(for: error, fallback: failure))
            }
        }
    }
}
