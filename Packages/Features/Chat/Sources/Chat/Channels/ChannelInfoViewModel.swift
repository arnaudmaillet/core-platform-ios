import CoreModels
import CoreNavigation
import CoreNetworking
import DesignSystem
import Foundation
import HeroPage

/// A channel's info screen (#2215, #2237): its identity, visibility and
/// counters; what the viewer may do, decided here, in one place
/// (`actions(by:viewer:on:)`, `canEdit`…) — the screen draws what it is
/// told: the header (`header(for:id:viewer:)`), the "⋯" (`menu(for:)`), the
/// lists behind the counters (`listTabs(for:)`, `page(of:after:)`).
///
/// The subscribers are read page by page (#2237, #995's paged
/// `ListMembers`): a channel of 12 400 is never read at once, and the screen
/// holds no person rows — only the owner and the admins it names.
///
/// Every write goes through `ConversationManaging`, then the channel is read
/// again: the server's answer is the screen, never a local guess at it.
@MainActor
final class ChannelInfoViewModel {
    /// What an owner or an admin may do to someone in the channel.
    nonisolated enum MemberAction: String, Equatable, Sendable, CaseIterable {
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

        /// The row the lists draw (#2237).
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
        var photoURL: URL?
        var description = ""
        var visibility: ConversationVisibility = .public
        var subscriberCount = 0
        var viewerState: ConversationViewerState = .none
        /// The owner, then the admins.
        var admins: [MemberRow] = []
        /// The owner and the admins: the Admins counter (#2237).
        var adminCount = 0
        /// The owner, for "by @owner" (#2237).
        var owner: MemberRow?
        /// Pending join requests, for owner and admins.
        var requestCount = 0
        var isMuted = false
        var isWorking = false
        /// Whether the screen offers "Share as a Post" at all (#2216,
        /// `-channels`): set once, by whoever builds the screen.
        var sharesShowcases = false

        var viewerRole: ConversationRole? { viewerState.role }
        /// Owner and admins edit the identity and the visibility, and see
        /// requests and subscribers.
        var canEdit: Bool { viewerState.runsChannel }
        /// The owner names and unnames admins.
        var canManageAdmins: Bool { viewerRole == .owner }
        /// Anyone in it mutes and leaves it.
        var isIn: Bool { viewerRole != nil }
        var subtitle: String { ChannelCopy.subscriberCount(subscriberCount) }
        /// "Share as a Post" (#2216): owner and admins of a channel the card
        /// can show — never a private one — once it is loaded.
        var canShareAsPost: Bool {
            sharesShowcases && phase == .loaded
                && ChannelShowcase.canShare(viewerState: viewerState, visibility: visibility)
        }
    }

    var onStateChange: ((State) -> Void)?
    /// A notice: `(title, message)` — the owner's "hand it over first".
    var onNotice: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// The viewer left: the host takes them back.
    var onLeft: (() -> Void)?
    /// The channel changed: the thread and the tab read it again.
    var onChange: (() -> Void)?
    /// A write changed who is in which list: the lists read again (#2237).
    var onPeopleChange: (() -> Void)?

    private(set) var state = State() { didSet { if state != oldValue { onStateChange?(state) } } }

    let conversationID: ConversationID
    private let service: any GroupChatServicing
    private let isMuted: @MainActor () -> Bool
    private let setMuted: @MainActor (_ muted: Bool, _ until: Date?, _ completion: @escaping @MainActor (Bool) -> Void) -> Void
    private(set) var viewerID: ProfileID?
    /// Everyone read so far, by any list: whom a row's menu acts on.
    private var known: [ProfileID: ConversationMember] = [:]
    static let pageSize = 30

    init(
        conversationID: ConversationID,
        service: any GroupChatServicing,
        isMuted: @escaping @MainActor () -> Bool = { false },
        setMuted: @escaping @MainActor (_ muted: Bool, _ until: Date?, _ completion: @escaping @MainActor (Bool) -> Void) -> Void = {
            _, _, done in done(false)
        },
        sharesShowcases: Bool = false
    ) {
        self.conversationID = conversationID
        self.service = service
        self.isMuted = isMuted
        self.setMuted = setMuted
        state.isMuted = isMuted()
        state.sharesShowcases = sharesShowcases
    }

    // MARK: - Showcase (#2216)

