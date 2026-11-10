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
        /// The rest of its people (#2237): as many records as its counters
        /// say — a big group's members, its followers, a channel's
        /// subscribers — made up (`crowdAuthor`) rather than named in the
        /// seed. Kept apart from `members` so chat.v1's unpaged `ListMembers`,
        /// which the inbox reads per row, never carries 12 400 of them: only
        /// the paged read (`membersPage`) reaches the crowd, as a real
        /// audience is only ever read page by page (#995).
        var crowd: [Crowd] = []
        /// Crowd people who left, were removed, or were named by a write
        /// (`materialize`): no longer the crowd's.
        var crowdGone: Set<String> = []
        /// Since when a public conversation is readable by anyone (#2217,
        /// chat.v1's public-since watermark): what an outsider or a follower
        /// reads starts here; members read everything.
        var publicSinceMs: Int64?
    }

    /// A run of made-up people with one role (#2237): `prof-crowd-<n>`
    /// for each n in `ids`.
    struct Crowd {
        var role: ProposedChat.Role
        var ids: Range<Int>

        var profileIDs: [String] { ids.map(MockConversationBook.crowdID) }
    }

    /// The made-up people's ids (#2237).
    static let crowdPrefix = "prof-crowd-"
    static func crowdID(_ index: Int) -> String { "\(crowdPrefix)\(index)" }

    /// A made-up person of the crowd (#2237), named and faced the way the
    /// mock's authors are, so a subscribers list of 64 reads as 64 people:
    /// a first and a last name from two short lists, a handle from them, and
    /// one of the authors' faces — or none, every third, for the initials.
    /// Nil for an id that isn't the crowd's.
    static func crowdAuthor(for profileID: String, faces: [MockSocialDataset.Author]) -> MockSocialDataset.Author? {
        guard profileID.hasPrefix(crowdPrefix), let index = Int(profileID.dropFirst(crowdPrefix.count)), index >= 0
        else { return nil }
        let first = crowdFirstNames[index % crowdFirstNames.count]
        let last = crowdLastNames[(index / crowdFirstNames.count) % crowdLastNames.count]
        let face = faces.isEmpty || index % 3 == 2 ? "" : faces[index % faces.count].avatarURL
        return MockSocialDataset.Author(
            profileID: profileID, handle: "\(first.lowercased()).\(last.lowercased())\(index)",
            displayName: "\(first) \(last)", avatarURL: face, bannerURL: "", bio: "", websiteURL: ""
        )
    }

    private static let crowdFirstNames = [
        "Alba", "Bram", "Cleo", "Dev", "Elio", "Fern", "Gus", "Hana", "Ines", "Jude", "Kai", "Lior", "Mina",
        "Noor", "Otto", "Pia", "Quinn", "Rosa", "Sami", "Tove", "Uma", "Vito", "Wim", "Xia", "Yusuf", "Zora"
    ]
    private static let crowdLastNames = [
        "Abbott", "Brandt", "Costa", "Duval", "Eriksen", "Ferro", "Gallo", "Hale", "Ito", "Janssen", "Kovac",
        "Lund", "Moretti", "Novak", "Okafor", "Price", "Quist", "Rossi", "Sato", "Toth", "Ueda", "Varga"
    ]

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    /// The next made-up person's index: every crowd is its own people.
    private var nextCrowd = 0
    private var order: [String] = []
    private var created = 0
    let viewer: String

    /// The public groups the viewer doesn't belong to (#2217): one with room
    /// (an outsider's Join / Follow), one full (Follow only).
    static let publicGroupID = "grp-coastal"
    static let fullGroupID = "grp-darkroom"
    /// The public group the viewer follows (#2217): muted in their inbox,
    /// and the one `-mock-group-private-after` turns private.
    static let followedGroupID = "grp-riverside"
    /// The channel the viewer follows, joined muted (#2230): its unread
    /// posts show on its row and stay out of the Chats badge.
    static let mutedChannelID = "ch-botanic"
    /// The channel the viewer follows with notifications turned back on
    /// (#2230): its unread posts count in the badge.
    static let notifyingChannelID = "ch-tides"

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
            // Public groups (#2217). Their followers are counted
            // (`subscriberCount`), not named: the audience plane is unbounded.
            var coastal: [String: ProposedChat.Role] = [author(20): .owner, author(21): .admin]
            for index in 22..<28 { coastal[author(index)] = .member }
            add(.init(conversationID: Self.publicGroupID, kind: .group, name: "Coastal cleanup", photoURL: photo("coastal"),
                      description: "Beach cleans every other Sunday. Bags and gloves provided.", visibility: .public,
                      subscriberCount: 2_300),
                members: coastal, since: now - 60 * day, unnamedMembers: 40 - coastal.count, publicSince: now - 60 * day)
            var darkroom: [String: ProposedChat.Role] = [author(30): .owner, author(31): .admin]
            for index in 32..<36 { darkroom[author(index)] = .member }
            add(.init(conversationID: Self.fullGroupID, kind: .group, name: "Darkroom swap", photoURL: photo("darkroom"),
                      description: "Chemistry, paper and enlargers changing hands.", visibility: .public,
                      subscriberCount: 860),
                members: darkroom, since: now - 300 * day, unnamedMembers: ProposedChat.groupCap - darkroom.count,
                publicSince: now - 300 * day)
            add(.init(conversationID: Self.followedGroupID, kind: .group, name: "Riverside sketchers",
                      photoURL: photo("riverside"), description: "Sketching by the water, Thursday evenings.",
                      visibility: .public, subscriberCount: 340),
                members: [author(36): .owner, author(37): .member, author(38): .member, viewer: .subscriber],
                since: now - 25 * day, unnamedMembers: 15, publicSince: now - 25 * day)
        }
        if seedsChannels {
            add(.init(conversationID: "ch-daily", kind: .channel, name: "Daily light", photoURL: photo("dailylight"),
                      description: "One photo of the day's best light, every evening.", visibility: .public,
                      subscriberCount: 12_400),
                members: [viewer: .owner, author(1): .admin], since: now - 200 * day,
                requests: [])
            add(.init(conversationID: Self.mutedChannelID, kind: .channel, name: "Botanical prints", photoURL: photo("botanic"),
                      description: "New prints, studio notes and the odd sale.", visibility: .listedOnRequest,
                      subscriberCount: 820),
                members: [author(29): .owner, viewer: .subscriber], since: now - 30 * day)
            add(.init(conversationID: Self.notifyingChannelID, kind: .channel, name: "Tide tables", photoURL: photo("tides"),
                      description: "High and low water, every morning.", visibility: .public, subscriberCount: 1_150),
                members: [author(19): .owner, viewer: .subscriber], since: now - 10 * day)
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
            seedProfileChannels(author: author, photo: photo, now: now, day: day)
        }
    }

    /// The viewer's private channel (#2232): members only, so their own
    /// profile lists it with a lock and nobody else's read answers it.
    static let privateOwnChannelID = "ch-sketchbook"

    /// The channels that give profiles one, two and five of them (#2232),
    /// beside the ones seeded for Chats and the showcases:
    ///
    /// - **one:** author 12 (Harbour notes, Join) — and authors 19 and 29,
    ///   whose one the viewer follows (Open);
    /// - **two:** author 16 (Print room, Request; Press marks, Join). Author
    ///   17 admins Print room and owns none: no tab;
    /// - **five:** author 11 (Film stock club, Requested, and four more —
    ///   Join and Request), plus a private sixth only its owner would see;
    /// - **the viewer:** Daily light, Studio drops, and a private one (the
    ///   lock).
    ///
    /// None but the viewer's own puts the viewer in a channel, so Chats
    /// lists exactly what it did, plus the viewer's private channel.
    private func seedProfileChannels(
        author: (Int) -> String, photo: (String) -> String, now: Int64, day: Int64
    ) {
        add(.init(conversationID: Self.privateOwnChannelID, kind: .channel, name: "Sketchbook", photoURL: photo("sketchbook"),
                  description: "Unfinished pages, for a few friends.", visibility: .private, subscriberCount: 6),
            members: [viewer: .owner], since: now - 5 * day)
        add(.init(conversationID: "ch-pressmarks", kind: .channel, name: "Press marks", photoURL: photo("pressmarks"),
                  description: "Colophons, printers' marks and the stories behind them.", visibility: .public,
                  subscriberCount: 1_900),
            members: [author(16): .owner], since: now - 45 * day)
        let film: [(id: String, name: String, about: String, visibility: ProposedChat.Visibility, count: Int)] = [
            ("ch-labnotes", "Lab notes", "Development times, pushes and pulls.", .public, 8_200),
            ("ch-scans", "Scan day", "The week's scans, straight off the bed.", .public, 3_400),
            ("ch-expired", "Expired stock", "What a forty-year-old roll still holds.", .listedOnRequest, 2_100),
            ("ch-darkroom-chem", "Darkroom chemistry", "Mixing, storing, and what not to pour away.", .listedOnRequest, 640),
            ("ch-film-friends", "Contact sheets", "Whole rolls, for close friends.", .private, 40),
        ]
        for (offset, channel) in film.enumerated() {
            add(.init(conversationID: channel.id, kind: .channel, name: channel.name, photoURL: photo(channel.id),
                      description: channel.about, visibility: channel.visibility, subscriberCount: channel.count),
                members: [author(11): .owner], since: now - Int64(100 + offset * 30) * day)
        }
    }

    /// `unnamedMembers`: a group's members past the named ones. The
    /// followers or subscribers past the named ones come from the details'
    /// `subscriberCount`: every counter is as many records (#2237).
    private func add(
        _ details: ProposedChat.Details, members: [String: ProposedChat.Role], since: Int64,
        requests: [ProposedChat.JoinRequest] = [], unnamedMembers: Int = 0, publicSince: Int64? = nil
    ) {
        var record = Record(details: details, members: members, joinedAtMs: [:], joinRequests: requests)
        let namedAudience = members.values.filter { $0 == .subscriber || $0 == .guest }.count
        let audience = max(0, details.subscriberCount - namedAudience)
        if unnamedMembers > 0 { record.crowd.append(makeCrowd(.member, count: unnamedMembers)) }
        if audience > 0 { record.crowd.append(makeCrowd(.subscriber, count: audience)) }
        record.publicSinceMs = publicSince
        for (offset, member) in members.keys.sorted().enumerated() { record.joinedAtMs[member] = since + Int64(offset) * 60_000 }
        records[details.conversationID] = record
        order.append(details.conversationID)
    }

    private func makeCrowd(_ role: ProposedChat.Role, count: Int) -> Crowd {
        defer { nextCrowd += count }
        return Crowd(role: role, ids: nextCrowd..<(nextCrowd + count))
    }

    /// How many of record's crowd hold one of `roles`, the gone left out.
    private static func crowdCount(_ record: Record, roles: Set<ProposedChat.Role>) -> Int {
        let gone: [Int] = record.crowdGone.compactMap(crowdIndex)
        var total = 0
        for crowd in record.crowd where roles.contains(crowd.role) {
            let left: Int = gone.filter { crowd.ids.contains($0) }.count
            total += crowd.ids.count - left
        }
        return total
    }

    /// A crowd id's index; nil for anyone else.
    private static func crowdIndex(_ profile: String) -> Int? {
        guard profile.hasPrefix(crowdPrefix) else { return nil }
        return Int(profile.dropFirst(crowdPrefix.count))
    }

    /// A crowd person's role in record, if they are still the crowd's.
    private static func crowdRole(of profile: String, in record: Record) -> ProposedChat.Role? {
        guard !record.crowdGone.contains(profile), let index = crowdIndex(profile) else { return nil }
        return record.crowd.first { $0.ids.contains(index) }?.role
    }

    /// A crowd person a write names (#2237): made a member record, as the
    /// seed's named people are, so every write reads one dictionary.
    private func materialize(_ profile: String, in id: String) {
        guard let record = records[id], record.members[profile] == nil,
              let role = Self.crowdRole(of: profile, in: record) else { return }
        records[id]?.crowdGone.insert(profile)
        records[id]?.members[profile] = role
        records[id]?.joinedAtMs[profile] = record.joinedAtMs.values.min() ?? 0
    }

    /// The people of `roles` in record, in the lists' order (#2237): by role
    /// (owner, admins, members, subscribers), the named first within each,
    /// by id, then the crowd.
    private static func people(of record: Record, roles: Set<ProposedChat.Role>) -> [(String, ProposedChat.Role)] {
        let order: [ProposedChat.Role] = [.owner, .admin, .member, .subscriber, .guest]
        return order.filter(roles.contains).flatMap { role -> [(String, ProposedChat.Role)] in
            let named = record.members.filter { $0.value == role }.keys.sorted().map { ($0, role) }
            let crowd = record.crowd.filter { $0.role == role }.flatMap(\.profileIDs)
                .filter { !record.crowdGone.contains($0) }.map { ($0, role) }
            return named + crowd
        }
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

    /// `profile`'s role in `id`, if they are in it.
    func role(of profile: String, in id: String) -> ProposedChat.Role? {
        lock.withLock { records[id]?.members[profile] }
    }

    /// Who a call lets into a conversation, and which (#2230): the viewer
    /// joining or subscribing, or the requester an admin approves. Nil for
    /// any other call.
    static func joiner(of call: ProposedChat.Call) -> (profile: String, conversationID: String)? {
        switch call {
        case let .requestToJoin(viewer, id), let .subscribe(viewer, id):
            return (profile: viewer, conversationID: id)
        case let .answerJoinRequest(_, id, requester, approve) where approve:
            return (profile: requester, conversationID: id)
        default:
            return nil
        }
    }

    func members(of id: String) -> [(profileID: String, role: ProposedChat.Role, joinedAtMs: Int64)] {
        lock.withLock {
            guard let record = records[id] else { return [] }
            return record.members.keys.sorted().map { ($0, record.members[$0]!, record.joinedAtMs[$0] ?? 0) }
        }
    }

    /// Since when `requester` reads conversation `id` (#2217): 0 for a member
    /// (everything), the public-since watermark for an outsider or a
    /// follower of a public one, nil when they can't read it at all — a
    /// private conversation answers an outsider as a missing one, and a
    /// group turned private closes it to its former followers at once.
    func readableSince(_ id: String, for requester: String) -> Int64? {
        lock.withLock {
            guard let record = records[id] else { return nil }
            switch record.members[requester] {
            case .owner?, .admin?, .member?: return 0
            case .subscriber?, .guest?:
                // A channel's subscribers are its audience, whatever its
                // visibility; a group's followers only while it is public.
                if record.details.kind == .channel { return 0 }
                return record.details.visibility == .public ? record.publicSinceMs ?? 0 : nil
            case nil:
                if record.details.viewerState == .invited, requester == viewer { return 0 }
                switch record.details.visibility {
                case .private: return nil
                case .public: return record.publicSinceMs ?? 0
                case .listedOnRequest: return 0
                }
            }
        }
    }

    /// Whether `profile` follows group `id` (#2217).
    func follows(_ profile: String, group id: String) -> Bool {
        lock.withLock { records[id]?.details.kind == .group && records[id]?.members[profile] == .subscriber }
    }

    /// Group `id` turned private by its owner (#2217) — the scripted change
    /// `-mock-group-private-after` makes while the viewer reads it.
    func turnPrivateByOwner(_ id: String, now: Int64) {
        lock.withLock {
            guard let owner = records[id]?.members.first(where: { $0.value == .owner })?.key else { return }
            _ = handle(.setVisibility(viewer: owner, conversationID: id, visibility: .private), now: now)
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
        // A group's followers are its audience, counted apart (#2217): its
        // members are the ones who talk, named or not. Each counter is the
        // records it counts, the crowd's included (#2237), so a list and
        // its counter never disagree.
        record.details.memberCount = talkers + Self.crowdCount(record, roles: [.owner, .admin, .member])
        let audience = record.members.values.filter { $0 == .subscriber || $0 == .guest }.count
        record.details.subscriberCount = audience + Self.crowdCount(record, roles: [.subscriber, .guest])
        return record.details
    }

    /// Whether group `id` has no room left: chat.v1's 500-member cap.
    private func isFull(_ id: String) -> Bool {
        guard let record = records[id], record.details.kind == .group else { return false }
        let talkers = record.members.values.filter { $0 == .owner || $0 == .admin || $0 == .member }.count
        return talkers + Self.crowdCount(record, roles: [.owner, .admin, .member]) >= ProposedChat.groupCap
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
        case let .membersPage(viewer, id, roles, token, limit):
            guard let record = records[id], record.members[viewer] != nil || record.details.visibility != .private else {
                return refused("CHT-1004: conversation not found")
            }
            let all = Self.people(of: record, roles: Set(roles))
            let start = min(max(0, Int(token) ?? 0), all.count)
            let end = min(start + max(1, limit), all.count)
            let earliest = record.joinedAtMs.values.min() ?? 0
            return ProposedChat.Reply(
                members: all[start..<end].map { profile, role in
                    ProposedChat.Member(profileID: profile, role: role, joinedAtMs: record.joinedAtMs[profile] ?? earliest)
                },
                nextPageToken: end < all.count ? String(end) : "", total: all.count
            )
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
            let role = record.members[viewer]
            // A group's follower joins as a member (#2217); anyone else in
            // already is answered as they are.
            let followerJoins = record.details.kind == .group && role == .subscriber
            if role != nil, !followerJoins {
                return ProposedChat.Reply(details: details(id, for: viewer).map { [$0] } ?? [])
            }
            if record.details.kind == .group, isFull(id) { return refused("CHT-1020: this group is full") }
            if record.details.visibility == .public {
                records[id]?.members[viewer] = record.details.kind == .channel ? .subscriber : .member
                records[id]?.joinedAtMs[viewer] = now
                // A channel gains a subscriber; a follower who joins a group
                // leaves its audience for its members.
                if record.details.kind == .channel { records[id]?.details.subscriberCount += 1 }
                if followerJoins { records[id]?.details.subscriberCount -= 1 }
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
            materialize(member, in: id)
            guard manages(viewer, id), records[id]?.members[member] != nil else {
                return refused("CHT-1030: only an owner or an admin changes roles")
            }
            guard role != .owner, records[id]?.members[member] != .owner else {
                return refused("CHT-1033: ownership moves by transfer")
            }
            records[id]?.members[member] = role
            return ProposedChat.Reply()
        case let .remove(viewer, id, member, ban):
            materialize(member, in: id)
            guard manages(viewer, id), member != viewer else { return refused("CHT-1030: only an owner or an admin removes") }
            guard records[id]?.members[member] != .owner else { return refused("CHT-1033: the owner can't be removed") }
            let wasSubscriber = records[id]?.members[member] == .subscriber
            records[id]?.members[member] = nil
            if ban { records[id]?.banned.insert(member) }
            if wasSubscriber { records[id]?.details.subscriberCount -= 1 }
            return ProposedChat.Reply()
        case let .transferOwnership(viewer, id, to):
            materialize(to, in: id)
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
            let was = records[id]?.details.visibility
            records[id]?.details.visibility = visibility
            if visibility == .public, was != .public {
                // Readable by anyone from now on, not before (#2217).
                records[id]?.publicSinceMs = now
            }
            if visibility == .private, was == .public, records[id]?.details.kind == .group {
                // Turned private, a group closes to its followers at once
                // (#2217, `chat.conversation.unpublished`): they are no
                // longer in it, and every read of theirs answers not found.
                let kept = records[id]?.members.filter { $0.value != .subscriber && $0.value != .guest } ?? [:]
                records[id]?.members = kept
                records[id]?.crowd.removeAll { $0.role == .subscriber || $0.role == .guest }
                records[id]?.details.subscriberCount = 0
                records[id]?.publicSinceMs = nil
            }
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
        case let .ownedChannels(viewer, owner):
            return ProposedChat.Reply(details: ownedChannels(of: owner, for: viewer))
        }
    }

    /// The channels `owner` owns, as `viewer` may see them (#2232): only
    /// the ones whose owner they are — an admin's channel stays off the
    /// admin's profile, and a transfer moves it to the new owner's —
    /// someone else's private ones left out (they can't be probed), the
    /// most subscribed first, then by name, so the order holds still
    /// between two reads.
    private func ownedChannels(of owner: String, for viewer: String) -> [ProposedChat.Details] {
        let owned = order.compactMap { id -> ProposedChat.Details? in
            guard let record = records[id], record.details.kind == .channel,
                  record.members[owner] == .owner else { return nil }
            if record.details.visibility == .private, viewer != owner { return nil }
            return details(id, for: viewer)
        }
        return owned.sorted { lhs, rhs in
            if lhs.subscriberCount != rhs.subscriberCount { return lhs.subscriberCount > rhs.subscriberCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
