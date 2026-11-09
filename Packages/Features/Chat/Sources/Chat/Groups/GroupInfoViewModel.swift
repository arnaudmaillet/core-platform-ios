import CoreModels
import CoreNetworking
import Foundation

/// A group's info screen (#2214): its photo, name and description, its
/// members with their roles, and what the viewer may do — which their role
/// decides, here, in one place (`actions(by:on:)`, `canEdit`…), so the screen
/// only draws what it is told.
///
/// Every write goes through `ConversationManaging`, then the members are
/// read again: the server's answer is the list, never a local guess at it.
@MainActor
final class GroupInfoViewModel {
    /// What an owner or an admin may do to a member, from the member's menu.
    nonisolated enum MemberAction: Equatable, Sendable, CaseIterable {
        case makeAdmin
        case removeAdmin
        case transferOwnership
        case remove
        case ban

        /// The menu's words.
        var title: String {
            switch self {
            case .makeAdmin: "Make Admin"
            case .removeAdmin: "Remove as Admin"
            case .transferOwnership: "Make Owner"
            case .remove: "Remove from Group"
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
        /// What the viewer may do to them; empty: no menu.
        let actions: [MemberAction]

        /// "Owner", "Admin" — nil for a plain member.
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
        /// Its own name, empty for a group named by its members — what the
        /// rename field starts from.
        var ownName = ""
        var photoURL: URL?
        var description = ""
        var memberCount = 0
        var members: [MemberRow] = []
        var viewerRole: ConversationRole?
        var isMuted = false
        /// A write is on its way: the screen holds its controls.
        var isWorking = false

        /// Owner and admins edit the name, the photo and the description.
        var canEdit: Bool { viewerRole?.manages == true }
        /// Owner and admins add people.
        var canAddMembers: Bool { viewerRole?.manages == true }
        /// "12 members".
        var subtitle: String { memberCount == 1 ? "1 member" : "\(memberCount) members" }
    }

    var onStateChange: ((State) -> Void)?
    /// A notice to show: `(title, message)` — the owner's "transfer first".
    var onNotice: ((String, String) -> Void)?
    /// A write the server refused: the words.
    var onFailure: ((String) -> Void)?
    /// The viewer left: the screen goes back to the inbox.
    var onLeft: (() -> Void)?
    /// The group changed (a rename, a member gone): the thread behind reads
    /// it again.
    var onChange: (() -> Void)?

    private(set) var state = State() { didSet { if state != oldValue { onStateChange?(state) } } }

    let conversationID: ConversationID
    private let service: any GroupChatServicing
    /// The inbox's mute (#719), shared with the thread's bell and the row.
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

    /// What `viewer` (with `viewerRole`) may do to `member` (#2214):
    ///
    /// - the OWNER manages everyone: makes or unmakes admins, hands the
    ///   group over, removes, bans;
    /// - an ADMIN manages plain members: makes them admin, removes, bans —
    ///   never another admin, never the owner;
    /// - a MEMBER manages no one, and nobody manages themselves.
    nonisolated static func actions(
        by viewerRole: ConversationRole?, viewer: ProfileID?, on member: ConversationMember
    ) -> [MemberAction] {
        guard let viewerRole, viewerRole.manages, member.profileID != viewer, member.role != .owner else { return [] }
        let isAdmin = member.role == .admin
        switch viewerRole {
        case .owner:
            return [isAdmin ? .removeAdmin : .makeAdmin, .transferOwnership, .remove, .ban]
        case .admin:
            return isAdmin ? [] : [.makeAdmin, .remove, .ban]
        default:
            return []
        }
    }

    /// Why the viewer can't leave, if they can't: the owner hands the group
    /// over first (chat.v1 refuses an owner's `Leave`).
    nonisolated static func leaveBlockedReason(for role: ConversationRole?) -> String? {
        role == .owner
            ? "You own this group. Before you leave, make someone else the owner from their menu in Members."
            : nil
    }

    // MARK: - Reads

    func load() {
        let groupService = service
        let id = conversationID
        Task { [weak self] in
            do {
                async let identity = groupService.details(of: id)
                async let members = groupService.members(of: id)
                let viewer = try? await groupService.viewerProfileID()
                let (details, list) = try await (identity, members)
                let profiles = await groupService.profiles(list.map(\.profileID))
                self?.adopt(details, list, profiles: profiles, viewer: viewer)
            } catch {
                guard let self else { return }
                if self.state.phase != .loaded {
                    self.state.phase = .failed(FailureCopy.message(for: error, fallback: "Couldn't load this group."))
                }
            }
        }
    }

    private func adopt(
        _ identity: ConversationIdentity, _ list: [ConversationMember], profiles: [ProfileID: ChatProfile], viewer: ProfileID?
    ) {
        viewerID = viewer
        members = list
        var next = state
        next.phase = .loaded
        let viewerRole = list.first { $0.profileID == viewer }?.role ?? identity.viewerState.role
        next.viewerRole = viewerRole
        next.memberCount = max(identity.memberCount, list.count)
        next.ownName = identity.name
        let others = list.filter { $0.profileID != viewer }.compactMap { profiles[$0.profileID]?.name }
        next.name = identity.name.isEmpty
            ? ConversationIdentity.memberName(others, total: max(0, next.memberCount - 1))
            : identity.name
        next.photoURL = identity.photoURL
        next.description = identity.description
        next.members = Self.rows(list, profiles: profiles, viewer: viewer, viewerRole: viewerRole)
        next.isMuted = isMuted()
        state = next
    }

    /// The owner first, then admins, then members; by name within each, the
    /// viewer signed "You".
    nonisolated static func rows(
        _ list: [ConversationMember], profiles: [ProfileID: ChatProfile], viewer: ProfileID?, viewerRole: ConversationRole?
    ) -> [MemberRow] {
        list.map { member in
            let profile = profiles[member.profileID]
            let isViewer = member.profileID == viewer
            let named = profile.flatMap { $0.name.isEmpty ? $0.handle : $0.name } ?? "Member"
            let name = isViewer ? "You" : named
            return MemberRow(
                id: member.profileID, name: name, handle: profile?.handle, avatarURL: profile?.avatarURL,
                role: member.role, isViewer: isViewer,
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

    /// A member's menu: the action, written, then the members read again.
    func perform(_ action: MemberAction, on profileID: ProfileID) {
        guard let member = members.first(where: { $0.profileID == profileID }),
              Self.actions(by: state.viewerRole, viewer: viewerID, on: member).contains(action) else { return }
        let groupService = service
        let id = conversationID
        write(failure: Self.failureWords(for: action)) {
            switch action {
            case .makeAdmin: try await groupService.setRole(.admin, of: profileID, in: id)
            case .removeAdmin: try await groupService.setRole(.member, of: profileID, in: id)
            case .transferOwnership: try await groupService.transferOwnership(of: id, to: profileID)
            case .remove: try await groupService.remove(profileID, from: id, ban: false)
            case .ban: try await groupService.remove(profileID, from: id, ban: true)
            }
        }
    }

    nonisolated static func failureWords(for action: MemberAction) -> String {
        switch action {
        case .makeAdmin, .removeAdmin: "Couldn't change their role"
        case .transferOwnership: "Couldn't hand over the group"
        case .remove, .ban: "Couldn't remove them"
        }
    }

    /// The name and the description, from the edit sheet. Owner and admins
    /// only; the photo stays as it is (no picker yet, see
    /// `GroupCreationViewModel`).
    func editIdentity(name: String, description: String) {
        guard state.canEdit else { return }
        let groupService = service
        let id = conversationID
        let photo = state.photoURL
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        write(failure: "Couldn't save the changes") {
            try await groupService.editIdentity(of: id, name: trimmedName, photoURL: photo, description: trimmedDescription)
        }
    }

    /// People picked in the picker, invited (#2213: an invitation, which they
    /// accept from their inbox).
    func add(_ profileIDs: [ProfileID]) {
        guard state.canAddMembers, !profileIDs.isEmpty else { return }
        let groupService = service
        let id = conversationID
        write(failure: "Couldn't add them") {
            try await groupService.invite(profileIDs, to: id)
        }
    }

    /// Everyone in, the viewer included — what the picker excludes.
    var memberIDs: Set<ProfileID> { Set(members.map(\.profileID)).union(viewerID.map { [$0] } ?? []) }

    /// The inbox's mute, flipped at once and put back if refused.
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

    /// Leaves the group — or, for the owner, says why they can't yet.
    func leave() {
        if let reason = Self.leaveBlockedReason(for: state.viewerRole) {
            onNotice?("Make someone else the owner", reason)
            return
        }
        let groupService = service
        let id = conversationID
        state.isWorking = true
        Task { [weak self] in
            do {
                try await groupService.leave(id)
                self?.state.isWorking = false
                self?.onLeft?()
            } catch {
                self?.state.isWorking = false
                self?.onFailure?(FailureCopy.message(for: error, fallback: "Couldn't leave the group"))
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
