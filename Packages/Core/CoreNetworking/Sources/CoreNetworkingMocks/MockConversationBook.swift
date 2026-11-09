import CoreModels
import CoreNetworking
import Foundation

/// The mock's groups and channels (#2213), as core-platform-backend#995
/// describes them: identity, members with roles, visibility, invitations,
/// join requests. `MockChatService` lists them in the inbox (their kind on
/// the entry) and answers `ProposedChat` from here.
///
/// Seeded only when asked (`-group-chats`, `-channels` at launch; the
/// tests ask): without them the inbox is DMs only, as it was.
final class MockConversationBook: @unchecked Sendable {
    struct Record {
        var details: ProposedChat.Details
        /// profile → role, the viewer included when in.
        var members: [String: ProposedChat.Role]
        var joinedAtMs: [String: Int64]
        var joinRequests: [ProposedChat.JoinRequest]
        var banned: Set<String> = []
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var created = 0
    let viewer: String

    init(viewer: String, authors: [String], seedsGroups: Bool, seedsChannels: Bool, now: Int64) {
        self.viewer = viewer
        let day: Int64 = 86_400_000
        func author(_ index: Int) -> String { authors[index % max(1, authors.count)] }
        func photo(_ seed: String) -> String { "https://picsum.photos/seed/\(seed)/400/400" }
        if seedsGroups {
            add(.init(conversationID: "grp-hike", kind: .group, name: "Weekend hike", photoURL: photo("hike"),
                      description: "Saturday mornings, wherever the weather lets us.", visibility: .private),
                members: [viewer: .owner, author(0): .admin, author(1): .member, author(2): .member, author(3): .member],
                since: now - 40 * day)
            // No name, no photo: named and faced by its members.
            add(.init(conversationID: "grp-studio", kind: .group, visibility: .private),
                members: [viewer: .member, author(4): .owner, author(5): .member], since: now - 12 * day)
            var crew: [String: ProposedChat.Role] = [viewer: .member, author(6): .owner, author(7): .admin]
            for index in 8..<45 { crew[author(index)] = .member }
            add(.init(conversationID: "grp-printfair", kind: .group, name: "Print fair crew", photoURL: photo("printfair"),
                      description: "Stalls, rotas and the van.", visibility: .private),
                members: crew, since: now - 90 * day)
            // The viewer is invited, not in yet.
            add(.init(conversationID: "grp-nightwalk", kind: .group, name: "Night photo walk", photoURL: photo("nightwalk"),
                      visibility: .private, viewerState: .invited, invitedBy: author(3)),
                members: [author(3): .owner, author(9): .member, author(10): .member], since: now - 2 * day)
        }
        if seedsChannels {
            add(.init(conversationID: "ch-daily", kind: .channel, name: "Daily light", photoURL: photo("dailylight"),
                      description: "One photo of the day's best light, every evening.", visibility: .public,
                      subscriberCount: 12_400),
                members: [viewer: .owner, author(1): .admin], since: now - 200 * day,
                requests: [])
            add(.init(conversationID: "ch-botanic", kind: .channel, name: "Botanical prints", photoURL: photo("botanic"),
                      description: "New prints, studio notes and the odd sale.", visibility: .listedOnRequest,
                      subscriberCount: 820),
                members: [author(29): .owner, viewer: .subscriber], since: now - 30 * day)
            add(.init(conversationID: "ch-film", kind: .channel, name: "Film stock club", photoURL: photo("filmclub"),
                      description: "Stocks, labs, and what came back.", visibility: .listedOnRequest,
                      subscriberCount: 50_000, viewerState: .requested),
                members: [author(11): .owner], since: now - 400 * day,
                requests: [.init(profileID: viewer, requestedAtMs: now - day)])
            add(.init(conversationID: "ch-harbour", kind: .channel, name: "Harbour notes", photoURL: photo("harbour"),
                      description: "Boats in, boats out.", visibility: .public, subscriberCount: 10),
                members: [author(12): .owner], since: now - 8 * day)
            add(.init(conversationID: "ch-studio-requests", kind: .channel, name: "Studio drops", photoURL: photo("studiodrops"),
                      description: "Members-only drops from the studio.", visibility: .listedOnRequest,
                      subscriberCount: 64),
                members: [viewer: .owner], since: now - 20 * day,
                requests: [author(13), author(14), author(15)].enumerated().map {
                    .init(profileID: $0.element, requestedAtMs: now - Int64($0.offset + 1) * 3_600_000)
                })
            // For the showcases (#2216): one on request the viewer has no
            // standing in (Request to join), and one turned private (its
            // showcase reads "This channel is private"). A showcase whose
            // channel is in no record reads as deleted.
            add(.init(conversationID: "ch-printroom", kind: .channel, name: "Print room", photoURL: photo("printroom"),
                      description: "Proofs, plates and the press, from the studio floor.", visibility: .listedOnRequest,
                      subscriberCount: 340),
                members: [author(16): .owner, author(17): .admin], since: now - 60 * day)
            add(.init(conversationID: "ch-backroom", kind: .channel, name: "Backroom sessions", photoURL: photo("backroom"),
                      description: "Live sets, invite only.", visibility: .private, subscriberCount: 95),
                members: [author(18): .owner], since: now - 15 * day)
        }
    }

