import CoreModels
import CoreNavigation
import CoreNetworking
import DesignSystem
import Foundation
import HeroPage
import MediaCore

/// A group's info screen (#2214, #2237): its identity, its counters, what
/// the viewer may do — which their role decides, here, in one place
/// (`actions(by:viewer:on:)`, `canEdit`…), so the screen only draws what it
/// is told: the header (`header(for:id:)`), the "⋯" (`menu(for:)`), the
/// lists behind the counters (`listTabs(for:)`, `page(of:after:)`).
///
/// The people are read page by page (#2237, #995's paged `ListMembers`):
/// the screen holds no person rows, only the owner and the admins it names.
///
/// Every write goes through `ConversationManaging`, then the group is read
/// again: the server's answer is the screen, never a local guess at it.
@MainActor
final class GroupInfoViewModel {
    /// What an owner or an admin may do to a member, from the member's menu.
    nonisolated enum MemberAction: String, Equatable, Sendable, CaseIterable {
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

        /// The row the lists draw (#2237): the role and the @handle under
        /// the name, the menu's entries.
        var listRow: PersonListRow {
            PersonListRow(
                id: id.rawValue, name: name,
                detail: [roleLabel, handle.map { "@\($0)" }].compactMap(\.self).joined(separator: " · "),
                avatarURL: avatarURL, monogram: MonogramAvatarView.monogram(name: name, handle: handle ?? ""),
                actions: actions.map { PersonListRowAction(id: $0.rawValue, title: $0.title, isDestructive: $0.isDestructive) },
                opens: !isViewer
            )
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
        /// The header's picture (#2233): the photo, else the other members'
        /// faces, else the initials — the inbox row's and the pill's.
        var groupAvatar = GroupAvatarContent(name: "")
        var description = ""
        var memberCount = 0
        /// A public group's audience (#2217), counted apart from its members.
        var followerCount = 0
        /// The owner and the admins: the Admins counter (#2237).
        var adminCount = 0
        /// Join requests waiting, for owner and admins.
        var requestCount = 0
        var visibility: ConversationVisibility = .private
        /// No room left (#2217): an outsider is offered Follow only.
        var isFull = false
        /// The owner first, then the admins.
        var admins: [MemberRow] = []
        var viewerRole: ConversationRole?
        var isMuted = false
        /// A write is on its way: the screen holds its controls.
        var isWorking = false

        /// Owner and admins edit the name, the photo and the description.
        var canEdit: Bool { viewerRole?.manages == true }
        /// Owner and admins add people.
        var canAddMembers: Bool { viewerRole?.manages == true }
        /// Owner and admins switch Public / Private (#2217).
        var canChangeVisibility: Bool { viewerRole?.manages == true }
        /// A member who talks — the one who can leave (#2217): a follower
        /// unfollows, an outsider has nothing to leave.
        var isMember: Bool { viewerRole?.talks == true }
        /// The viewer follows this public group (#2217).
        var isFollower: Bool { viewerRole == .subscriber }
        /// Neither a member nor a follower.
        var isOutsider: Bool { viewerRole == nil }
        /// Whether the viewer may read who is in it: anyone who sees a
        /// public group, members of a private one.
        var readsPeople: Bool { visibility == .public || isMember }
        /// "12 members"; a public group's "40 members · 2.3K followers" (#2217).
        var subtitle: String { GroupCopy.header(memberCount: memberCount, followerCount: followerCount, visibility: visibility) }
        /// The members' count alone, never the audience.
        var memberCountText: String { GroupCopy.memberCount(memberCount) }
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
    /// A write changed who is in which list: the lists read again (#2237).
    var onPeopleChange: (() -> Void)?

    private(set) var state = State() { didSet { if state != oldValue { onStateChange?(state) } } }

    let conversationID: ConversationID
    private let service: any GroupChatServicing
    /// The inbox's mute (#719), shared with the thread's bell and the row.
    private let isMuted: @MainActor () -> Bool
    private let setMuted: @MainActor (_ muted: Bool, _ until: Date?, _ completion: @escaping @MainActor (Bool) -> Void) -> Void
    private var viewerID: ProfileID?
    /// Everyone read so far, by any list: whom a row's menu acts on.
    private var known: [ProfileID: ConversationMember] = [:]
    /// The lists' page size.
    static let pageSize = 30

    init(
        conversationID: ConversationID,
        service: any GroupChatServicing,
        isMuted: @escaping @MainActor () -> Bool = { false },
        setMuted: @escaping @MainActor (_ muted: Bool, _ until: Date?, _ completion: @escaping @MainActor (Bool) -> Void) -> Void = {
            _, _, done in done(false)
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
    /// - a FOLLOWER (#2217, listed since #2237) is removed or banned by
    ///   either, never made admin nor owner: they are not members;
    /// - a MEMBER manages no one, and nobody manages themselves.
    nonisolated static func actions(
        by viewerRole: ConversationRole?, viewer: ProfileID?, on member: ConversationMember
    ) -> [MemberAction] {
        guard let viewerRole, viewerRole.manages, member.profileID != viewer, member.role != .owner else { return [] }
        if !member.role.talks { return [.remove, .ban] }
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

    // MARK: - What the screen shows (#2237)

    /// The header for `state`: the profile's and the place's, drawing a
    /// group.
    nonisolated static func header(for state: State, id: ConversationID) -> ConversationInfoHeader {
        let link = state.visibility == .public ? AppRoute.conversationLink(id) : nil
        var counters: [ConversationInfoList: Int] = [.members: state.memberCount, .admins: state.adminCount]
        if state.canEdit, state.requestCount > 0 { counters[.requests] = state.requestCount }
        if state.visibility == .public { counters[.followers] = state.followerCount }
        var openable: Set<ConversationInfoList> = []
        if state.readsPeople { openable.formUnion([.members, .admins]) }
        if state.canEdit {
            openable.insert(.requests)
            if state.visibility == .public { openable.insert(.followers) }
        }
        let capsules: [ConversationInfoAction]
        if state.canEdit {
            capsules = [.edit, .addMembers]
        } else if state.isOutsider, state.visibility == .public {
            capsules = state.isFull ? [.follow] : [.join, .follow]
        } else if state.isFollower, !state.isFull {
            capsules = [.join]
        } else {
            capsules = []
        }
        return ConversationInfoHeader(
            title: state.name,
            subtitle: state.visibility == .public ? "Public group" : "Private group",
            bio: state.description.isEmpty ? nil : state.description,
            linkText: ConversationInfoHeader.linkText(link), linkURL: link,
            photoURL: state.photoURL, monogram: MonogramAvatarView.monogram(name: state.name, handle: ""),
            counters: counters, openable: openable, capsules: capsules,
            bubbles: link == nil ? [] : [.share],
            groupAvatar: state.groupAvatar
        )
    }

    /// The bar's "⋯" for `state`, Leave last; never Leave for the owner, who
    /// hands the group over first.
    nonisolated static func menu(for state: State) -> [ConversationInfoMenuEntry] {
        var entries: [ConversationInfoMenuEntry] = []
        if state.canChangeVisibility { entries.append(.visibility) }
        if state.viewerRole == .owner { entries.append(.transferOwnership) }
        if state.isFollower { entries.append(.unfollow) }
        if state.isMember, state.viewerRole != .owner { entries.append(.leave) }
        return entries
    }

    /// The lists behind the counters, for who may read them: Members and
    /// Admins; Requests for owner and admins, and a public group's Followers.
    nonisolated static func listTabs(for state: State) -> [PersonListTab] {
        var lists: [ConversationInfoList] = state.readsPeople ? [.members, .admins] : []
        if state.canEdit {
            lists.append(.requests)
            if state.visibility == .public { lists.append(.followers) }
        }
        return lists.map { list in
            let count: Int = switch list {
            case .members: state.memberCount
            case .admins: state.adminCount
            case .requests: state.requestCount
            case .followers, .subscribers: state.followerCount
            }
            let lead: PersonListTab.LeadingAction? = list == .members && state.canAddMembers
                ? PersonListTab.LeadingAction(title: "Add Members", symbol: "person.badge.plus") : nil
            return PersonListTab(id: list.rawValue, title: list.tabTitle(count: count), empty: list.empty(channel: false), leadingAction: lead)
        }
    }

    var header: ConversationInfoHeader { Self.header(for: state, id: conversationID) }

    // MARK: - Reads

    func load() {
        let groupService = service
        let id = conversationID
        Task { [weak self] in
            do {
                let identity = try await groupService.details(of: id)
                let viewer = try? await groupService.viewerProfileID()
                let reads = identity.visibility == .public || identity.viewerState.role?.talks == true
                // The admins name the Admins counter; a nameless group is
                // named by its first members.
                var admins: ConversationMemberPage?
                var firsts: ConversationMemberPage?
                if reads {
                    admins = try? await groupService.members(of: id, roles: [.owner, .admin], after: nil, limit: 50)
                    if identity.name.isEmpty {
                        firsts = try? await groupService.members(of: id, roles: [.owner, .admin, .member], after: nil, limit: 6)
                    }
                }
                var requests = 0
                if identity.viewerState.role?.manages == true {
                    requests = (try? await groupService.joinRequests(to: id).count) ?? 0
                }
                let people: [ConversationMember] = (admins?.members ?? []) + (firsts?.members ?? [])
                let profiles = await groupService.profiles(people.map(\.profileID))
                self?.adopt(identity, admins: admins, firsts: firsts?.members ?? [], requests: requests,
                            profiles: profiles, viewer: viewer)
            } catch {
                guard let self else { return }
                if self.state.phase != .loaded {
                    self.state.phase = .failed(FailureCopy.message(for: error, fallback: "Couldn't load this group."))
                }
            }
        }
    }

    private func adopt(
        _ identity: ConversationIdentity, admins: ConversationMemberPage?, firsts: [ConversationMember], requests: Int,
        profiles: [ProfileID: ChatProfile], viewer: ProfileID?
    ) {
        viewerID = viewer
        let adminList = admins?.members ?? []
        for member in adminList + firsts { known[member.profileID] = member }
        var next = state
        next.phase = .loaded
        let viewerRole = adminList.first { $0.profileID == viewer }?.role ?? identity.viewerState.role
        next.viewerRole = viewerRole
        next.memberCount = identity.memberCount
        next.followerCount = identity.subscriberCount
        next.adminCount = admins?.total ?? adminList.count
        next.requestCount = requests
        next.visibility = identity.visibility
        next.isFull = identity.isFull
        next.ownName = identity.name
        let others = firsts.filter { $0.profileID != viewer }.compactMap { profiles[$0.profileID]?.name }
        next.name = identity.name.isEmpty
            ? ConversationIdentity.memberName(others, total: max(0, next.memberCount - 1))
            : identity.name
        next.photoURL = identity.photoURL
        // The members read so far — the admins and the first page — each once.
        var seen = Set<ProfileID>()
        let readMembers = (adminList + firsts).filter { seen.insert($0.profileID).inserted }
        next.groupAvatar = GroupAvatarContent(
            name: next.name, photoURL: identity.photoURL,
            faces: ConversationMember.groupFaces(readMembers, viewer: viewer) { id in
                let profile = profiles[id]
                let name = profile?.name ?? ""
                return (name: name.isEmpty ? profile?.handle ?? "" : name, avatarURL: profile?.avatarURL)
            },
            memberCount: next.memberCount
        )
        next.description = identity.description
        next.admins = Self.rows(adminList, profiles: profiles, viewer: viewer, viewerRole: viewerRole)
        next.isMuted = isMuted()
        state = next
    }

    /// The owner first, then admins, then members; by name within each, the
    /// viewer signed "You".
    nonisolated static func rows(
        _ list: [ConversationMember], profiles: [ProfileID: ChatProfile], viewer: ProfileID?, viewerRole: ConversationRole?
    ) -> [MemberRow] {
        list.map { row(for: $0, profiles: profiles, viewer: viewer, viewerRole: viewerRole) }
            .sorted { lhs, rhs in
                if lhs.role != rhs.role { return lhs.role < rhs.role }
                if lhs.isViewer != rhs.isViewer { return lhs.isViewer }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    nonisolated static func row(
        for member: ConversationMember, profiles: [ProfileID: ChatProfile], viewer: ProfileID?, viewerRole: ConversationRole?
    ) -> MemberRow {
        let profile = profiles[member.profileID]
        let isViewer = member.profileID == viewer
        let named = profile.flatMap { $0.name.isEmpty ? $0.handle : $0.name } ?? "Member"
        return MemberRow(
            id: member.profileID, name: isViewer ? "You" : named, handle: profile?.handle, avatarURL: profile?.avatarURL,
            role: member.role, isViewer: isViewer, actions: actions(by: viewerRole, viewer: viewer, on: member)
        )
    }

    /// One page of a list behind a counter (#2237), in the server's order,
    /// each row with what the viewer may do to them.
    func page(of list: ConversationInfoList, after token: String?) async throws -> PersonListPage {
        if list == .requests {
            guard state.canEdit else { return PersonListPage(rows: [], nextPageToken: nil, total: 0) }
            return try await ConversationRequestsPage.read(
                service: service, conversationID: conversationID, after: token, limit: Self.pageSize
            )
        }
        guard let roles = list.roles else { return PersonListPage(rows: [], nextPageToken: nil, total: 0) }
        let page = try await service.members(of: conversationID, roles: roles, after: token, limit: Self.pageSize)
        for member in page.members { known[member.profileID] = member }
        let profiles = await service.profiles(page.members.map(\.profileID))
        let viewer = viewerID
        let role = state.viewerRole
        let rows = page.members.map { Self.row(for: $0, profiles: profiles, viewer: viewer, viewerRole: role).listRow }
        return PersonListPage(rows: rows, nextPageToken: page.nextPageToken, total: page.total)
    }

    // MARK: - Writes

    /// A member's menu: the action, written, then the group read again.
    func perform(_ action: MemberAction, on profileID: ProfileID) {
        guard let member = known[profileID],
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

    /// The member a list row names, as read.
    func member(_ profileID: ProfileID) -> ConversationMember? { known[profileID] }

    nonisolated static func failureWords(for action: MemberAction) -> String {
        switch action {
        case .makeAdmin, .removeAdmin: "Couldn't change their role"
        case .transferOwnership: "Couldn't hand over the group"
        case .remove, .ban: "Couldn't remove them"
        }
    }

    /// A join request's answer, from the Requests list — owner and admins.
    func answer(_ profileID: ProfileID, approve: Bool) {
        guard state.canEdit else { return }
        let groupService = service
        let id = conversationID
        write(failure: approve ? "Couldn't approve the request" : "Couldn't decline the request") {
            try await groupService.answerJoinRequest(from: profileID, to: id, approve: approve)
        }
    }

    /// The name and the description, from the editing sheet. Owner and
    /// admins only; the photo stays as it is (no picker yet, see
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

    /// Public or Private, once the screen has asked (#2217) — owner and
    /// admins. Going public opens what is said from now on to anyone; going
    /// private closes it to its followers at once. The group is read again:
    /// the server's answer is the switch.
    func setVisibility(_ visibility: ConversationVisibility) {
        guard state.canChangeVisibility, visibility != state.visibility,
              GroupCopy.choosableVisibilities.contains(visibility) else { return }
        let groupService = service
        let id = conversationID
        write(failure: visibility == .public ? "Couldn't make the group public" : "Couldn't make the group private") {
            try await groupService.setVisibility(visibility, of: id)
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

    /// Everyone read so far, the viewer included — what the picker excludes;
    /// the server answers anyone already in as they are.
    var memberIDs: Set<ProfileID> {
        Set(known.values.filter(\.role.talks).map(\.profileID)).union(viewerID.map { [$0] } ?? [])
    }

    /// An outsider or a follower joins a public group with room (#2217).
    func join() {
        guard state.visibility == .public, state.isOutsider || state.isFollower, !state.isFull else { return }
        let groupService = service
        let id = conversationID
        write(failure: "Couldn't join the group") { _ = try await groupService.requestToJoin(id) }
    }

    /// An outsider follows a public group (#2217).
    func follow() {
        guard state.visibility == .public, state.isOutsider else { return }
        let groupService = service
        let id = conversationID
        write(failure: "Couldn't follow the group") { try await groupService.subscribe(to: id) }
    }

    /// A follower stops following (#2217) — from the "⋯", as #2236 puts the
    /// thread's ways out.
    func unfollow() {
        guard state.isFollower else { return }
        let groupService = service
        let id = conversationID
        write(failure: "Couldn't unfollow the group") { try await groupService.unsubscribe(from: id) }
    }

    /// The bell (#2237): muted until `until` (nil: until turned back on), or
    /// on again — shown at once, put back if refused.
    func setMute(_ muting: Bool, until: Date? = nil) {
        state.isMuted = muting
        setMuted(muting, until) { [weak self] confirmed in
            guard let self else { return }
            self.state.isMuted = self.isMuted()
            if !confirmed {
                self.onFailure?(ConversationListViewModel.muteAnswer(muting: muting, confirmed: false))
            }
        }
    }

    /// The bell's tap: the other way.
    func toggleMute() { setMute(!state.isMuted) }

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
                self.onPeopleChange?()
                self.load()
            } catch {
                guard let self else { return }
                self.state.isWorking = false
                self.onFailure?(FailureCopy.message(for: error, fallback: failure))
            }
        }
    }
}

/// A conversation's join requests as a list's pages (#2237): read whole —
/// they are a few — and served a page at a time, each row with Approve and
/// Decline.
enum ConversationRequestsPage {
    @MainActor
    static func read(
        service: any GroupChatServicing, conversationID: ConversationID, after token: String?, limit: Int
    ) async throws -> PersonListPage {
        let requests = try await service.joinRequests(to: conversationID)
        let start = min(max(0, Int(token ?? "") ?? 0), requests.count)
        let end = min(start + max(1, limit), requests.count)
        let slice = Array(requests[start..<end])
        let profiles = await service.profiles(slice.map(\.profileID))
        let now = Date()
        let rows: [PersonListRow] = slice.map { request in
            let profile = profiles[request.profileID]
            let name = profile.flatMap { $0.name.isEmpty ? $0.handle : $0.name } ?? "Someone"
            let when = RelativeAgeFormatter.short(from: request.requestedAt, to: now)
            let detail = [profile?.handle.map { "@\($0)" }, when].compactMap(\.self).joined(separator: " · ")
            return PersonListRow(
                id: request.profileID.rawValue, name: name, detail: detail, avatarURL: profile?.avatarURL,
                monogram: MonogramAvatarView.monogram(name: name, handle: profile?.handle ?? ""), answersRequest: true
            )
        }
        return PersonListPage(rows: rows, nextPageToken: end < requests.count ? String(end) : nil, total: requests.count)
    }
}