    /// The card "Share as a Post" opens the composer with: the channel as
    /// this screen shows it. Nil when the viewer may not share it.
    var showcaseEmbed: PostEmbed? {
        guard state.canShareAsPost else { return nil }
        return ChannelShowcase.embed(
            conversationID, name: state.name, photoURL: state.photoURL, description: state.description,
            subscriberCount: state.subscriberCount, visibility: state.visibility
        )
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

    // MARK: - What the screen shows (#2237)

    /// "Public channel · by @owner", "Channel on request · by @owner".
    nonisolated static func subtitle(visibility: ConversationVisibility, ownerHandle: String?) -> String {
        let kind: String = switch visibility {
        case .public: "Public channel"
        case .listedOnRequest: "Channel on request"
        case .private: "Private channel"
        }
        guard let ownerHandle, !ownerHandle.isEmpty else { return kind }
        return "\(kind) · by @\(ownerHandle)"
    }

    /// The header for `state`: the profile's and the place's, drawing a
    /// channel.
    nonisolated static func header(for state: State, id: ConversationID) -> ConversationInfoHeader {
        let link = state.visibility == .private && !state.canEdit ? nil : AppRoute.conversationLink(id)
        var counters: [ConversationInfoList: Int] = [.subscribers: state.subscriberCount]
        if state.isIn { counters[.admins] = state.adminCount }
        if state.canEdit, state.requestCount > 0 { counters[.requests] = state.requestCount }
        var openable: Set<ConversationInfoList> = []
        if state.isIn { openable.insert(.admins) }
        if state.canEdit { openable.formUnion([.subscribers, .requests]) }
        let capsules: [ConversationInfoAction]
        if state.canEdit {
            capsules = [.edit, .invite]
        } else {
            switch state.viewerState {
            case .none, .invited:
                capsules = switch state.visibility {
                case .public: [.join]
                case .listedOnRequest: [.requestToJoin]
                case .private: []
                }
            case .requested: capsules = [.requested]
            default: capsules = []
            }
        }
        let owner = state.owner
        return ConversationInfoHeader(
            title: state.name, titleSymbol: ConversationInfoHeader.channelSymbol,
            subtitle: subtitle(visibility: state.visibility, ownerHandle: owner?.handle),
            subtitleOwner: owner.flatMap { $0.isViewer || $0.handle == nil ? nil : $0.id },
            bio: state.description.isEmpty ? nil : state.description,
            linkText: ConversationInfoHeader.linkText(link), linkURL: link,
            photoURL: state.photoURL, monogram: MonogramAvatarView.monogram(name: state.name, handle: ""),
            counters: counters, openable: openable, capsules: capsules,
            bubbles: link == nil ? [] : [.share]
        )
    }

    /// The bar's "⋯" for `state`, Leave last; never Leave for the owner, who
    /// hands the channel over first.
    nonisolated static func menu(for state: State) -> [ConversationInfoMenuEntry] {
        var entries: [ConversationInfoMenuEntry] = []
        if state.canShareAsPost { entries.append(.shareAsPost) }
        if state.canEdit { entries.append(.visibility) }
        if state.viewerRole == .owner { entries.append(.transferOwnership) }
        if state.isIn, state.viewerRole != .owner { entries.append(.leave) }
        return entries
    }

    /// The lists behind the counters, for who may read them: Subscribers
    /// and Requests for owner and admins, Admins for anyone in.
    nonisolated static func listTabs(for state: State) -> [PersonListTab] {
        var lists: [ConversationInfoList] = []
        if state.canEdit { lists.append(.subscribers) }
        if state.isIn { lists.append(.admins) }
        if state.canEdit { lists.append(.requests) }
        return lists.map { list in
            let count: Int = switch list {
            case .subscribers, .followers: state.subscriberCount
            case .admins, .members: state.adminCount
            case .requests: state.requestCount
            }
            let lead: PersonListTab.LeadingAction? = switch list {
            case .subscribers where state.canEdit: PersonListTab.LeadingAction(title: "Invite People", symbol: "link")
            case .admins where state.canManageAdmins: PersonListTab.LeadingAction(title: "Add Admin", symbol: "person.badge.plus")
            default: nil
            }
            return PersonListTab(id: list.rawValue, title: list.tabTitle(count: count), empty: list.empty(channel: true), leadingAction: lead)
        }
    }

    var header: ConversationInfoHeader { Self.header(for: state, id: conversationID) }

    // MARK: - Reads

    func load() {
        let channelService = service
        let id = conversationID
        Task { [weak self] in
            do {
                let identity = try await channelService.details(of: id)
                let viewer = try? await channelService.viewerProfileID()
                // A channel the viewer isn't in shows itself — and its owner,
                // for "by @owner" — not its people.
                let admins: ConversationMemberPage? =
                    try? await channelService.members(of: id, roles: [.owner, .admin], after: nil, limit: 50)
                var requests = 0
                if identity.viewerState.runsChannel {
                    requests = (try? await channelService.joinRequests(to: id).count) ?? 0
                }
                let people: [ConversationMember] = admins?.members ?? []
                let profiles = await channelService.profiles(people.map(\.profileID))
                self?.adopt(identity, admins: admins, requests: requests, profiles: profiles, viewer: viewer)
            } catch {
                guard let self, self.state.phase != .loaded else { return }
                self.state.phase = .failed(FailureCopy.message(for: error, fallback: "Couldn't load this channel."))
            }
        }
    }

    private func adopt(
        _ identity: ConversationIdentity, admins: ConversationMemberPage?, requests: Int,
        profiles: [ProfileID: ChatProfile], viewer: ProfileID?
    ) {
        viewerID = viewer
        let list = admins?.members ?? []
        for member in list { known[member.profileID] = member }
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
        next.owner = rows.first { $0.role == .owner }
        // The people are the insiders' to see; the owner names the channel
        // to anyone ("by @owner").
        next.admins = identity.viewerState.role == nil ? [] : rows
        next.adminCount = identity.viewerState.role == nil ? 0 : (admins?.total ?? rows.count)
        next.isMuted = isMuted()
        state = next
    }

    /// The owner first, then admins, then subscribers; by name within each,
    /// the viewer signed "You".
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
        let named = profile.flatMap { $0.name.isEmpty ? $0.handle : $0.name } ?? "Subscriber"
        return MemberRow(
            id: member.profileID, name: isViewer ? "You" : named, handle: profile?.handle,
            avatarURL: profile?.avatarURL, role: member.role, isViewer: isViewer,
            actions: actions(by: viewerRole, viewer: viewer, on: member)
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
        // Subscribers are the managers' to see; the admins, anyone in's.
        let allowed = list == .admins ? state.isIn : state.canEdit
        guard allowed, let roles = list.roles else { return PersonListPage(rows: [], nextPageToken: nil, total: 0) }
        let page = try await service.members(of: conversationID, roles: roles, after: token, limit: Self.pageSize)
        for member in page.members { known[member.profileID] = member }
        let profiles = await service.profiles(page.members.map(\.profileID))
        let viewer = viewerID
        let role = state.viewerRole
        let rows = page.members.map { Self.row(for: $0, profiles: profiles, viewer: viewer, viewerRole: role).listRow }
        return PersonListPage(rows: rows, nextPageToken: page.nextPageToken, total: page.total)
    }

    /// Who "Add Admin" offers (#2215): subscribers the owner may name, from
    /// the first page of them.
    func adminCandidates() async -> [MemberRow] {
        guard state.canManageAdmins,
              let page = try? await service.members(of: conversationID, roles: [.subscriber], after: nil, limit: 50)
        else { return [] }
        for member in page.members { known[member.profileID] = member }
        let profiles = await service.profiles(page.members.map(\.profileID))
        return Self.rows(page.members, profiles: profiles, viewer: viewerID, viewerRole: state.viewerRole)
            .filter { $0.actions.contains(.makeAdmin) }
    }

    /// The member a list row names, as read.
    func member(_ profileID: ProfileID) -> ConversationMember? { known[profileID] }

    // MARK: - Writes

    func perform(_ action: MemberAction, on profileID: ProfileID) {
        guard let member = known[profileID],
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

    /// A join request's answer, from the Requests list — owner and admins.
    func answer(_ profileID: ProfileID, approve: Bool) {
        guard state.canEdit else { return }
        let channelService = service
        let id = conversationID
        write(failure: approve ? "Couldn't approve the request" : "Couldn't decline the request") {
            try await channelService.answerJoinRequest(from: profileID, to: id, approve: approve)
        }
    }

    /// The name and the description, from the editing sheet. A channel keeps
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

    /// An outsider joins a public channel, or asks to join one on request.
    func join() {
        guard state.viewerState == .none || state.viewerState == .invited, state.visibility != .private else { return }
        let channelService = service
        let id = conversationID
        write(failure: "Couldn't join the channel") { _ = try await channelService.requestToJoin(id) }
    }

    /// The viewer takes their request back.
    func cancelJoinRequest() {
        guard state.viewerState == .requested else { return }
        let channelService = service
        let id = conversationID
        write(failure: "Couldn't cancel the request") { try await channelService.cancelJoinRequest(id) }
    }

    /// The join requests were answered elsewhere (the requests list): read
    /// again.
    func requestsChanged() {
        onChange?()
        load()
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

    func toggleMute() { setMute(!state.isMuted) }

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
