import Connect
import CoreContracts
import Foundation

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
    /// `conv-req-0`/`conv-req-1` are with authors the viewer does NOT follow
    /// and has never answered, which is exactly what `MessageRequestPolicy`
    /// partitions into the Requests tab.
    /// Sixteen active conversations, so the compose picker's Recent section is
    /// full enough to hit its fifteen-row cap and the inbox itself scrolls.
    /// `conv-0`..`conv-11` are with authors the viewer follows; `conv-12`..
    /// `conv-15` are with authors they do NOT follow but HAVE answered, which
    /// keeps them out of Requests by the other half of the partition rule.
    private var otherMember: [String: String] {
        var members: [String: String] = [
            "conv-req-0": dataset.authors[16].profileID,
            "conv-req-1": dataset.authors[17].profileID
        ]
        for index in 0..<16 {
            members["conv-\(index)"] = dataset.authors[index].profileID
        }
        return members
    }

    /// Every seeded conversation id, newest activity first.
    private var conversationIDs: [String] {
        (0..<16).map { "conv-\($0)" } + ["conv-req-0", "conv-req-1"]
    }
    private let viewer = MockSocialDataset.viewerProfileID

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/chat.v1.ChatService/ListSubscriptions") { [self] (_: Chat_V1_ListSubscriptionsRequest) in
            var response = Chat_V1_ListSubscriptionsResponse()
            response.conversationIds = conversationIDs
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/ListMembers") { [self] (request: Chat_V1_ListMembersRequest) in
            var response = Chat_V1_ListMembersResponse()
            // The viewer's member view carries `last_read`, which is what the
            // inbox derives its Unread tab from — so it has to be real state,
            // not a blank field, and MarkRead below has to move it.
            response.members = [
                member(viewer, lastRead: viewerLastRead(in: request.conversationID)),
                member(otherMember[request.conversationID] ?? viewer)
            ]
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/GetHistory") { [self] (request: Chat_V1_GetHistoryRequest) in
            var response = Chat_V1_GetHistoryResponse()
            let all = store.messages(for: request.conversationID, seed: seedHistory(for: request.conversationID))
            // A real page: the newest `limit` messages, not a special case for
            // 1. The inbox now asks for a window rather than a single message,
            // because it counts the unread tail inside it — answering that with
            // the whole history would make the mock the only place the count is
            // unbounded.
            response.messages = request.limit > 0 ? Array(all.suffix(Int(request.limit))) : all
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/SendMessage") { [self] (request: Chat_V1_SendMessageRequest) in
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
        bff.register(path: "/chat.v1.ChatService/CreateConversation") { [self] (_: Chat_V1_CreateConversationRequest) in
            var response = Chat_V1_CreateConversationResponse()
            response.conversationID = store.newConversationID()
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/JoinAsMember") { (_: Chat_V1_JoinAsMemberRequest) in
            .success(Chat_V1_CommandResponse())
        }
        bff.register(path: "/chat.v1.ChatService/Subscribe") { (_: Chat_V1_SubscribeRequest) in
            .success(Chat_V1_CommandResponse())
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
    /// simulator is doing, and renders as "now" (`relativeShort` clamps a
    /// future date rather than counting backwards).
    private static let justArrived: Int64 = -5

    private func seedHistory(for conversationID: String) -> [Chat_V1_MessageView] {
        let other = otherMember[conversationID] ?? viewer
        let minute: Int64 = 60_000
        // (sender, body, minutesAgo). conv-0 is the dense thread-screen seed:
        // two day sections, same-sender runs (grouped bubbles), a long-wrap
        // paragraph, and back-to-back turnarounds. conv-1 stays short.
        let morning: Int64 = 25 * 60
        let midday: Int64 = 24 * 60 + 30
        // Request threads are inbound-only and unanswered by construction —
        // that IS the partition rule, so seeding a viewer reply here would
        // quietly move the row into the active inbox.
        if conversationID.hasPrefix("conv-req-") {
            let opener = conversationID == "conv-req-0"
                ? "Hi! Loved your shot of the pier — any chance you sell prints?"
                : "Hey, we're putting together a small show next month and I'd love to include your work."
            let inbound: [(String, String, Int64)] = [
                (other, opener, 90), (other, "No pressure either way 🙂", 88)
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
                (viewer, "Sent you the venue list", 200),
                (other, "Perfect, thanks! One more thing —", Self.justArrived + 1),
                (other, "can you make Thursday instead?", Self.justArrived)
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
                "Are we still on for Thursday?",
                "Sent you the files 👍",
                "That place you mentioned — what was it called?",
                "Congrats on the launch!",
                "Any chance you're free later this week?",
                "Just saw your post, that light is unreal",
                "Thanks again for yesterday"
            ]
            let replies = [
                "Yep, works for me",
                "Got them, thanks!",
                "I'll dig out the link",
                "Appreciate it 🙏",
                "Let me check and come back to you"
            ]
            // Staggered so the inbox (and Recent) has a real recency order
            // rather than a block of identical timestamps.
            let base = Int64(index) * 37 + 20
            var thread: [(String, String, Int64)] = [
                (other, openers[index % openers.count], base + 12),
                (viewer, replies[index % replies.count], base + 6)
            ]
            if !answered {
                // `conv-3` lands its reply as a live arrival; the rest sit in
                // the past. Three arrivals total, so the All badge reads "3"
                // out of the box and the rows under it say which three.
                thread.append((other, "👍", index == 3 ? Self.justArrived : base))
            }
            // `conv-4` is the BURST: one peer talking into the silence, which
            // is the only seeded state that pushes a row's unread count into
            // two digits. Without it every avatar badge is a single digit and
            // the pill's widening — the whole reason it is a capsule and not a
            // circle — goes unexercised.
            if index == 4 {
                let burst = [
                    "Actually, one more thing", "Sorry, several more things",
                    "The venue wants a deposit by Friday", "And a rider",
                    "Do we have a rider?", "I'll assume no",
                    "Also parking is a nightmare", "Bring cash for it",
                    "Load-in is 4pm sharp", "They were very firm about that"
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
                (other, "Morning! Standup moved to 9:30 today", morning),
                (other, "Room 4 this time", morning - 1),
                (other, "And bring the tab bar demo if it's ready", morning - 2),
                (viewer, "👍 on my way", morning - 4),
                (viewer, "Demo's ready — pushed the branch last night", morning - 5),
                (other, "Saw it. The thread screen rebuild is next, right? The list one is starting to feel very 2015.", midday),
                (viewer, "Yep, Telegram-style bubbles, day chips, glass input bar — the works. Native UIKit only though, no custom layout engine.", midday - 10),
                (other, "Bold claim 😄", midday - 11),
                (viewer, "Watch me", midday - 15),
                (other, "Hey! Did you see the new build?", 60),
                (viewer, "Yeah, shipping it today 🚀", 58),
                (viewer, "Just cleaning up the last QA notes", 57),
                (other, "Nice — ping me when it's live", 55),
                (other, "No rush, I'm in reviews all morning anyway", 54),
                (viewer, "Will do", 12)
            ]
            : [
                (other, "Hey! Did you see the new build?", 60),
                (viewer, "Yeah, shipping it today 🚀", 58),
                (other, "Nice — ping me when it's live", Self.justArrived)
            ]
        // Seeded threaded replies (message index → the index it answers), so
        // the quoted-reply rendering is present in the dense demo thread
        // without having to compose one. conv-0 only.
        let replyLinks: [Int: Int] = conversationID == "conv-0" ? [6: 5, 8: 7] : [:]
        return specs.enumerated().map { index, spec in
            let (sender, body, minutesAgo) = spec
            var view = Chat_V1_MessageView()
            view.messageID = "\(conversationID)-m\(index)"
            view.senderID = sender
            view.body = body
            view.createdAtMs = nowMs - minutesAgo * minute
            if let target = replyLinks[index] { view.replyTo = "\(conversationID)-m\(target)" }
            return view
        }
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String: [Chat_V1_MessageView]] = [:]
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
        func append(_ request: Chat_V1_SendMessageRequest, after newest: Int64) -> String {
            lock.withLock {
                let id = "\(request.conversationID)-sent-\(sent[request.conversationID]?.count ?? 0)"
                var view = Chat_V1_MessageView()
                view.messageID = id
                view.senderID = request.senderID
                view.body = request.body
                view.replyTo = request.replyTo
                view.createdAtMs = max(Int64(Date().timeIntervalSince1970 * 1000), newest + 1)
                sent[request.conversationID, default: []].append(view)
                return id
            }
        }
    }
}