    private func add(
        _ details: ProposedChat.Details, members: [String: ProposedChat.Role], since: Int64,
        requests: [ProposedChat.JoinRequest] = []
    ) {
        var record = Record(details: details, members: members, joinedAtMs: [:], joinRequests: requests)
        for (offset, member) in members.keys.sorted().enumerated() { record.joinedAtMs[member] = since + Int64(offset) * 60_000 }
        records[details.conversationID] = record
        order.append(details.conversationID)
    }

    // MARK: - Reads for the inbox

    /// The conversations the viewer's inbox lists: the ones they are in,
    /// and the ones they are invited to.
    var inboxIDs: [String] {
        lock.withLock {
            order.filter { id in
                guard let record = records[id] else { return false }
                return record.members[viewer] != nil || record.details.viewerState == .invited
            }
        }
    }

    func kind(of id: String) -> ProposedChat.Kind? { lock.withLock { records[id]?.details.kind } }

    func members(of id: String) -> [(profileID: String, role: ProposedChat.Role, joinedAtMs: Int64)] {
        lock.withLock {
            guard let record = records[id] else { return [] }
            return record.members.keys.sorted().map { ($0, record.members[$0]!, record.joinedAtMs[$0] ?? 0) }
        }
    }

    /// Whether `profile` posts in channel `id` (#2215): its owner and admins.
    func publishes(_ profile: String, in id: String) -> Bool {
        lock.withLock {
            guard let role = records[id]?.members[profile] else { return false }
            return role == .owner || role == .admin
        }
    }

    // MARK: - Showcases (#2216)

    /// Channel `id` as a showcase's card shows it to `viewer`, read now — as
    /// the backend hydrates an embed in the feed, map and search responses
    /// (#995), so a join or a request made through the chat mock shows on
    /// the next read of the post. Nil for a conversation that is not a
    /// channel.
    ///
    /// - In no record: deleted.
    /// - Private and the viewer not in: private — the card can't show it.
    /// - `blocksOwner`: a block either way with its owner hides it.
    /// - An owner and an admin are members to the card (Open).
    func channelEmbed(
        _ id: String, for viewer: String, lastMessage: String?, blocksOwner: (String) -> Bool
    ) -> ChannelEmbed? {
        lock.withLock { () -> ChannelEmbed? in
            guard let record = records[id] else {
                return ChannelEmbed(conversationID: ConversationID(id), availability: .deleted)
            }
            guard record.details.kind == .channel, let details = details(id, for: viewer) else { return nil }
            let state = Self.embedState(details.viewerState)
            let isIn = state == .member || state == .subscriber
            // A private channel tells an outsider nothing — not even its
            // name (#995: it can't be probed).
            if details.visibility == .private, !isIn {
                return ChannelEmbed(conversationID: ConversationID(id), availability: .private)
            }
            let owner = record.members.first { $0.value == .owner }?.key
            let blocked = owner.map { $0 != viewer && blocksOwner($0) } ?? false
            let availability: ChannelEmbed.Availability = blocked ? .blocked : .available
            // Only a reader sees what was said: a public channel's, or one
            // the viewer is in.
            let readable = isIn || details.visibility == .public
            return ChannelEmbed(
                conversationID: ConversationID(id),
                name: details.name,
                photoURL: details.photoURL.isEmpty ? nil : URL(string: details.photoURL),
                description: details.description,
                subscriberCount: details.subscriberCount,
                visibility: details.visibility == .public ? .public : .onRequest,
                viewerState: state,
                availability: availability,
                lastMessagePreview: readable ? lastMessage : nil
            )
        }
    }

