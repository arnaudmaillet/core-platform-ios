import Connect
import CoreModels
import CoreContracts
import CoreNetworking
import Foundation
import SwiftProtobuf

/// What a DM opening answers in the mock (backend #656, #2212), from the
/// peer's "Who Can Message" setting: it opens, the opener's messages are a
/// request, or it is refused (CHT-1011).
public enum MockDirectAdmission: Sendable, Equatable {
    case open
    case request
    case refused
}

/// Fake of chat.v1.ChatService over the shared dataset. Seeds four direct
/// conversations (viewer ↔ a dataset author) with a short history, persists
/// sent messages, and accepts MarkRead. Members are dataset authors, so profile
/// hydration resolves.
public final class MockChatService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    /// The epoch every seeded timestamp is measured back from, pinned ONCE per
    /// instance. Recomputing `Date()` per `GetHistory` call made two seeds with
    /// the same relative age land microseconds apart — or exactly equal —
    /// depending on timing, so the inbox's ordering jittered between loads.
    private let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    private let store = Store()

    /// conversationID → the other (non-viewer) member.
    ///
    /// `conv-0`/`conv-1`/`conv-2` are with authors the viewer follows — the
    /// active inbox. `conv-0` ends on the viewer's own message (never unread);
    /// `conv-1` and `conv-2` end on an inbound one, so mock mode has TWO
    /// unread conversations. Two matters: with only one, reading it empties
    /// the Unread tab entirely, which hides whether a read row actually
    /// leaves a still-populated list.
    ///
    /// `conv-req-0`..`conv-req-4` are message requests: with authors the
    /// viewer does NOT follow, and never answered — `ListInbox` files them in
    /// REQUESTS until the viewer replies, which moves them to INBOX.
    /// Sixteen active conversations, so the compose picker's Recent section is
    /// full enough to hit its fifteen-row cap and the inbox itself scrolls.
    /// `conv-0`..`conv-11` are with authors the viewer follows; `conv-12`..
    /// `conv-15` are with authors they do NOT follow but HAVE answered — an
    /// answered conversation is never a request, whoever the viewer follows.
    private var otherMember: [String: String] {
        var members: [String: String] = [:]
        for (offset, id) in (Self.requestIDs + Self.hiddenRequestIDs).enumerated() {
            members[id] = dataset.authors[16 + offset].profileID
        }
        for index in 0..<16 {
            members["conv-\(index)"] = dataset.authors[index].profileID
        }
        // DMs opened in this session (`OpenDirectConversation`, #2212).
        for direct in store.openedDirects() {
            members[direct.id] = direct.peer
        }
        return members
    }

    /// The pending requests, and what each one says.
    ///
    /// FIVE, with two arriving live and three sitting in the past — which is
    /// what makes the Requests tab render BOTH of its sections. With every
    /// request the same age the list is one undivided block, and the split that
    /// the badge is supposed to describe has nothing to describe.
    private static let requests: [(id: String, opener: String, closer: String, minutesAgo: Int64)] = [
        ("conv-req-0", "Hi! Loved your shot of the pier 😍 any chance you sell prints?",
         "No pressure either way 🙂", justArrived),
        ("conv-req-1", "Hey, we're putting together a small show next month and I'd love to include your work.",
         "Happy to send over the details.", justArrived + 1),
        ("conv-req-2", "Following you from the print fair — your process posts are great.",
         "Do you ever run workshops? 👀", 3 * 60),
        ("conv-req-3", "We're commissioning covers for a short story collection.",
         "Budget is modest but the brief is open.", 26 * 60),
        ("conv-req-4", "Quick one — what film stock was the harbour series shot on?",
         "Asking for a very jealous friend :blush:", 4 * 24 * 60)
    ]

    private static let requestIDs = requests.map(\.id)

    /// A conversation whose history runs to several pages (#600): this many
    /// messages older than its everyday thread.
    public static let longHistoryConversationID = "conv-5"
    public static let longHistoryOlderCount = 120

    /// Requests the viewer's hidden words caught (#552): `ListInbox` files
    /// them in HIDDEN_REQUESTS, not REQUESTS, until the viewer replies. Two,
    /// so the Hidden requests list shows a list rather than a lone row.
    private static let hiddenRequests: [(id: String, opener: String, closer: String, minutesAgo: Int64)] = [
        ("conv-hidden-0", "Want 10k followers by Friday? DM me for a deal 💸",
         "Limited spots, act fast!!", 50),
        ("conv-hidden-1", "Congrats, you've been selected for a crypto giveaway 🎁",
         "Just send your wallet address to claim.", 2 * 24 * 60)
    ]

    private static let hiddenRequestIDs = hiddenRequests.map(\.id)

    /// Every seeded conversation id, newest activity first, then the DMs
    /// opened in this session (#2212).
    private var conversationIDs: [String] {
        (0..<16).map { "conv-\($0)" } + Self.requestIDs + Self.hiddenRequestIDs
            + store.openedDirects().map(\.id).sorted()
            + book.inboxIDs
    }

    /// The seeded groups and channels (#2213), and the ones created.
    private let book: MockConversationBook
    private let viewer = MockSocialDataset.viewerProfileID

    /// Whether `sender` may message `recipient` (backend #656): with the
    /// recipient's No One, a message is refused (CHT-1011). A narrower
    /// audience turns it into a request on the fleet; not modelled here.
    private let mayMessage: @Sendable (_ sender: String, _ recipient: String) -> Bool
    /// Whether `sender` opening a DM with `recipient` opens it, makes it a
    /// request, or is refused (#2212). Defaults to `mayMessage`: refused or
    /// open, never a request.
    private let admission: @Sendable (_ sender: String, _ recipient: String) -> MockDirectAdmission

    public init(
        dataset: MockSocialDataset,
        mayMessage: @escaping @Sendable (_ sender: String, _ recipient: String) -> Bool = { _, _ in true },
        admission: (@Sendable (_ sender: String, _ recipient: String) -> MockDirectAdmission)? = nil,
        seedsGroups: Bool = false,
        seedsChannels: Bool = false,
        groupGoesPrivateAfter: TimeInterval? = nil
    ) {
        self.dataset = dataset
        book = MockConversationBook(
            viewer: MockSocialDataset.viewerProfileID, authors: dataset.authors.map(\.profileID),
            seedsGroups: seedsGroups, seedsChannels: seedsChannels, now: Int64(Date().timeIntervalSince1970 * 1000)
        )
        self.mayMessage = mayMessage
        self.admission = admission ?? { sender, recipient in mayMessage(sender, recipient) ? .open : .refused }
        // A followed channel joined muted, as every join is (#2230): its
        // posts on its row, out of the Chats badge.
        if seedsChannels {
            store.setMuted(true, until: 0, in: MockConversationBook.mutedChannelID, for: viewer)
        }
        guard seedsGroups else { return }
        // The group the viewer follows sits muted in their inbox, as Follow
        // leaves it (#2217): the app mutes what it follows.
        store.setMuted(true, until: 0, in: MockConversationBook.followedGroupID, for: viewer)
        // `-mock-group-private-after <seconds>` (#2217): its owner turns it
        // private that long after launch — the one other account the mock
        // has, so a follower can watch it close with the thread open.
        if let groupGoesPrivateAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + groupGoesPrivateAfter) { [book] in
                book.turnPrivateByOwner(MockConversationBook.followedGroupID, now: Int64(Date().timeIntervalSince1970 * 1000))
            }
        }
    }

    /// Channel `id` as a showcase's card shows it to the viewer (#2216),
    /// read now: its identity, count, visibility, the viewer's standing —
    /// what a join or a request made here has just changed — and the first
    /// line of its last message. Nil for a conversation that is not a
    /// channel; a channel in no record reads as deleted.
    public func channelEmbed(_ id: String, blocksOwner: (String) -> Bool = { _ in false }) -> ChannelEmbed? {
        let last = book.kind(of: id) == .channel
            ? store.messages(for: id, seed: seedHistory(for: id)).last?.body
            : nil
        let firstLine = last?.split(whereSeparator: \.isNewline).first.map(String.init)
        return book.channelEmbed(id, for: viewer, lastMessage: firstLine, blocksOwner: blocksOwner)
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/chat.v1.ChatService/ListSubscriptions") { [self] (_: Chat_V1_ListSubscriptionsRequest) in
            var response = Chat_V1_ListSubscriptionsResponse()
            response.conversationIds = conversationIDs
            return .success(response)
        }
        // One folder of the viewer's inbox, newest activity first, page by
        // page (#593): at most `limit` (clamped to 100; unset reads as 20)
        // from where `page_token` left off. The token is an offset here —
        // opaque to the client either way.
        bff.register(path: "/chat.v1.ChatService/ListInbox") { [self] (request: Chat_V1_ListInboxRequest) in
            let entries = inboxEntries(in: request.folder)
            let size = request.limit > 0 ? Int(min(request.limit, 100)) : 20
            let start = min(max(Int(request.pageToken) ?? 0, 0), entries.count)
            let end = min(start + size, entries.count)
            var response = Chat_V1_ListInboxResponse()
            response.entries = Array(entries[start..<end])
            response.nextPageToken = end < entries.count ? String(end) : ""
            return .success(response)
        }
        // Groups' and channels' needs (#2213), until chat.v1 carries them.
        bff.register(path: ProposedChat.path) { [self] (request: Google_Protobuf_StringValue) -> Result<Google_Protobuf_StringValue, ConnectError> in
            guard let call = try? ProposedChat.unwrap(ProposedChat.Call.self, from: request) else {
                return .failure(ConnectError(code: .invalidArgument, message: "unreadable call"))
            }
            let joiner = MockConversationBook.joiner(of: call)
            let wasIn = joiner.map { book.role(of: $0.profile, in: $0.conversationID) != nil } ?? true
            guard let reply = try? ProposedChat.wrap(book.answer(call, now: Int64(Date().timeIntervalSince1970 * 1000))) else {
                return .failure(ConnectError(code: .invalidArgument, message: "unreadable call"))
            }
            // A channel joins MUTED (#2230, WhatsApp's rule, for #995): a
            // subscriber's posts reach their inbox without a push until they
            // turn notifications on — joined, subscribed, or approved. A
            // channel its owner creates is not muted: nobody joins it.
            if let joiner, !wasIn, book.kind(of: joiner.conversationID) == .channel,
               book.role(of: joiner.profile, in: joiner.conversationID) == .subscriber {
                store.setMuted(true, until: 0, in: joiner.conversationID, for: joiner.profile)
            }
            return .success(reply)
        }
        bff.register(path: "/chat.v1.ChatService/ListMembers") { [self] (request: Chat_V1_ListMembersRequest) -> Result<Chat_V1_ListMembersResponse, ConnectError> in
            var response = Chat_V1_ListMembersResponse()
            if book.kind(of: request.conversationID) != nil {
                response.members = book.members(of: request.conversationID).map { row in
                    var view = member(row.profileID, lastRead: row.profileID == viewer ? viewerLastRead(in: request.conversationID) : "")
                    view.joinedAtMs = row.joinedAtMs
                    view.role = switch row.role {
                    case .owner: .owner
                    case .admin: .admin
                    case .member: .member
                    case .subscriber: .subscriber
                    case .guest: .guest
                    }
                    return view
                }
                return .success(response)
            }
            // The viewer's member view carries `last_read`, which is what the
            // inbox derives its Unread tab from — so it has to be real state,
            // not a blank field, and MarkRead below has to move it.
            response.members = [
                member(viewer, lastRead: viewerLastRead(in: request.conversationID)),
                member(otherMember[request.conversationID] ?? viewer)
            ]
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/GetHistory") { [self] (request: Chat_V1_GetHistoryRequest) -> Result<Chat_V1_GetHistoryResponse, ConnectError> in
            var response = Chat_V1_GetHistoryResponse()
            var all = store.messages(for: request.conversationID, seed: seedHistory(for: request.conversationID))
            // A group's or a channel's history as the requester may read it
            // (#2217): a private one answers an outsider — a former follower
            // included — as a missing one; an outsider or a follower of a
            // public one reads from its public-since watermark.
            if book.kind(of: request.conversationID) != nil {
                guard let since = book.readableSince(request.conversationID, for: request.requesterID) else {
                    return .failure(ConnectError(code: .notFound, message: "CHT-1004: conversation not found"))
                }
                all.removeAll { $0.createdAtMs < since }
            }
            // A real page: the newest `limit` messages, not a special case for
            // 1. The inbox now asks for a window rather than a single message,
            // because it counts the unread tail inside it — answering that with
            // the whole history would make the mock the only place the count is
            // unbounded.
            //
            // And paged (#600): `page_token` reads the `limit` messages just
            // OLDER than the last page, as chat.v1 does, with a token while
            // there are more. The token is an index here — opaque to the client.
            let end = min(max(Int(request.pageToken) ?? all.count, 0), all.count)
            let start = request.limit > 0 ? max(0, end - Int(request.limit)) : 0
            response.messages = Array(all[start..<end])
            response.nextPageToken = start > 0 ? String(start) : ""
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/SendMessage") { [self] (request: Chat_V1_SendMessageRequest) -> Result<Chat_V1_SendMessageResponse, ConnectError> in
            let recipient = otherMember[request.conversationID]
                ?? store.members(of: request.conversationID).first { $0 != request.senderID }
            if let recipient, !mayMessage(request.senderID, recipient) {
                return .failure(ConnectError(code: .permissionDenied, message: "CHT-1011: this account doesn't take messages"))
            }
            // A channel's owner and admins post; its subscribers read (#2215).
            if book.kind(of: request.conversationID) == .channel,
               !book.publishes(request.senderID, in: request.conversationID) {
                return .failure(ConnectError(
                    code: .permissionDenied, message: "CHT-1034: only a channel's owner and admins post"
                ))
            }
            // A request waiting for its answer takes one message (#656).
            if store.pendingRequester(of: request.conversationID) == request.senderID,
               store.messages(for: request.conversationID, seed: []).contains(where: { $0.senderID == request.senderID }) {
                return .failure(ConnectError(
                    code: .failedPrecondition, message: "CHT-1010: a message request is waiting for its answer"
                ))
            }
            // The key's shape, as chat.v1 checks it (#795): 8–64 of
            // letters, digits, `-`, `_`; empty is no deduplication.
            if !request.idempotencyKey.isEmpty, !IdempotencyKey.isValid(request.idempotencyKey) {
                return .failure(ConnectError(code: .invalidArgument, message: "CHT-2010: invalid idempotency_key"))
            }
            let existing = store.messages(
                for: request.conversationID, seed: seedHistory(for: request.conversationID)
            )
            let id = store.append(request, after: existing.map(\.createdAtMs).max() ?? 0)
            var response = Chat_V1_SendMessageResponse()
            response.messageID = id
            return .success(response)
        }
        // Persisted, so opening a thread genuinely clears its unread state and
        // the Unread tab can empty out (and disappear) for real.
        bff.register(path: "/chat.v1.ChatService/MarkRead") { [self] (request: Chat_V1_MarkReadRequest) in
            store.markRead(request.messageID, in: request.conversationID, for: request.memberID)
            return .success(Chat_V1_CommandResponse())
        }
        // The pair's one DM (#656, #2212): a seeded conversation with the
        // peer, else the one opened before, else a new one — unless the peer
        // takes messages from no one (CHT-1011). Opened under the peer's
        // settings: the opener's messages may be a request.
        bff.register(path: "/chat.v1.ChatService/OpenDirectConversation") { [self] (request: Chat_V1_OpenDirectConversationRequest) -> Result<Chat_V1_OpenDirectConversationResponse, ConnectError> in
            var response = Chat_V1_OpenDirectConversationResponse()
            if request.profileID == viewer,
               let seeded = conversationIDs.first(where: { otherMember[$0] == request.peerID && !store.isOpenedDirect($0) }) {
                // Opening a request sent to the viewer accepts it.
                if (Self.requestIDs + Self.hiddenRequestIDs).contains(seeded) { store.answer(seeded, accept: true) }
                response.conversationID = seeded
                return .success(response)
            }
            if let opened = store.openedDirect(between: request.profileID, and: request.peerID) {
                response.conversationID = opened
                response.request = store.pendingRequester(of: opened) == request.profileID
                return .success(response)
            }
            switch admission(request.profileID, request.peerID) {
            case .refused:
                return .failure(ConnectError(code: .permissionDenied, message: "CHT-1011: this account doesn't take messages"))
            case .open:
                response.conversationID = store.openDirect(request.profileID, with: request.peerID, asRequest: false)
            case .request:
                response.conversationID = store.openDirect(request.profileID, with: request.peerID, asRequest: true)
                response.request = true
            }
            return .success(response)
        }
        // The viewer answers a request to them (#2212): accepted, it is
        // filed in the INBOX; declined, it leaves REQUESTS.
        bff.register(path: "/chat.v1.ChatService/RespondToMessageRequest") { [self] (request: Chat_V1_RespondToMessageRequestRequest) in
            store.answer(request.conversationID, accept: request.accept)
            return .success(Chat_V1_CommandResponse())
        }
        bff.register(path: "/chat.v1.ChatService/CreateConversation") { [self] (_: Chat_V1_CreateConversationRequest) in
            var response = Chat_V1_CreateConversationResponse()
            response.conversationID = store.newConversationID()
            return .success(response)
        }
        // Remembered, so a created conversation knows who the message is for.
        bff.register(path: "/chat.v1.ChatService/JoinAsMember") { [self] (request: Chat_V1_JoinAsMemberRequest) -> Result<Chat_V1_CommandResponse, ConnectError> in
            store.join(request.profileID, to: request.conversationID)
            return .success(Chat_V1_CommandResponse())
        }
        // Remembered per member (#719), so the thread's bell and the inbox's
        // mute survive a reload as they do on the fleet.
        bff.register(path: "/chat.v1.ChatService/MuteConversation") { [self] (request: Chat_V1_MuteConversationRequest) in
            store.setMuted(
                request.muted, until: request.untilMs, in: request.conversationID, for: request.memberID
            )
            return .success(Chat_V1_CommandResponse())
        }
        bff.register(path: "/chat.v1.ChatService/Subscribe") { (_: Chat_V1_SubscribeRequest) in
            .success(Chat_V1_CommandResponse())
        }
    }

    /// The viewer's conversations in `folder`, as `ListInbox` lists them: a
    /// request is one the viewer has never written in; everything else is the
    /// INBOX. Unread as the server reads it — the last message is someone
    /// else's and past the viewer's cursor; a request is unread until answered.
    private func inboxEntries(in folder: Chat_V1_InboxFolder) -> [Chat_V1_InboxEntryView] {
        let members = otherMember
        return conversationIDs.compactMap { id -> Chat_V1_InboxEntryView? in
            let history = store.messages(for: id, seed: seedHistory(for: id))
            // A DM opened here is listed once it holds a message.
            if store.isOpenedDirect(id), history.isEmpty { return nil }
            let answer = store.answer(of: id)
            if answer == false { return nil }
            let isRequest = (Self.requestIDs + Self.hiddenRequestIDs).contains(id)
                && !history.contains { $0.senderID == viewer } && answer != true
            let isHidden = Self.hiddenRequestIDs.contains(id)
            switch folder {
            case .inbox: guard !isRequest else { return nil }
            case .requests: guard isRequest, !isHidden else { return nil }
            case .hiddenRequests: guard isRequest, isHidden else { return nil }
            default: return nil
            }
            var entry = Chat_V1_InboxEntryView()
            entry.conversationID = id
            switch book.kind(of: id) {
            case .group?: entry.kind = .group
            case .channel?: entry.kind = .channel
            default:
                entry.kind = .direct
                entry.peerID = members[id] ?? ""
            }
            // The viewer's own request, waiting for the peer (#2212).
            entry.request = store.pendingRequester(of: id) == viewer
            let latest = history.max { $0.createdAtMs < $1.createdAtMs }
            entry.lastActivityMs = latest?.createdAtMs ?? nowMs
            entry.muted = store.isMuted(id, for: viewer)
            if let latest {
                var preview = Chat_V1_MessagePreview()
                preview.messageID = latest.messageID
                preview.senderID = latest.senderID
                preview.contentType = latest.contentType
                // A voice message's preview is the server's own (backend#993).
                preview.preview = latest.contentType == .media
                    ? MockVoiceCatalog.preview(forReference: latest.mediaRef) ?? String(latest.body.prefix(100))
                    : String(latest.body.prefix(100))
                entry.lastMessage = preview
                entry.unread = latest.senderID != viewer && (isRequest || viewerLastRead(in: id) != latest.messageID)
            }
            return entry
        }
        .sorted {
            $0.lastActivityMs != $1.lastActivityMs
                ? $0.lastActivityMs > $1.lastActivityMs
                : $0.conversationID < $1.conversationID
        }
    }

    /// Where the viewer's read cursor sits: what `MarkRead` recorded, or — for
    /// a thread they have never opened in this session — their own newest
    /// message.
    ///
    /// ⚠️ The fallback is what makes the seeded unread COUNTS realistic. With a
    /// blank cursor every inbound message in a thread is unread, including ones
    /// the viewer demonstrably read: the seeds have them REPLYING mid-thread,
    /// so a blank cursor made a conversation they answered read as two unread
    /// messages rather than the one that arrived after their reply. Sending is
    /// reading, and the fixture now says so.
    private func viewerLastRead(in conversationID: String) -> String {
        let stored = store.lastRead(in: conversationID, for: viewer)
        guard stored.isEmpty else { return stored }
        let all = store.messages(for: conversationID, seed: seedHistory(for: conversationID))
        return all.last { $0.senderID == viewer }?.messageID ?? ""
    }

    private func member(_ profileID: String, lastRead: String = "") -> Chat_V1_MemberView {
        var view = Chat_V1_MemberView()
        view.profileID = profileID
        view.lastRead = lastRead
        return view
    }

    /// "Minutes ago" for a message that must read as having arrived AFTER the
    /// inbox opened — a negative age, so its timestamp lands ahead of the epoch
    /// every other seed counts back from.
    ///
    /// ⚠️ This is what makes the All tab's badge reachable in mock mode. That
    /// badge counts arrivals since the viewer last left the tab, and on a cold
    /// launch the baseline is the moment the screen opened — so a fixture whose
    /// every message predates the launch can only ever total zero, and the
    /// feature looks broken when it is the data that is silent. Three
    /// conversations therefore arrive a few minutes into the future, which
    /// covers the seconds between launch and first render whatever the
    /// simulator is doing, and renders as "now" (`RelativeAgeFormatter` clamps a
    /// future date rather than counting backwards).
    private static let justArrived: Int64 = -5

    /// A group's history with several senders, a channel's its owner's and
    /// admins' posts (#2213).
    private func bookHistory(for id: String, minute: Int64) -> [Chat_V1_MessageView] {
        let members = book.members(of: id)
        // A group's followers read; they never write in it (#2217).
        let others = members.filter { $0.role != .subscriber && $0.role != .guest }.map(\.profileID).filter { $0 != viewer }
        func pick(_ index: Int) -> String { others.isEmpty ? viewer : others[index % others.count] }
        let publishers = members.filter { $0.role == .owner || $0.role == .admin }.map(\.profileID)
        let lines: [(String, String, Int64)]
        switch (id, book.kind(of: id)) {
        case ("grp-hike", _):
            lines = [(pick(0), "Forecast says clear until noon ☀️", 180), (pick(1), "I can drive, room for three", 175),
                     (viewer, "Perfect, meet at the station at 7?", 170), (pick(2), "7 works", 160),
                     (pick(1), "Bringing the good coffee", 30), (pick(3), "See you there 🥾", 12)]
        case ("grp-studio", _):
            lines = [(pick(0), "New paper arrived", 300), (viewer, "Finally!", 290), (pick(1), "Test prints tomorrow?", 45)]
        case ("grp-printfair", _):
            lines = [(pick(0), "Rota is up for Saturday", 600), (pick(1), "I'll take the morning shift", 590),
                     (pick(2), "Who has the card reader?", 400), (viewer, "Me, I'll bring it", 395),
                     (pick(3), "Van leaves at 6:30 sharp", 90)]
        case ("grp-nightwalk", _):
            lines = [(pick(0), "Thinking Friday, after sunset", 200), (pick(1), "Tripods or handheld?", 150)]
        case (MockConversationBook.publicGroupID, _):
            lines = [(pick(0), "Next clean: Sunday 10:00 at the north jetty", 1_400), (pick(1), "I'll bring the litter pickers", 1_300),
                     (pick(2), "Tide is low at 11, perfect timing", 600), (pick(3), "Count me in, with two friends", 240),
                     (pick(4), "Last time we filled 38 bags 💪", 35)]
        case (MockConversationBook.fullGroupID, _):
            lines = [(pick(0), "Swapping a Durst enlarger for fibre paper", 900), (pick(1), "Anyone got spare fixer?", 400),
                     (pick(2), "Meetup at the lab on Saturday", 50)]
        case (MockConversationBook.followedGroupID, _):
            lines = [(pick(0), "Thursday: the old boathouse, 18:30", 2_000), (pick(1), "Bringing the new watercolour set", 900),
                     (pick(2), "Light was lovely tonight", 120)]
        case (MockConversationBook.fourFacesGroupID, _):
            lines = [(pick(0), "The 6:40 tram is cancelled again", 80), (viewer, "Taking the bus then", 75),
                     (pick(1), "Save me a seat", 20)]
        case (MockConversationBook.fiveFacesGroupID, _):
            lines = [(viewer, "Issue 4 deadline is Friday", 900), (pick(2), "Mine's at the printer", 600),
                     (pick(3), "Can someone bring the long stapler?", 240)]
        case (MockConversationBook.largeGroupID, _):
            lines = [(pick(0), "Field is booked for the 14th", 3_000), (pick(1), "Wind forecast looks perfect", 1_500),
                     (pick(2), "Who's on the spare lines stall?", 400)]
        // A channel created in this session starts empty: it is new (#2215).
        case (_, .channel?) where !id.contains("-new-"):
            let author = publishers.first ?? pick(0)
            lines = [(author, "Tonight's light: the pier at 19:42, gold all the way down.", 1_500),
                     (author, "Thanks for the kind words on yesterday's post 🙏", 700),
                     (author, "New series starts Monday.", 60)]
        default:
            lines = []
        }
        return lines.enumerated().map { index, spec in
            var view = Chat_V1_MessageView()
            view.messageID = "\(id)-m\(index)"
            view.senderID = spec.0
            view.body = spec.1
            view.createdAtMs = nowMs - spec.2 * minute
            return view
        }
    }

    private func seedHistory(for conversationID: String) -> [Chat_V1_MessageView] {
        let other = otherMember[conversationID] ?? viewer
        let minute: Int64 = 60_000
        // (sender, body, minutesAgo). conv-0 is the dense thread-screen seed:
        // two day sections, same-sender runs (grouped bubbles), a long-wrap
        // paragraph, and back-to-back turnarounds. conv-1 stays short.
        let morning: Int64 = 25 * 60
        let midday: Int64 = 24 * 60 + 30
        // A DM opened this session (#2212) starts empty: it is new.
        if store.isOpenedDirect(conversationID) { return [] }
        // A group's or a channel's own (#2213).
        if book.kind(of: conversationID) != nil { return bookHistory(for: conversationID, minute: minute) }
        // Request threads are inbound-only and unanswered by construction —
        // a viewer reply seeded here would answer the request and file it in
        // the INBOX instead.
        if let request = (Self.requests + Self.hiddenRequests).first(where: { $0.id == conversationID }) {
            let inbound: [(String, String, Int64)] = [
                (other, request.opener, request.minutesAgo + 2),
                (other, request.closer, request.minutesAgo)
            ]
            return inbound
                .enumerated()
                .map { index, spec in
                    var view = Chat_V1_MessageView()
                    view.messageID = "\(conversationID)-m\(index)"
                    view.senderID = spec.0
                    view.body = spec.1
                    view.createdAtMs = nowMs - spec.2 * minute
                    return view
                }
        }
        if conversationID == "conv-2" {
            let inbound: [(String, String, Int64)] = [
                (viewer, "Sent you the venue list ✅", 200),
                (other, "Perfect, thanks! One more thing —", Self.justArrived + 1),
                (other, "can you make Thursday instead? 🥺🙏", Self.justArrived)
            ]
            return inbound.enumerated().map { index, spec in
                var view = Chat_V1_MessageView()
                view.messageID = "\(conversationID)-m\(index)"
                view.senderID = spec.0
                view.body = spec.1
                view.createdAtMs = nowMs - spec.2 * minute
                return view
            }
        }
        // `conv-3`..`conv-15`: short, varied threads. Those with a peer the
        // viewer does not follow end on the VIEWER's message, which is what
        // keeps them in the active inbox rather than Requests.
        if let index = Int(conversationID.dropFirst("conv-".count)), index >= 3 {
            let answered = index >= 12
            let openers = [
                "Are we still on for Thursday? 🤞",
                "Sent you the files 👍 :lol:",
                "That place you mentioned — what was it called?",
                "Congrats on the launch!! 🎉🎉🎉🥳🎊",
                "Any chance you're free later this week?",
                "Just saw your post, that light is unreal 😍",
                "Thanks again for yesterday 🙏✨"
            ]
            let replies = [
                "Yep, works for me",
                "Got them, thanks! 🙌",
                "I'll dig out the link",
                "Appreciate it 🙏",
                "Let me check and come back to you 🫡"
            ]
            // Staggered so the inbox (and Recent) has a real recency order
            // rather than a block of identical timestamps.
            let base = Int64(index) * 37 + 20
            var thread: [(String, String, Int64)] = [
                (other, openers[index % openers.count], base + 12),
                (viewer, replies[index % replies.count], base + 6)
            ]
            // The LONG history (#600): older than a page reaches, so the
            // thread pages upward in mock mode. Before the opener, numbered so
            // a page boundary can be read off the screen.
            if conversationID == Self.longHistoryConversationID {
                let older = (0..<Self.longHistoryOlderCount).map { position -> (String, String, Int64) in
                    let sender = position.isMultiple(of: 3) ? viewer : other
                    let line = openers[position % openers.count]
                    let age = base + 12 + Int64(Self.longHistoryOlderCount - position) * 20
                    return (sender, "#\(position + 1) \(line)", age)
                }
                thread = older + thread
            }
            if !answered {
                // `conv-3` lands its reply as a live arrival; the rest sit in
                // the past. Three arrivals total, so the All badge reads "3"
                // out of the box and the rows under it say which three.
                //
                // The closing line varies by thread, so the inbox's previews
                // are not a column of identical thumbs: most carry emotes, one
                // a run, a couple plain text.
                let closers = [
                    "👍", "haha perfect :lmao:", "😂😂😂😂😂", "ok deal", "sounds good",
                    "🔥🔥", "love that 🥰", "see you there", "yesss"
                ]
                thread.append((other, closers[index % closers.count], index == 3 ? Self.justArrived : base))
            }
            // `conv-4` is the BURST: one peer talking into the silence, which
            // is the only seeded state that pushes a row's unread count into
            // two digits. Without it every avatar badge is a single digit and
            // the pill's widening — the whole reason it is a capsule and not a
            // circle — goes unexercised.
            if index == 4 {
                let burst = [
                    "Actually, one more thing 😅", "Sorry, several more things",
                    "The venue wants a deposit by Friday :money:", "And a rider",
                    "Do we have a rider? 🤔", "I'll assume no 😂😂😂😂😂😂",
                    "Also parking is a nightmare 😩", "Bring cash for it",
                    "Load-in is 4pm sharp ⏰", "They were very firm about that 💀"
                ]
                for (offset, body) in burst.enumerated() {
                    thread.append((other, body, base - Int64(offset) - 1))
                }
            }
            return thread.enumerated().map { position, spec in
                var view = Chat_V1_MessageView()
                view.messageID = "\(conversationID)-m\(position)"
                view.senderID = spec.0
                view.body = spec.1
                view.createdAtMs = nowMs - spec.2 * minute
                return view
            }
        }
        let specs: [(String, String, Int64)] = conversationID == "conv-0"
            ? [
                (other, "Morning! Standup moved to 9:30 today ☕", morning),
                (other, "Room 4 this time", morning - 1),
                (other, "And bring the tab bar demo if it's ready 🙏", morning - 2),
                (viewer, "👍 on my way", morning - 4),
                (viewer, "Demo's ready — pushed the branch last night", morning - 5),
                (other, "Saw it. The thread screen rebuild is next, right? The list one is starting to feel very 2015.", midday),
                (viewer, "Yep, Telegram-style bubbles, day chips, glass input bar — the works. Native UIKit only though, no custom layout engine.", midday - 10),
                (other, "Bold claim 😂😂😂😂😂😂", midday - 11),
                (viewer, "Watch me 😎", midday - 15),
                (other, "Hey! Did you see the new build? 👀", 60),
                (viewer, "Yeah, shipping it today 🚀", 58),
                (viewer, "Just cleaning up the last QA notes", 57),
                (other, "Nice — ping me when it's live", 55),
                (other, "No rush, I'm in reviews all morning anyway :lol:", 54),
                (viewer, "Will do", 12)
            ]
            : [
                (other, "Hey! Did you see the new build? 👀", 60),
                (viewer, "Yeah, shipping it today 🚀", 58),
                (other, "Nice — ping me when it's live 🎉", Self.justArrived)
            ]
        // Seeded threaded replies (message index → the index it answers), so
        // the quoted-reply rendering is present in the dense demo thread
        // without having to compose one. conv-0 only.
        let replyLinks: [Int: Int] = conversationID == "conv-0" ? [6: 5, 8: 7] : [:]
        // A received PHOTO (#681): "Room 4 this time" is its caption, so the
        // thread draws a media message on a cold launch. conv-0 only.
        let photoAt: Int? = conversationID == "conv-0" ? 1 : nil
        let texts = specs.enumerated().map { index, spec in
            let (sender, body, minutesAgo) = spec
            var view = Chat_V1_MessageView()
            view.messageID = "\(conversationID)-m\(index)"
            view.senderID = sender
            view.body = body
            view.createdAtMs = nowMs - minutesAgo * minute
            if let target = replyLinks[index] { view.replyTo = "\(conversationID)-m\(target)" }
            if index == photoAt, let reference = Self.seededPhotoReference {
                view.contentType = .media
                view.mediaRef = reference
            } else {
                view.contentType = .text
            }
            return view
        }
        // In time order: a page is the newest `limit` by POSITION.
        return (texts + Self.seededVoices(in: conversationID, other: other, viewer: viewer, now: nowMs, minute: minute))
            .sorted { $0.createdAtMs < $1.createdAtMs }
    }

    /// Voice messages for the thread's voice bubble (#2103, #2104): in conv-0
    /// a received short one (unplayed), a received long one and one of the
    /// viewer's; in conv-1 two received back to back (autoplay). Each older
    /// than its thread's last message, so the inbox rows read as before.
    static func seededVoices(
        in conversationID: String, other: String, viewer: String, now nowMs: Int64, minute: Int64
    ) -> [Chat_V1_MessageView] {
        let seeds: [(sender: String, voice: String, minutesAgo: Int64)] = switch conversationID {
        case "conv-0": [(other, "voice-short", 50), (other, "voice-long", 49), (viewer, "voice-mine", 48)]
        case "conv-1": [(other, "voice-pair1", 59), (other, "voice-pair2", 59)]
        default: []
        }
        return seeds.enumerated().compactMap { index, seed in
            guard let reference = MockVoiceCatalog.shared.reference(voiceID: seed.voice) else { return nil }
            var view = Chat_V1_MessageView()
            view.messageID = "\(conversationID)-v\(index)"
            view.senderID = seed.sender
            view.contentType = .media
            view.mediaRef = reference
            // Back to back: a second apart.
            view.createdAtMs = nowMs - seed.minutesAgo * minute + Int64(index) * 1_000
            return view
        }
    }

    /// A catalog photo as the client's `ChatMediaRef` writes one
    /// (`cpmedia://v1?kind=image&url=…&w=…&h=…`).
    static var seededPhotoReference: String? {
        // The single-photo ordinal after every post's (`MockSocialDataset
        // .Ordinals`). Round the pool, it may be a post's picture too: one
        // media may serve several (the owner, 2026-10-31).
        guard let photo = MockPhotoCatalog.shared.singlePhoto(
            forOrdinal: MockSocialDataset.arrivalSingleBase + 1
        ) else { return nil }
        let media = photo.media
        let url = media.url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? media.url
        return "cpmedia://v1?kind=image&url=\(url)&w=\(media.width)&h=\(media.height)"
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String: [Chat_V1_MessageView]] = [:]
        /// "sender|conversation|key" → the message that key first stored.
        private var keyed: [String: (messageID: String, atMs: Int64)] = [:]
        /// How long a key names its first message (chat.v1: 24 hours).
        static let keyWindowMs: Int64 = 24 * 60 * 60 * 1000
        private var createdCount = 0
        /// conversationID → memberID → last read message id.
        private var readCursors: [String: [String: String]] = [:]

        func lastRead(in conversationID: String, for memberID: String) -> String {
            lock.withLock { readCursors[conversationID]?[memberID] ?? "" }
        }

        func markRead(_ messageID: String, in conversationID: String, for memberID: String) {
            guard !messageID.isEmpty else { return }
            lock.withLock { readCursors[conversationID, default: [:]][memberID] = messageID }
        }

        private var joined: [String: [String]] = [:]
        /// conversationID → member → muted until (ms since 1970; 0 is "until
        /// turned back on").
        private var mutes: [String: [String: Int64]] = [:]

        func setMuted(_ muted: Bool, until: Int64, in conversationID: String, for memberID: String) {
            lock.withLock {
                if muted { mutes[conversationID, default: [:]][memberID] = until } else { mutes[conversationID]?[memberID] = nil }
            }
        }

        /// Muted, and the mute not yet expired (#729).
        func isMuted(_ conversationID: String, for memberID: String) -> Bool {
            lock.withLock {
                guard let until = mutes[conversationID]?[memberID] else { return false }
                return until == 0 || until > Int64(Date().timeIntervalSince1970 * 1000)
            }
        }

        func join(_ member: String, to conversationID: String) {
            lock.withLock {
                if joined[conversationID]?.contains(member) != true { joined[conversationID, default: []].append(member) }
            }
        }

        func members(of conversationID: String) -> [String] {
            lock.withLock { joined[conversationID] ?? [] }
        }

        /// DMs opened through `OpenDirectConversation` (#2212): id → the
        /// opener and the peer; and the ones whose opener's messages are a
        /// request still waiting.
        private var directs: [String: (opener: String, peer: String)] = [:]
        private var pendingRequests: [String: String] = [:]
        /// Requests to the viewer they answered: true accepted, false declined.
        private var answers: [String: Bool] = [:]

        func openedDirects() -> [(id: String, peer: String)] {
            lock.withLock { directs.map { (id: $0.key, peer: $0.value.peer) } }
        }

        func isOpenedDirect(_ id: String) -> Bool { lock.withLock { directs[id] != nil } }

        func openedDirect(between one: String, and other: String) -> String? {
            lock.withLock {
                directs.first { Set([$0.value.opener, $0.value.peer]) == Set([one, other]) }?.key
            }
        }

        func openDirect(_ opener: String, with peer: String, asRequest: Bool) -> String {
            lock.withLock {
                let id = "dm-\(directs.count + 1)"
                directs[id] = (opener, peer)
                joined[id] = [opener, peer]
                if asRequest { pendingRequests[id] = opener }
                return id
            }
        }

        func pendingRequester(of id: String) -> String? { lock.withLock { pendingRequests[id] } }

        func answer(_ id: String, accept: Bool) { lock.withLock { answers[id] = accept } }

        func answer(of id: String) -> Bool? { lock.withLock { answers[id] } }

        func newConversationID() -> String {
            lock.withLock {
                createdCount += 1
                return "conv-created-\(createdCount)"
            }
        }

        func messages(for conversationID: String, seed: [Chat_V1_MessageView]) -> [Chat_V1_MessageView] {
            lock.withLock { seed + (sent[conversationID] ?? []) }
        }

        /// Appends at `now` — or one millisecond past the newest message there
        /// already is, whichever is later.
        ///
        /// ⚠️ The clamp is not paranoia. Some conversations are seeded as having
        /// arrived a few minutes into the FUTURE (see `justArrived`, which is
        /// what lets the All tab's badge have anything to count on a cold
        /// launch), and a reply stamped with the wall clock would sort BEFORE
        /// the message it is answering. Sending something and watching it land
        /// second-from-last is a bug in any inbox; a mock that produces it is a
        /// mock that teaches the wrong thing.
        ///
        /// ⚠️ **A REPEATED KEY IS THE FIRST MESSAGE, NOT A SECOND (#795).** As
        /// chat.v1 does: the same `idempotency_key` from the same sender in
        /// the same conversation within 24 hours stores nothing and answers
        /// the id the first send stored — what a retry after a lost answer
        /// relies on. (The fleet's ABORTED while the first is still in flight
        /// has no window here: a mock call is answered whole.)
        func append(_ request: Chat_V1_SendMessageRequest, after newest: Int64) -> String {
            lock.withLock {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let scope = "\(request.senderID)|\(request.conversationID)|\(request.idempotencyKey)"
                if !request.idempotencyKey.isEmpty, let first = keyed[scope], nowMs - first.atMs < Self.keyWindowMs {
                    return first.messageID
                }
                let id = "\(request.conversationID)-sent-\(sent[request.conversationID]?.count ?? 0)"
                var view = Chat_V1_MessageView()
                view.messageID = id
                view.senderID = request.senderID
                view.body = request.body
                // Kept as sent (#681): a MEDIA message comes back with its
                // reference, the way chat.v1 stores it.
                view.contentType = request.contentType
                view.mediaRef = request.mediaRef
                view.replyTo = request.replyTo
                view.createdAtMs = max(nowMs, newest + 1)
                sent[request.conversationID, default: []].append(view)
                if !request.idempotencyKey.isEmpty { keyed[scope] = (id, nowMs) }
                return id
            }
        }
    }
}