    /// A standing as the card says it: an owner and an admin are members
    /// (Open); an invitation is no standing yet.
    private static func embedState(_ state: ProposedChat.ViewerState) -> ChannelEmbed.ViewerState {
        switch state {
        case .owner, .admin, .member: return .member
        case .subscriber: return .subscriber
        case .requested: return .requested
        case .banned: return .banned
        case .invited, .none: return .none
        }
    }

    // MARK: - ProposedChat

    func answer(_ call: ProposedChat.Call, now: Int64) -> ProposedChat.Reply {
        lock.withLock { handle(call, now: now) }
    }

    private func refused(_ message: String) -> ProposedChat.Reply { ProposedChat.Reply(error: message) }

    private func details(_ id: String, for viewer: String) -> ProposedChat.Details? {
        guard var record = records[id] else { return nil }
        let role = record.members[viewer]
        record.details.viewerState = switch role {
        case .owner: .owner
        case .admin: .admin
        case .member: .member
        case .subscriber, .guest: .subscriber
        case nil:
            if record.banned.contains(viewer) { .banned }
            else if record.joinRequests.contains(where: { $0.profileID == viewer }) { .requested }
            else if record.details.viewerState == .invited, viewer == self.viewer { .invited }
            else { .none }
        }
        let talkers = record.members.values.filter { $0 == .owner || $0 == .admin || $0 == .member }.count
        if record.details.kind == .group { record.details.memberCount = record.members.count } else {
            record.details.memberCount = talkers
        }
        return record.details
    }

    private func manages(_ viewer: String, _ id: String) -> Bool {
        guard let role = records[id]?.members[viewer] else { return false }
        return role == .owner || role == .admin
    }

    private func handle(_ call: ProposedChat.Call, now: Int64) -> ProposedChat.Reply {
        switch call {
        case let .details(viewer, ids):
            // A private conversation answers an outsider as a missing one.
            return ProposedChat.Reply(details: ids.compactMap { id in
                guard let found = details(id, for: viewer) else { return nil }
                if found.visibility == .private, found.viewerState == .none { return nil }
                return found
            })
        case let .members(viewer, id):
            guard let record = records[id], record.members[viewer] != nil || record.details.visibility != .private else {
                return refused("CHT-1004: conversation not found")
            }
            return ProposedChat.Reply(members: record.members.keys.sorted().map {
                ProposedChat.Member(profileID: $0, role: record.members[$0]!, joinedAtMs: record.joinedAtMs[$0] ?? 0)
            })
        case let .create(viewer, kind, name, photoURL, description, visibility, memberIDs):
            created += 1
            let id = "\(kind == .channel ? "ch" : "grp")-new-\(created)"
            var members: [String: ProposedChat.Role] = [viewer: .owner]
            if kind == .group { for member in memberIDs where member != viewer { members[member] = .member } }
            records[id] = Record(
                details: .init(conversationID: id, kind: kind, name: name, photoURL: photoURL, description: description,
                               visibility: visibility, subscriberCount: 0),
                members: members, joinedAtMs: Dictionary(uniqueKeysWithValues: members.keys.map { ($0, now) }), joinRequests: []
            )
            order.insert(id, at: 0)
            return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [], conversationID: id)
        case let .editIdentity(viewer, id, name, photoURL, description):
            guard manages(viewer, id) else { return refused("CHT-1030: only an owner or an admin edits this") }
            records[id]?.details.name = name
            records[id]?.details.photoURL = photoURL
            records[id]?.details.description = description
            return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [])
        case let .invite(viewer, id, profileIDs):
            guard manages(viewer, id) else { return refused("CHT-1030: only an owner or an admin invites") }
            // Invitations reach the invitees (#995); the mock has no other
            // viewer to show them to.
            _ = profileIDs
            return ProposedChat.Reply()
        case let .answerInvitation(viewer, id, accept):
            guard records[id]?.details.viewerState == .invited, viewer == self.viewer else {
                return refused("CHT-1004: no invitation")
            }
            records[id]?.details.viewerState = .none
            if accept {
                records[id]?.members[viewer] = .member
                records[id]?.joinedAtMs[viewer] = now
            } else {
                order.removeAll { $0 == id }
            }
            return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [])
        case let .requestToJoin(viewer, id):
            guard let record = records[id], record.details.visibility != .private else {
                return refused("CHT-1004: conversation not found")
            }
            if record.banned.contains(viewer) { return refused("CHT-1032: you can't join this") }
            if record.members[viewer] != nil { return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? []) }
            if record.details.visibility == .public {
                records[id]?.members[viewer] = record.details.kind == .channel ? .subscriber : .member
                records[id]?.joinedAtMs[viewer] = now
                if record.details.kind == .channel { records[id]?.details.subscriberCount += 1 }
            } else if !record.joinRequests.contains(where: { $0.profileID == viewer }) {
                records[id]?.joinRequests.append(.init(profileID: viewer, requestedAtMs: now))
            }
            return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [])
        case let .cancelJoinRequest(viewer, id):
            records[id]?.joinRequests.removeAll { $0.profileID == viewer }
            return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [])
        case let .joinRequests(viewer, id):
            guard manages(viewer, id) else { return refused("CHT-1030: only an owner or an admin sees requests") }
            return ProposedChat.Reply(joinRequests: records[id]?.joinRequests ?? [])
        case let .answerJoinRequest(viewer, id, requester, approve):
            guard manages(viewer, id) else { return refused("CHT-1030: only an owner or an admin answers requests") }
            guard records[id]?.joinRequests.contains(where: { $0.profileID == requester }) == true else {
                return refused("CHT-1004: no such request")
            }
            records[id]?.joinRequests.removeAll { $0.profileID == requester }
            if approve, let kind = records[id]?.details.kind {
                records[id]?.members[requester] = kind == .channel ? .subscriber : .member
                records[id]?.joinedAtMs[requester] = now
                if kind == .channel { records[id]?.details.subscriberCount += 1 }
            }
            return ProposedChat.Reply(joinRequests: records[id]?.joinRequests ?? [])
        case let .setRole(viewer, id, member, role):
            guard manages(viewer, id), records[id]?.members[member] != nil else {
                return refused("CHT-1030: only an owner or an admin changes roles")
            }
            guard role != .owner, records[id]?.members[member] != .owner else {
                return refused("CHT-1033: ownership moves by transfer")
            }
            records[id]?.members[member] = role
            return ProposedChat.Reply()
        case let .remove(viewer, id, member, ban):
            guard manages(viewer, id), member != viewer else { return refused("CHT-1030: only an owner or an admin removes") }
            guard records[id]?.members[member] != .owner else { return refused("CHT-1033: the owner can't be removed") }
            let wasSubscriber = records[id]?.members[member] == .subscriber
            records[id]?.members[member] = nil
            if ban { records[id]?.banned.insert(member) }
            if wasSubscriber { records[id]?.details.subscriberCount -= 1 }
            return ProposedChat.Reply()
        case let .transferOwnership(viewer, id, to):
            guard records[id]?.members[viewer] == .owner, records[id]?.members[to] != nil else {
                return refused("CHT-1030: only the owner transfers, to a member")
            }
            records[id]?.members[to] = .owner
            records[id]?.members[viewer] = .admin
            return ProposedChat.Reply()
        case let .leave(viewer, id):
            guard let role = records[id]?.members[viewer] else { return refused("CHT-1004: not a member") }
            guard role != .owner else { return refused("CHT-1031: the owner transfers ownership before leaving") }
            records[id]?.members[viewer] = nil
            if role == .subscriber { records[id]?.details.subscriberCount -= 1 }
            return ProposedChat.Reply()
        case let .setVisibility(viewer, id, visibility):
            guard manages(viewer, id) else { return refused("CHT-1030: only an owner or an admin changes visibility") }
            records[id]?.details.visibility = visibility
            return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [])
        case let .subscribe(viewer, id):
            guard let record = records[id], record.details.visibility == .public else {
                return refused("CHT-1004: conversation not found")
            }
            if record.members[viewer] == nil {
                records[id]?.members[viewer] = .subscriber
                records[id]?.joinedAtMs[viewer] = now
                records[id]?.details.subscriberCount += 1
            }
            return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [])
        case let .unsubscribe(viewer, id):
            if records[id]?.members[viewer] == .subscriber {
                records[id]?.members[viewer] = nil
                records[id]?.details.subscriberCount -= 1
            }
            return ProposedChat.Reply()
        }
    }
}
