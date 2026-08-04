import CoreModels
import CoreNavigation
import Foundation
import Testing
import UIKit
@testable import Chat

// MARK: - Fixtures

private func conversation(
    _ id: String,
    peer: String? = "peer-1",
    peers: [String]? = nil,
    lastMessageIsMine: Bool = false,
    hasActivity: Bool = true,
    isUnread: Bool = false,
    unreadCount: Int = 0,
    activityAt: Date = Date(timeIntervalSince1970: 0)
) -> Conversation {
    Conversation(
        id: ConversationID(id),
        title: "Ava",
        lastMessage: "hi",
        lastActivityAt: hasActivity ? activityAt : nil,
        otherMemberIDs: (peers ?? [peer].compactMap(\.self)).map { ProfileID($0) },
        lastMessageIsMine: lastMessageIsMine,
        lastMessageID: "\(id)-latest",
        isUnread: isUnread,
        unreadCount: unreadCount
    )
}

private func displayModel(_ id: String, isUnread: Bool) -> ConversationDisplayModel {
    ConversationDisplayModel(
        conversation: conversation(id, isUnread: isUnread, unreadCount: isUnread ? 1 : 0),
        isUnread: isUnread,
        unreadCount: isUnread ? 1 : 0
    )
}

private actor StubInboxProvider: ChatProviding {
    var conversations: [Conversation]
    /// (conversation, message) pairs the inbox asked to mark read.
    private(set) var markReadCalls: [(ConversationID, String)] = []
    /// When true, a load keeps reporting rows as unread — the server ignoring
    /// (or not yet reflecting) the write.
    private var ignoresMarkRead = false
    private var failingMarkReads: Set<ConversationID> = []
    private var markReadGateIsOpen = true
    private var pendingMarkReads = 0

    init(conversations: [Conversation]) { self.conversations = conversations }

    /// The write is accepted but never reflected by later loads — replication
    /// lag, the exact condition the read bridge exists for.
    func setIgnoresMarkRead(_ ignores: Bool) { ignoresMarkRead = ignores }

    /// The write itself fails for this conversation.
    func setMarkReadFailure(for id: ConversationID) { failingMarkReads.insert(id) }

    /// Holds every `markRead` open, so a test can observe what the inbox looks
    /// like while the write is still in flight.
    func setMarkReadGate(open isOpen: Bool) { markReadGateIsOpen = isOpen }
    var markReadIsPending: Bool { pendingMarkReads > 0 }

    /// Stands in for the server advancing every `last_read` cursor — the next
    /// load reports everything as read.
    func markEverythingRead() {
        conversations = conversations.map { $0.read() }
    }

    /// Payloads handed out one per `loadConversations` call, so a test can make
    /// an earlier (superseded) load resolve to a different, truncated inbox
    /// than the one that supersedes it.
    private var loadPayloads: [[Conversation]] = []
    private var loadGateIsOpen = true

    func setConversations(_ updated: [Conversation]) { conversations = updated }
    func setLoadPayloads(_ payloads: [[Conversation]]) { loadPayloads = payloads }
    func setLoadGate(open isOpen: Bool) { loadGateIsOpen = isOpen }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }

    func loadConversations() async throws -> [Conversation] {
        // The payload is claimed in call order, THEN the call blocks — so two
        // overlapping loads resolve to the payloads their order implies.
        let payload = loadPayloads.isEmpty ? conversations : loadPayloads.removeFirst()
        while !loadGateIsOpen {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return payload
    }
    /// One inbound message, id-matched to the fixture's `lastMessageID`, so a
    /// thread opened over this stub has something to mark read.
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] {
        [ChatMessage(
            id: "\(conversationID.rawValue)-latest",
            senderID: ProfileID("peer-1"),
            body: "hi",
            createdAt: Date(timeIntervalSince1970: 0),
            isMine: false
        )]
    }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "m", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {
        markReadCalls.append((conversationID, messageID))
        if !markReadGateIsOpen {
            pendingMarkReads += 1
            while !markReadGateIsOpen {
                try? await Task.sleep(for: .milliseconds(5))
            }
            pendingMarkReads -= 1
        }
        if failingMarkReads.contains(conversationID) { throw StubError() }
        guard !ignoresMarkRead else { return }
        // Only THIS conversation's cursor moves — a write that lands for one
        // row must not quietly mark its neighbours read too.
        conversations = conversations.map { $0.id == conversationID ? $0.read() : $0 }
    }
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
}

private struct StubRelations: PeerRelationProviding {
    var followed: Set<ProfileID> = []
    var failure: (any Error)?

    func followedPeers(among peers: [ProfileID]) async throws -> Set<ProfileID> {
        if let failure { throw failure }
        return Set(peers).intersection(followed)
    }
}

private struct StubError: Error {}

/// A clock a test can move, for the view models that take `now` as a closure.
/// A frozen one cannot express "…and then the viewer came back", which is the
/// only interesting thing about a watermark.
private final class MovableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private extension Conversation {
    /// The same conversation with its unread flag cleared, as a server that
    /// advanced the read cursor would report it.
    func read() -> Conversation {
        Conversation(
            id: id,
            title: title,
            lastMessage: lastMessage,
            lastActivityAt: lastActivityAt,
            otherMemberIDs: otherMemberIDs,
            lastMessageIsMine: lastMessageIsMine,
            lastMessageID: lastMessageID,
            isUnread: false
        )
    }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private actor StubSuggestions: SuggestionsProviding {
    var accounts: [SuggestedAccount]
    var shouldFailFollow = false
    private(set) var followed: [ProfileID] = []
    private(set) var unfollowed: [ProfileID] = []

    init(accounts: [SuggestedAccount] = [], shouldFailFollow: Bool = false) {
        self.accounts = accounts
        self.shouldFailFollow = shouldFailFollow
    }

    func suggestions(limit: Int) async throws -> [SuggestedAccount] { accounts }
    func follow(_ profileID: ProfileID) async throws {
        if shouldFailFollow { throw StubError() }
        followed.append(profileID)
    }
    func unfollow(_ profileID: ProfileID) async throws {
        if shouldFailFollow { throw StubError() }
        unfollowed.append(profileID)
    }
}

private func account(_ id: String, reason: SuggestedAccount.Reason = .followsYou) -> SuggestedAccount {
    SuggestedAccount(
        id: ProfileID(id),
        handle: id,
        displayName: "Name \(id)",
        avatarURL: nil,
        reason: reason
    )
}

// MARK: - Request partition

struct MessageRequestPolicyTests {
    @Test func unansweredMessageFromAnUnfollowedPeerIsARequest() {
        let partition = MessageRequestPolicy.partition([conversation("c1")], followedPeers: [])
        #expect(partition.requests.map(\.id) == [ConversationID("c1")])
        #expect(partition.active.isEmpty)
    }

    @Test func aFollowedPeerIsNeverARequest() {
        let partition = MessageRequestPolicy.partition(
            [conversation("c1", peer: "peer-1")], followedPeers: [ProfileID("peer-1")]
        )
        #expect(partition.active.map(\.id) == [ConversationID("c1")])
        #expect(partition.requests.isEmpty)
    }

    /// Having replied answers the ask, follow or no follow.
    @Test func aConversationTheViewerAnsweredIsNotARequest() {
        let partition = MessageRequestPolicy.partition(
            [conversation("c1", lastMessageIsMine: true)], followedPeers: []
        )
        #expect(partition.active.map(\.id) == [ConversationID("c1")])
    }

    @Test func anEmptyConversationIsNotARequest() {
        let partition = MessageRequestPolicy.partition(
            [conversation("c1", hasActivity: false)], followedPeers: []
        )
        #expect(partition.active.map(\.id) == [ConversationID("c1")])
    }

    /// "The sender" isn't a single account the viewer can vet.
    @Test func groupConversationsAreNeverRequests() {
        let partition = MessageRequestPolicy.partition(
            [conversation("c1", peers: ["peer-1", "peer-2"])], followedPeers: []
        )
        #expect(partition.active.map(\.id) == [ConversationID("c1")])
    }

    @Test func acceptedRequestsJoinTheActiveInboxAndDeclinedOnesLeaveEntirely() {
        let conversations = [conversation("c1"), conversation("c2"), conversation("c3")]
        let partition = MessageRequestPolicy.partition(
            conversations,
            followedPeers: [],
            accepted: [ConversationID("c1")],
            declined: [ConversationID("c2")]
        )
        #expect(partition.active.map(\.id) == [ConversationID("c1")])
        #expect(partition.requests.map(\.id) == [ConversationID("c3")])
    }

    @Test func deletedConversationsLeaveBothLists() {
        let partition = MessageRequestPolicy.partition(
            [conversation("c1"), conversation("c2", lastMessageIsMine: true)],
            followedPeers: [],
            deleted: [ConversationID("c1"), ConversationID("c2")]
        )
        #expect(partition.active.isEmpty)
        #expect(partition.requests.isEmpty)
    }
}

// MARK: - Row ordering

struct ConversationOrderingTests {
    private func order(_ conversations: [Conversation]) -> [String] {
        conversations.sorted(by: Conversation.isOrderedBefore).map(\.id.rawValue)
    }

    @Test func newestActivityComesFirst() {
        let older = conversation("older", activityAt: Date(timeIntervalSince1970: 100))
        let newer = conversation("newer", activityAt: Date(timeIntervalSince1970: 200))
        #expect(order([older, newer]) == ["newer", "older"])
        #expect(order([newer, older]) == ["newer", "older"])
    }

    /// The bug: ordering on the timestamp ALONE is a partial order, and
    /// Swift's sort is not stable — so equal activity let rows swap places
    /// between two identical loads. The id tie-break makes it total, and the
    /// result independent of the input order.
    @Test func equalActivityIsBrokenByIdAndIsInputOrderIndependent() {
        let shared = Date(timeIntervalSince1970: 100)
        let a = conversation("a", activityAt: shared)
        let b = conversation("b", activityAt: shared)
        let c = conversation("c", activityAt: shared)

        // Every permutation must land on the same answer.
        #expect(order([a, b, c]) == ["a", "b", "c"])
        #expect(order([c, b, a]) == ["a", "b", "c"])
        #expect(order([b, a, c]) == ["a", "b", "c"])
        #expect(order([c, a, b]) == ["a", "b", "c"])
    }

    @Test func conversationsWithNoActivitySinkButStayOrdered() {
        let active = conversation("active", activityAt: Date(timeIntervalSince1970: 100))
        let quietB = conversation("quiet-b", hasActivity: false)
        let quietA = conversation("quiet-a", hasActivity: false)
        #expect(order([quietB, active, quietA]) == ["active", "quiet-a", "quiet-b"])
    }
}

// MARK: - Suggestion ranking

struct SuggestionRankerTests {
    private func input(
        followers: [String] = [],
        following: [String] = [],
        secondHop: [String: [String]] = [:],
        dismissed: [String] = []
    ) -> SuggestionRanker.Input {
        SuggestionRanker.Input(
            viewer: ProfileID("me"),
            followers: Set(followers.map { ProfileID($0) }),
            following: Set(following.map { ProfileID($0) }),
            followingOfFollowing: secondHop.reduce(into: [:]) { partial, pair in
                partial[ProfileID(pair.key)] = Set(pair.value.map { ProfileID($0) })
            },
            dismissed: Set(dismissed.map { ProfileID($0) })
        )
    }

    /// Someone who already chose the viewer outranks any number of shared
    /// connections.
    @Test func followersOutrankFriendsOfFriends() {
        let ranked = SuggestionRanker.rank(input(
            followers: ["p-follower"],
            following: ["f1", "f2", "f3"],
            secondHop: ["f1": ["p-popular"], "f2": ["p-popular"], "f3": ["p-popular"]]
        ))
        #expect(ranked.map(\.id) == [ProfileID("p-follower"), ProfileID("p-popular")])
        #expect(ranked[0].followsViewer)
        #expect(ranked[1].connectors.count == 3)
    }

    @Test func friendsOfFriendsRankByConnectorCount() {
        let ranked = SuggestionRanker.rank(input(
            following: ["f1", "f2"],
            secondHop: ["f1": ["p-one", "p-two"], "f2": ["p-two"]]
        ))
        #expect(ranked.map(\.id) == [ProfileID("p-two"), ProfileID("p-one")])
    }

    @Test func accountsAlreadyFollowedTheViewerAndDismissalsAreExcluded() {
        let ranked = SuggestionRanker.rank(input(
            followers: ["f1", "me", "p-hidden"],
            following: ["f1", "f2"],
            secondHop: ["f2": ["f1", "me", "p-hidden", "p-ok"]],
            dismissed: ["p-hidden"]
        ))
        #expect(ranked.map(\.id) == [ProfileID("p-ok")])
    }

    /// Equal scores break on id, so reloading can't reshuffle the list.
    @Test func tiesBreakDeterministicallyAndTheLimitHolds() {
        let ranked = SuggestionRanker.rank(
            input(followers: ["p-c", "p-a", "p-b"]),
            limit: 2
        )
        #expect(ranked.map(\.id) == [ProfileID("p-a"), ProfileID("p-b")])
    }
}

// MARK: - Catalog

@MainActor
struct InboxCatalogTests {
    /// ⚠️ Fixed-duration, and therefore a source of flakiness: it waits for the
    /// CLOCK, not for the work. 50ms was enough until it wasn't — on the first
    /// run after a build, four different tests in this file have been seen to
    /// fail with empty snapshots (the load simply had not landed yet), each
    /// passing on every re-run. The budget is now spread over several rounds,
    /// which covers the observed window with room to spare.
    ///
    /// Prefer `settle(until:)` for anything new: it waits for the condition the
    /// test is actually about, and returns as soon as it holds.
    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Waits for a condition instead of for the clock.
    ///
    /// `settle()` sleeps a fixed 50ms, which is enough right up until the
    /// machine is busy. Polling also means the work has LANDED when the test
    /// ends, rather than being left in flight to slow whatever runs next.
    private func settle(until condition: @escaping () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func loadPartitionsActiveConversationsFromRequests() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("active", peer: "friend", lastMessageIsMine: false),
                conversation("request", peer: "stranger")
            ]),
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var snapshots: [InboxCatalog.Snapshot] = []
        let token = catalog.observe { snapshots.append($0) }
        catalog.reload()
        await settle()

        #expect(snapshots.last?.active.map(\.id) == [ConversationID("active")])
        #expect(snapshots.last?.requests.map(\.id) == [ConversationID("request")])
        _ = token
    }

    @Test func acceptingARequestMovesItIntoTheActiveInbox() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [conversation("request", peer: "stranger")]),
            relations: StubRelations()
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        catalog.accept(ConversationID("request"))
        #expect(latest?.active.map(\.id) == [ConversationID("request")])
        #expect(latest?.requests.isEmpty == true)
        _ = token
    }

    @Test func decliningARequestRemovesItFromBothLists() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [conversation("request", peer: "stranger")]),
            relations: StubRelations()
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        catalog.decline(ConversationID("request"))
        #expect(latest?.active.isEmpty == true)
        #expect(latest?.requests.isEmpty == true)
        _ = token
    }

    /// The partition is a heuristic, so an unreachable relation service must
    /// fail OPEN — quarantining real conversations behind a tab the user may
    /// never open is the worse failure by a wide margin.
    @Test func aRelationLookupFailureLeavesEverythingInTheActiveInbox() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [conversation("c1", peer: "stranger")]),
            relations: StubRelations(failure: StubError())
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        #expect(latest?.active.map(\.id) == [ConversationID("c1")])
        #expect(latest?.requests.isEmpty == true)
        _ = token
    }

    /// Unread is a PROJECTION of the active list, not a separate one — so it
    /// inherits pin ordering and can never contain a request.
    /// The back-navigation flash: opening a thread starts a load (via the
    /// read report), popping starts another, and the first is cancelled.
    /// Cancellation is best-effort — the cancelled load can still resolve to a
    /// TRUNCATED inbox, because hydration skips conversations whose requests
    /// failed. Publishing that produced the half-state: badges at zero, one
    /// row, then everything snapping back.
    ///
    /// A superseded load must publish nothing at all.
    @Test func aSupersededLoadNeverPublishesItsTruncatedResult() async {
        let full = [
            conversation("a", peer: "friend"),
            conversation("b", peer: "friend"),
            conversation("c", peer: "friend", isUnread: true)
        ]
        let provider = StubInboxProvider(conversations: full)
        // The first (soon-superseded) load resolves to a single row.
        await provider.setLoadPayloads([[conversation("a", peer: "friend")], full])
        await provider.setLoadGate(open: false)
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var loadedCounts: [Int] = []
        var loadedUnreadCounts: [Int] = []
        let token = catalog.observe { snapshot in
            guard snapshot.phase == .loaded else { return }
            loadedCounts.append(snapshot.active.count)
            loadedUnreadCounts.append(snapshot.unreadIDs.count)
        }

        catalog.reload()   // load A — claims the truncated payload
        catalog.reload()   // supersedes A; load B claims the full one
        await provider.setLoadGate(open: true)
        await settle()

        #expect(!loadedCounts.isEmpty)
        // The one-row inbox never reached anybody.
        #expect(loadedCounts.allSatisfy { $0 == 3 })
        #expect(loadedUnreadCounts.allSatisfy { $0 == 1 })
    _ = token
    }

    /// A reload over a populated inbox must not blank it first — the rows and
    /// the badge counts stay put for the whole fetch, which is what keeps a
    /// pop transition stable.
    @Test func aReloadKeepsTheCurrentRowsUntilTheNewOnesArrive() async {
        let provider = StubInboxProvider(conversations: [
            conversation("a", peer: "friend"),
            conversation("b", peer: "friend", isUnread: true),
            conversation("r1", peer: "stranger")
        ])
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        catalog.reload()
        await settle()

        var observed: [(active: Int, unread: Int, requests: Int)] = []
        let token = catalog.observe { snapshot in
            observed.append((snapshot.active.count, snapshot.unreadIDs.count, snapshot.requests.count))
        }
        await provider.setLoadGate(open: false)
        catalog.reload()
        await settle() // mid-flight: the fetch has not returned

        #expect(observed.allSatisfy { $0 == (2, 1, 1) })
        await provider.setLoadGate(open: true)
        await settle()
        #expect(observed.last! == (2, 1, 1))
        _ = token
    }

    /// Unread spans BOTH partitions. It was active-only while unread was a
    /// question only the All list asked; the Requests rows now wear the same
    /// bold preview and avatar count, and a request nobody has opened is unread
    /// by exactly the same test.
    @Test func unreadCoversRequestsAsWellAsActiveConversations() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("read", peer: "friend"),
                conversation("unread", peer: "friend", isUnread: true),
                conversation("unread-request", peer: "stranger", isUnread: true)
            ]),
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        #expect(latest?.active.map(\.id) == [ConversationID("read"), ConversationID("unread")])
        #expect(latest?.requests.map(\.id) == [ConversationID("unread-request")])
        #expect(latest?.unreadIDs == [ConversationID("unread"), ConversationID("unread-request")])
        _ = token
    }

    /// The bug this covers: the inbox used to learn a thread had been read
    /// only by reloading on appear, which races the thread screen's own
    /// `markRead`. Pop back before that write lands — or run on a network
    /// slower than a mock — and the reload returns PRE-write state, so the
    /// row sits in Unread until something reloads again.
    ///
    /// Simulated here by a repository whose reads keep reporting the stale
    /// truth: the row must still leave Unread the moment the thread reports
    /// its cursor moved.
    @Test func aThreadReportingItsReadCursorLeavesUnreadEvenIfTheNextLoadIsStale() async {
        let provider = StubInboxProvider(conversations: [
            conversation("u1", peer: "friend", isUnread: true),
            conversation("u2", peer: "friend", isUnread: true)
        ])
        // The server hasn't caught up: every load still says both are unread.
        await provider.setIgnoresMarkRead(true)
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()
        #expect(latest?.unreadIDs.count == 2)

        // The thread screen reports that it moved the cursor.
        catalog.markRead(ConversationID("u1"))

        #expect(latest?.unreadIDs == [ConversationID("u2")])
        // And the row it left is still a conversation — only its unread state
        // changed.
        #expect(latest?.active.count == 2)

        // The confirming reload lands; the row must not reappear just because
        // this stub never advances its cursors.
        await settle()
        #expect(latest?.unreadIDs == [ConversationID("u2")])
        _ = token
    }

    /// The audit, as an executable spec: EVERY inbox action lands on the very
    /// next line, with no `await` in between.
    ///
    /// That is what makes a back swipe safe — the list underneath is already
    /// right, so the reveal has nothing left to update. A regression here
    /// (someone routing an action through a network round trip first) brings
    /// the post-animation jump straight back.
    @Test func everyInboxActionLandsSynchronously() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("a", peer: "friend"),
                conversation("b", peer: "friend"),
                conversation("unread", peer: "friend", isUnread: true),
                conversation("r1", peer: "stranger"),
                conversation("r2", peer: "stranger")
            ]),
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        // Pin: reorders the active list, immediately.
        catalog.togglePin(ConversationID("b"))
        #expect(latest?.active.first?.id == ConversationID("b"))
        #expect(latest?.pinned.contains(ConversationID("b")) == true)

        catalog.togglePin(ConversationID("b"))
        #expect(latest?.active.first?.id == ConversationID("a"))

        // Mute: flags without reordering, immediately.
        catalog.toggleMute(ConversationID("a"))
        #expect(latest?.muted.contains(ConversationID("a")) == true)

        // Accept a request: leaves Requests and joins All, immediately.
        catalog.accept(ConversationID("r1"))
        #expect(latest?.requests.map(\.id) == [ConversationID("r2")])
        #expect(latest?.active.contains { $0.id == ConversationID("r1") } == true)

        // Refuse: leaves both lists, immediately.
        catalog.decline(ConversationID("r2"))
        #expect(latest?.requests.isEmpty == true)

        // Read: leaves Unread, immediately.
        catalog.markRead(ConversationID("unread"))
        #expect(latest?.unreadIDs.isEmpty == true)

        // Delete: leaves the inbox, immediately.
        catalog.delete([ConversationID("a")])
        #expect(latest?.active.contains { $0.id == ConversationID("a") } == false)
        _ = token
    }

    /// Sending changes the row's preview, time AND position. It was the one
    /// action with no optimistic path — the catalog only learned of it by
    /// reloading, so the list underneath a thread stayed stale until a fetch
    /// completed, which on any real network is after the swipe has finished.
    @Test func aSentMessageUpdatesItsRowImmediatelyAndHoistsIt() async {
        let older = Date(timeIntervalSince1970: 0)
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("top", peer: "friend"),
                conversation("bottom", peer: "friend", isUnread: true)
            ]),
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()
        #expect(latest?.active.map(\.id) == [ConversationID("top"), ConversationID("bottom")])

        catalog.recordSentMessage(
            ChatMessage(
                id: "sent-1",
                senderID: ProfileID("me"),
                body: "on my way",
                createdAt: older.addingTimeInterval(500),
                isMine: true
            ),
            in: ConversationID("bottom")
        )

        // Same turn: hoisted, preview replaced, and no longer unread — you
        // cannot have unread mail from yourself.
        let rows = latest?.active ?? []
        #expect(rows.map(\.id) == [ConversationID("bottom"), ConversationID("top")])
        #expect(rows.first?.lastMessage == "on my way")
        #expect(rows.first?.lastMessageIsMine == true)
        #expect(latest?.unreadIDs.isEmpty == true)
        _ = token
    }

    @Test func aSentMessageInAnUnknownConversationIsIgnored() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [conversation("a", peer: "friend")]),
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        catalog.recordSentMessage(
            ChatMessage(id: "x", senderID: ProfileID("me"), body: "hi", createdAt: Date(), isMine: true),
            in: ConversationID("not-in-the-inbox")
        )

        #expect(latest?.active.map(\.id) == [ConversationID("a")])
        _ = token
    }

    /// The inbox must be correct *underneath* the thread, not after it closes.
    /// A back swipe reveals the list progressively, so a change that lands
    /// once the transition ends is a visible jump — the read has to be
    /// applied before the server write is even attempted.
    @Test func theInboxIsUpdatedBeforeTheServerWriteIsAttempted() async {
        let provider = StubInboxProvider(conversations: [
            conversation("u1", peer: "friend", isUnread: true),
            conversation("u2", peer: "friend", isUnread: true)
        ])
        await provider.setMarkReadGate(open: false) // the write cannot complete
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        let viewModel = ConversationViewModel(conversationID: ConversationID("u1"), repository: provider)
        viewModel.onDidMarkRead = { catalog.markRead($0) }
        viewModel.onMarkReadDidFail = { catalog.markReadDidFail($0) }
        viewModel.viewDidLoad()
        await settle()

        // The write is still blocked, yet the row is already gone.
        #expect(await provider.markReadIsPending)
        #expect(latest?.unreadIDs == [ConversationID("u2")])
        await provider.setMarkReadGate(open: true)
        _ = token
    }

    /// And if that write then fails, the row comes back — the optimism is
    /// bounded, not blind.
    @Test func aThreadWhoseWriteFailsPutsItsRowBack() async {
        let provider = StubInboxProvider(conversations: [conversation("u1", peer: "friend", isUnread: true)])
        await provider.setMarkReadFailure(for: ConversationID("u1"))
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        let viewModel = ConversationViewModel(conversationID: ConversationID("u1"), repository: provider)
        viewModel.onDidMarkRead = { catalog.markRead($0) }
        viewModel.onMarkReadDidFail = { catalog.markReadDidFail($0) }
        viewModel.viewDidLoad()
        await settle()

        #expect(latest?.unreadIDs == [ConversationID("u1")])
        _ = token
    }

    /// Reading the last unread conversation empties the projection, which is
    /// what makes the Unread tab disappear.
    @Test func readingTheLastUnreadConversationEmptiesTheProjection() async {
        let provider = StubInboxProvider(conversations: [conversation("u1", peer: "friend", isUnread: true)])
        await provider.setIgnoresMarkRead(true)
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        catalog.markRead(ConversationID("u1"))
        await settle()

        #expect(latest?.unreadIDs.isEmpty == true)
        _ = token
    }

    /// Reporting the same conversation twice (thread reloads, then a send)
    /// must not thrash the list or re-emit endlessly.
    @Test func reportingTheSameReadTwiceIsIdempotent() async {
        let provider = StubInboxProvider(conversations: [conversation("u1", peer: "friend", isUnread: true)])
        await provider.setIgnoresMarkRead(true)
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var emissions = 0
        let token = catalog.observe { _ in emissions += 1 }
        catalog.reload()
        await settle()
        let before = emissions

        catalog.markRead(ConversationID("u1"))
        catalog.markRead(ConversationID("u1"))
        await settle()

        // One projection for the change, plus the confirming reload's own.
        #expect(emissions - before <= 2)
        _ = token
    }

    /// Toggling to the Requests tab must not reshuffle it. The rows here all
    /// share a timestamp — the degenerate case the mock's own seeds hit — so
    /// order rests entirely on the tie-break, and the repository is free to
    /// hand back a different arrangement each load.
    @Test func requestOrderIsIdenticalAcrossReloads() async {
        let shared = Date(timeIntervalSince1970: 500)
        let provider = StubInboxProvider(conversations: [
            conversation("r-c", peer: "stranger-c", activityAt: shared),
            conversation("r-a", peer: "stranger-a", activityAt: shared),
            conversation("r-b", peer: "stranger-b", activityAt: shared)
        ])
        let catalog = InboxCatalog(repository: provider, relations: StubRelations())
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }

        catalog.reload()
        await settle()
        let firstOrder = latest?.requests.map(\.id)
        #expect(firstOrder == [ConversationID("r-a"), ConversationID("r-b"), ConversationID("r-c")])

        // Each reload stands in for a return to the tab. The load is handed
        // the rows in a DIFFERENT arrangement every time; the projection must
        // not care.
        for arrangement in [["r-b", "r-c", "r-a"], ["r-c", "r-a", "r-b"], ["r-a", "r-c", "r-b"]] {
            await provider.setConversations(arrangement.map {
                conversation($0, peer: "stranger-\($0.suffix(1))", activityAt: shared)
            })
            catalog.reload()
            await settle()
            #expect(latest?.requests.map(\.id) == firstOrder)
        }
        _ = token
    }

    @Test func pinningHoistsWithinTheActiveListOnly() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("c1", peer: "friend"), conversation("c2", peer: "friend")
            ]),
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0 }
        catalog.reload()
        await settle()

        catalog.togglePin(ConversationID("c2"))
        #expect(latest?.active.map(\.id) == [ConversationID("c2"), ConversationID("c1")])
        #expect(catalog.isPinned(ConversationID("c2")))
        _ = token
    }
}

// MARK: - Surfaces sharing one catalog

@MainActor
struct InboxSurfaceViewModelTests {
    /// ⚠️ Fixed-duration, and therefore a source of flakiness: it waits for the
    /// CLOCK, not for the work. 50ms was enough until it wasn't — on the first
    /// run after a build, four different tests in this file have been seen to
    /// fail with empty snapshots (the load simply had not landed yet), each
    /// passing on every re-run. The budget is now spread over several rounds,
    /// which covers the observed window with room to spare.
    ///
    /// Prefer `settle(until:)` for anything new: it waits for the condition the
    /// test is actually about, and returns as soon as it holds.
    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The whole point of the shared catalog: one load, two projections, and a
    /// decision on one surface lands on the other with no refetch.
    @Test func acceptingInRequestsPublishesToTheConversationList() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [conversation("request", peer: "stranger")]),
            relations: StubRelations()
        )
        let list = ConversationListViewModel(catalog: catalog)
        let requests = MessageRequestsViewModel(catalog: catalog)
        var listPhase: ConversationListViewModel.Phase?
        var requestsPhase: MessageRequestsViewModel.Phase?
        list.onPhaseChange = { listPhase = $0 }
        requests.onPhaseChange = { requestsPhase = $0 }

        list.viewWillAppear()
        await settle()
        #expect(listPhase == .empty)
        guard case .content(let pendingSections) = requestsPhase else {
            Issue.record("expected a pending request, got \(String(describing: requestsPhase))")
            return
        }
        let pending = pendingSections.all
        #expect(pending.map(\.id) == [ConversationID("request")])

        requests.accept(ConversationID("request"))
        guard case .content(let rowsSections) = listPhase else {
            Issue.record("expected content, got \(String(describing: listPhase))")
            return
        }
        let rows = rowsSections.all
        #expect(rows.map(\.id) == [ConversationID("request")])
        #expect(requestsPhase == .empty)
    }

    /// Unread is marked IN the All list, not split into a tab: the rows stay
    /// put and carry a flag. That flag is what the row's avatar badge and bold
    /// text are drawn from — it is NOT what the tab badge counts, which is
    /// arrivals since the last visit (`InboxTabWatermark`).
    @Test func unreadRowsAreFlaggedInPlace() async {
        let provider = StubInboxProvider(conversations: [
            conversation("read", peer: "friend"),
            conversation("unread", peer: "friend", isUnread: true)
        ])
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        let list = ConversationListViewModel(catalog: catalog)
        var phase: ConversationListViewModel.Phase?
        list.onPhaseChange = { phase = $0 }

        list.viewWillAppear()
        await settle()

        guard case .content(let rowsSections) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        let rows = rowsSections.all
        // Both rows are present; only one is flagged.
        #expect(rows.map(\.id) == [ConversationID("read"), ConversationID("unread")])
        #expect(rows.map(\.isUnread) == [false, true])
    }

    /// Reading it clears the flag and the count without removing the row —
    /// the conversation never leaves the list it was always in.
    @Test func readingAConversationClearsItsFlagButKeepsTheRow() async {
        let provider = StubInboxProvider(conversations: [
            conversation("a", peer: "friend", isUnread: true),
            conversation("b", peer: "friend", isUnread: true)
        ])
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        let list = ConversationListViewModel(catalog: catalog)
        var phase: ConversationListViewModel.Phase?
        list.onPhaseChange = { phase = $0 }
        list.viewWillAppear()
        await settle()

        catalog.markRead(ConversationID("a"))

        guard case .content(let rowsSections) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        let rows = rowsSections.all
        #expect(rows.count == 2)
        #expect(rows.map(\.isUnread) == [false, true])
    }

    /// The Requests badge counts ARRIVALS SINCE THE APP OPENED, not pending
    /// totals — and nothing in the session takes it away.
    ///
    /// The watermark opens at the view model's `now`, so a `now` before the
    /// fixtures' activity is what makes them read as having arrived since.
    @Test func theRequestsBadgeCountsArrivalsAndHoldsThem() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("r1", peer: "a"), conversation("r2", peer: "b")
            ]),
            relations: StubRelations()
        )
        let requests = MessageRequestsViewModel(
            catalog: catalog, now: { Date(timeIntervalSince1970: -1) }
        )
        var counts: [Int] = []
        requests.onNewCountChange = { counts.append($0) }
        requests.refresh()
        await settle()

        #expect(counts == [2])
        #expect(requests.newCount == 2)

        // A reload is the closest thing to "the viewer did something": the
        // count must come back the same.
        requests.refresh()
        await settle()
        #expect(requests.newCount == 2)
        #expect(counts == [2])
    }

    /// The badge and the SECTION are the watermark's answer — what arrived
    /// since the app opened — and nothing in the session takes either away.
    ///
    /// ⚠️ Deliberately not asserted through `isUnread` any more. That flag is
    /// the READ CURSOR now, the same as on the All list, so a request the
    /// fixtures never marked unread is not bold — and the row's section is a
    /// different question with a different answer.
    @Test func theBadgeAndItsSectionSurviveWhileTheTabIsOpen() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("r1", peer: "a"), conversation("r2", peer: "b")
            ]),
            relations: StubRelations()
        )
        let clock = MovableClock(Date(timeIntervalSince1970: -1))
        let requests = MessageRequestsViewModel(catalog: catalog, now: { clock.now })
        var phase: MessageRequestsViewModel.Phase?
        requests.onPhaseChange = { phase = $0 }
        requests.refresh()
        await settle()

        guard case .content(let sections) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        #expect(requests.newCount == 2)
        #expect(sections.new.count == 2)
        #expect(sections.earlier.isEmpty)
    }

    /// Opening a request is what un-bolds it: the thread moves the read cursor,
    /// the catalog drops it from the unread set, and the row comes back plain
    /// with no count on its avatar — exactly what an All row does.
    @Test func readingARequestClearsItsBoldPreviewAndCount() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("r1", peer: "a", isUnread: true, unreadCount: 3),
                conversation("r2", peer: "b", isUnread: true, unreadCount: 2)
            ]),
            relations: StubRelations()
        )
        let requests = MessageRequestsViewModel(catalog: catalog)
        var phase: MessageRequestsViewModel.Phase?
        requests.onPhaseChange = { phase = $0 }
        requests.refresh()
        await settle()

        guard case .content(let before) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        #expect(before.all.map(\.isUnread) == [true, true])
        #expect(before.all.map(\.unreadCount) == [3, 2])

        // What the thread screen reports when it is opened.
        catalog.markRead(ConversationID("r1"))

        guard case .content(let after) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        #expect(after.all.map(\.isUnread) == [false, true])
        #expect(after.all.map(\.unreadCount) == [0, 2])
        // The row stays put: reading it is not the same as it never arriving.
        #expect(after.all.map(\.id) == before.all.map(\.id))

        // ⚠️ And because it stays put, the LIST has to be told. The row's id is
        // unchanged, so the diff between these two states is empty and a
        // diffable list re-renders nothing unless the changed row is named. A
        // correct projection that never reaches the cell is the bug this half
        // of the round trip exists to catch — it is what actually shipped on
        // Requests while every model-level assertion above passed.
        let previous = Dictionary(uniqueKeysWithValues: before.all.map { ($0.id, $0) })
        #expect(
            InboxRowDiff.changedRows(in: after.all, against: previous) == [ConversationID("r1")]
        )
    }

    @Test func anUnchangedRowIsNotReRendered() {
        let rows = [displayModel("r1", isUnread: true), displayModel("r2", isUnread: false)]
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(InboxRowDiff.changedRows(in: rows, against: previous).isEmpty)
        // A row the list has never shown is inserted by the diff, not
        // reconfigured — asking for both is a UIKit exception waiting to happen.
        let arrival = rows + [displayModel("r3", isUnread: true)]
        #expect(InboxRowDiff.changedRows(in: arrival, against: previous).isEmpty)
    }

    @Test func openingARequestRoutesToItsThread() async {
        let router = SpyRouter()
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [conversation("r1", peer: "a")]),
            relations: StubRelations()
        )
        let requests = MessageRequestsViewModel(catalog: catalog, router: router)
        requests.refresh()
        await settle()

        requests.didSelect(ConversationID("r1"))
        #expect(router.routes == [.conversation(ConversationID("r1"))])
    }
}

// MARK: - Suggestions

@MainActor
struct SuggestionsViewModelTests {
    /// ⚠️ Fixed-duration, and therefore a source of flakiness: it waits for the
    /// CLOCK, not for the work. 50ms was enough until it wasn't — on the first
    /// run after a build, four different tests in this file have been seen to
    /// fail with empty snapshots (the load simply had not landed yet), each
    /// passing on every re-run. The budget is now spread over several rounds,
    /// which covers the observed window with room to spare.
    ///
    /// Prefer `settle(until:)` for anything new: it waits for the condition the
    /// test is actually about, and returns as soon as it holds.
    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func loadIsPerformedOnceOnFirstActivation() async {
        let repository = StubSuggestions(accounts: [account("p1")])
        let viewModel = SuggestionsViewModel(repository: repository)
        var phases: [SuggestionsViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }

        viewModel.loadIfNeeded()
        await settle()
        viewModel.loadIfNeeded()
        await settle()

        #expect(phases.count == 1)
        guard case .content(let rows) = phases.last else {
            Issue.record("expected content, got \(String(describing: phases.last))")
            return
        }
        #expect(rows.map(\.id) == [ProfileID("p1")])
        #expect(rows[0].reasonText == "Follows you")
    }

    @Test func followFlipsImmediatelyAndReachesTheRepository() async {
        let repository = StubSuggestions(accounts: [account("p1")])
        let viewModel = SuggestionsViewModel(repository: repository)
        var phases: [SuggestionsViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.loadIfNeeded()
        await settle()

        viewModel.toggleFollow(ProfileID("p1"))
        // Asserted before any await: an optimistic button doesn't wait.
        guard case .content(let rows) = phases.last else {
            Issue.record("expected content")
            return
        }
        #expect(rows[0].isFollowing)

        await settle()
        #expect(await repository.followed == [ProfileID("p1")])
    }

    @Test func aFailedFollowRollsTheRowBack() async {
        let repository = StubSuggestions(accounts: [account("p1")], shouldFailFollow: true)
        let viewModel = SuggestionsViewModel(repository: repository)
        var phases: [SuggestionsViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.loadIfNeeded()
        await settle()

        viewModel.toggleFollow(ProfileID("p1"))
        await settle()

        guard case .content(let rows) = phases.last else {
            Issue.record("expected content")
            return
        }
        #expect(!rows[0].isFollowing)
        #expect(!viewModel.isFollowing(ProfileID("p1")))
    }

    @Test func dismissingRemovesTheRowAndEmptiesTheSurface() async {
        let viewModel = SuggestionsViewModel(repository: StubSuggestions(accounts: [account("p1")]))
        var phases: [SuggestionsViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.loadIfNeeded()
        await settle()

        viewModel.dismiss(ProfileID("p1"))
        #expect(phases.last == .empty)
    }

    @Test func messagingASuggestionRoutesStraightToTheThread() async {
        let router = SpyRouter()
        let viewModel = SuggestionsViewModel(
            repository: StubSuggestions(accounts: [account("p1")]), router: router
        )
        viewModel.loadIfNeeded()
        await settle()

        viewModel.message(ProfileID("p1"))
        viewModel.didSelect(ProfileID("p1"))
        // The DM route carries the row's identity: the thread is pushed before
        // its conversation is known to exist, so the header has nothing else to
        // render from until the find-or-create lands.
        #expect(router.routes == [
            .messageUser(ProfileID("p1"), stub: ProfileIdentityStub(handle: "p1", displayName: "Name p1")),
            .profile(ProfileID("p1"), stub: nil)
        ])
    }
}

// MARK: - Request row content

@MainActor
struct MessageRequestCellTests {
    private func model(
        preview: String,
        title: String = "Ava Moreau",
        hasActivity: Bool = true
    ) -> ConversationDisplayModel {
        ConversationDisplayModel(
            conversation: Conversation(
                id: ConversationID("c1"),
                title: title,
                lastMessage: preview,
                lastActivityAt: hasActivity ? Date(timeIntervalSince1970: 0) : nil,
                otherMemberIDs: [ProfileID("peer-1")]
            ),
            now: Date(timeIntervalSince1970: 3600)
        )
    }

    @Test func aRequestWithAMessageShowsIt() {
        #expect(MessageRequestCell.previewText(for: model(preview: "Any chance you sell prints?"))
            == "Any chance you sell prints?")
    }

    /// A request usually IS its first message. With nothing to show, the row
    /// says what it is rather than leaving the second line blank — the
    /// two-line silhouette is fixed, so an empty preview would read as a
    /// rendering bug.
    @Test func aRequestWithNoMessageStillFillsItsSecondLine() {
        #expect(MessageRequestCell.previewText(for: model(preview: "")) == "Wants to send you a message")
    }

    /// The timestamp reads as part of the name phrase ("Ava Moreau · 1h"), so
    /// it carries its own separator.
    @Test func theTimestampCarriesItsSeparator() {
        #expect(MessageRequestCell.timestampText(for: model(preview: "hi")) == "· 1h")
    }

    /// With no activity there is no timestamp — and therefore no orphaned
    /// separator dangling after the name.
    @Test func aConversationWithNoActivityHasNoTimestampAtAll() {
        #expect(MessageRequestCell.timestampText(for: model(preview: "hi", hasActivity: false)) == nil)
    }
}

// MARK: - List sections

/// The split, and the one property that makes it trustworthy: the first
/// section's row count IS the tab badge's number.
@MainActor
struct InboxListSectionTests {
    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Section one and the badge come from one watermark in one view model, so
    /// they cannot disagree — this is the assertion that says so out loud.
    @Test func theFirstSectionHoldsExactlyWhatTheBadgeCounts() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("r1", peer: "a"), conversation("r2", peer: "b")
            ]),
            relations: StubRelations()
        )
        let requests = MessageRequestsViewModel(
            catalog: catalog, now: { Date(timeIntervalSince1970: -1) }
        )
        var phase: MessageRequestsViewModel.Phase?
        requests.onPhaseChange = { phase = $0 }
        requests.refresh()
        await settle()

        guard case .content(let sections) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        #expect(sections.new.count == requests.newCount)
        #expect(sections.earlier.isEmpty)
    }

    /// Nothing new means ONE section, not an empty header over the list.
    @Test func anInboxWithNoArrivalsIsASingleSection() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("r1", peer: "a"), conversation("r2", peer: "b")
            ]),
            relations: StubRelations()
        )
        // A `now` after the fixtures' activity: they were already there.
        let requests = MessageRequestsViewModel(
            catalog: catalog, now: { Date(timeIntervalSince1970: 10_000) }
        )
        var phase: MessageRequestsViewModel.Phase?
        requests.onPhaseChange = { phase = $0 }
        requests.refresh()
        await settle()

        guard case .content(let sections) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        #expect(sections.new.isEmpty)
        #expect(sections.earlier.count == 2)
        #expect(requests.newCount == 0)
    }

    /// The split preserves the list's order, so a row does not jump when it
    /// crosses between sections.
    @Test func theSplitKeepsTheListsOrder() {
        let rows = ["a", "b", "c", "d"].map {
            ConversationDisplayModel(conversation: conversation($0), isUnread: $0 < "c")
        }
        let sections = InboxListSections(rows: rows, isNew: \.isUnread)

        #expect(sections.new.map(\.id) == [ConversationID("a"), ConversationID("b")])
        #expect(sections.earlier.map(\.id) == [ConversationID("c"), ConversationID("d")])
        #expect(sections.all.map(\.id) == rows.map(\.id))
    }
}

// MARK: - Avatar badge

/// The pill on a conversation's avatar. Its geometry is otherwise only
/// checkable by measuring a screenshot, and every failure here still renders
/// something badge-shaped.
@MainActor
struct BadgedAvatarViewTests {
    private func laidOut(_ style: BadgedAvatarView.Style) -> CGSize {
        let view = BadgedAvatarView()
        view.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        view.setBadge(style)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view.badgeSize
    }

    /// One digit is a CIRCLE: the height floor wins, because a capsule narrower
    /// than it is tall has a corner radius exceeding half its width and
    /// degenerates — the same floor the tab capsule's lens states.
    @Test func aSingleDigitDrawsACircle() {
        let size = laidOut(.count(3))
        #expect(size.width == size.height)
    }

    /// Two digits WIDEN it — that is the whole reason it is a capsule — without
    /// changing its height, so a row whose count crosses ten does not move.
    @Test func aSecondDigitWidensThePillWithoutHeighteningIt() {
        let one = laidOut(.count(3))
        let two = laidOut(.count(11))

        #expect(two.width > one.width)
        #expect(two.height == one.height)
    }

    /// Past 99 the text stops growing, so the pill stops too rather than
    /// running across the face behind it.
    @Test func theCountSaturatesRatherThanGrowingWithoutBound() {
        let hundred = laidOut(.count(100))
        let thousand = laidOut(.count(4_000))

        #expect(hundred.width == thousand.width)
    }

    /// A dot is the same height as a count — they occupy one slot, so a surface
    /// switching between them cannot shift the avatar beneath.
    @Test func aDotMatchesACountsHeight() {
        #expect(laidOut(.dot).height == laidOut(.count(1)).height)
        #expect(laidOut(.dot).width == laidOut(.dot).height)
    }
}

// MARK: - Tab watermark

/// The rule the tab badges are built on, in isolation from any view model.
struct InboxTabWatermarkTests {
    private let opened = Date(timeIntervalSince1970: 1_000)

    private func conversationAt(_ seconds: TimeInterval) -> Conversation {
        conversation("c", activityAt: Date(timeIntervalSince1970: seconds))
    }

    /// A first sight is never "all new": whatever was already there when the
    /// app opened is not an arrival. The trap `ForYouUnread` documents, and the
    /// reason the baseline starts at the opening moment rather than at zero.
    @Test func nothingAlreadyOnScreenCountsAsNew() {
        let watermark = InboxTabWatermark(openedAt: opened)
        #expect(watermark.newCount(in: [conversationAt(500), conversationAt(999)]) == 0)
    }

    @Test func anArrivalAfterTheBaselineCounts() {
        let watermark = InboxTabWatermark(openedAt: opened)
        #expect(watermark.newCount(in: [conversationAt(1_001), conversationAt(500)]) == 1)
    }

    /// A conversation with no activity has no arrival time, so it is a row that
    /// has always been there rather than a new one.
    @Test func aConversationWithNoActivityIsNeverNew() {
        let watermark = InboxTabWatermark(openedAt: opened)
        #expect(watermark.newCount(in: [conversation("c", hasActivity: false)]) == 0)
    }

    /// The count and the row marks are one question asked of one instant, so
    /// they always agree about a given row.
    @Test func theCountAndTheRowMarksAgree() {
        let watermark = InboxTabWatermark(openedAt: opened)
        let arrival = conversationAt(1_500)
        let old = conversationAt(500)

        #expect(watermark.newCount(in: [arrival, old]) == 1)
        #expect(watermark.isNewOnRow(arrival))
        #expect(!watermark.isNewOnRow(old))
    }

    /// ⚠️ There is NO way to move the baseline, and that is the design: nothing
    /// in a session retires a badge, so the only reset is a cold launch
    /// building a new watermark. This asserts the absence of the mutation two
    /// earlier designs had — clearing on selection, then on leaving the screen —
    /// both of which took the count away as a side effect of an action the
    /// viewer took for some other reason.
    @Test func anArrivalStaysNewForTheWholeSession() {
        let watermark = InboxTabWatermark(openedAt: opened)
        let arrival = conversationAt(1_500)

        #expect(watermark.newCount(in: [arrival]) == 1)
        #expect(watermark.isNewOnRow(arrival))
        #expect(watermark.newCount(in: [arrival]) == 1)
    }
}

// MARK: - Pager

@MainActor
struct InboxPagerTests {
    private func makePager(pages: Int = 3, width: CGFloat = 300) -> InboxPagerView {
        let pager = InboxPagerView(pages: (0..<pages).map { _ in UIView() })
        pager.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// A header tap sets the TARGET page up front. Settling must still be
    /// reported, or the destination surface is never woken and never publishes
    /// its chrome — the whole tab would page visually and do nothing else.
    @Test func programmaticPagingReportsItsSettle() {
        let pager = makePager()
        var settled: [Int] = []
        pager.onSettled = { settled.append($0) }

        pager.setActivePage(1, animated: false)

        #expect(settled == [1])
        #expect(pager.activeIndex == 1)
    }

    /// ⚠️ A page chosen BEFORE the pager has ever been laid out — which is
    /// every launch-time route, `-open-messages requests` and push payloads
    /// alike — still has to be the page on screen once there is a screen.
    ///
    /// A zero-width pager has no offset to scroll to, so `setActivePage` can
    /// only record the index and wait. Nothing used to pick it back up: the
    /// header's lens sat on the routed tab while the first tab's list stayed
    /// visible, and only a manual swipe reconciled them.
    @Test func aPageChosenBeforeLayoutIsTheOneShownAfterIt() {
        let pager = InboxPagerView(pages: (0..<3).map { _ in UIView() })
        var reported: [CGFloat] = []
        pager.onProgress = { reported.append($0) }

        pager.setActivePage(1, animated: false)
        #expect(pager.pagingScrollView.contentOffset.x == 0)

        pager.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        pager.layoutIfNeeded()

        #expect(pager.pagingScrollView.contentOffset.x == 300)
        // The lens is told too — a page the header disagrees with is the same
        // bug wearing the other half of its face.
        #expect(reported.last == 1)
    }

    /// Rotation moves the offset a page index does not: the same index is a
    /// different number of points at a different width.
    @Test func aWidthChangeKeepsTheActivePageAligned() {
        let pager = makePager(width: 300)
        pager.setActivePage(2, animated: false)
        #expect(pager.pagingScrollView.contentOffset.x == 600)

        pager.frame = CGRect(x: 0, y: 0, width: 500, height: 600)
        pager.layoutIfNeeded()

        #expect(pager.pagingScrollView.contentOffset.x == 1000)
    }

    /// Progress is continuous, not stepped: it is what the header interpolates
    /// the lens's frame against.
    @Test func progressReportsFractionalPositions() {
        let pager = makePager(width: 300)
        var reported: [CGFloat] = []
        pager.onProgress = { reported.append($0) }

        pager.pagingScrollView.contentOffset = CGPoint(x: 150, y: 0)

        #expect(reported.last == 0.5)
    }

    @Test func settleIsNotRepeatedForTheSamePage() {
        let pager = makePager()
        var settled: [Int] = []
        pager.setActivePage(2, animated: false)
        pager.onSettled = { settled.append($0) }

        // Landing on the page it is already on reports nothing.
        pager.setActivePage(2, animated: false)

        #expect(settled.isEmpty)
    }
}

// MARK: - Display

struct SuggestionDisplayModelTests {
    @Test func reasonReadsAsASentence() {
        #expect(SuggestionDisplayModel.reasonText(.followsYou) == "Follows you")
        #expect(SuggestionDisplayModel.reasonText(.suggestedForYou) == "Suggested for you")
        #expect(SuggestionDisplayModel.reasonText(.followedBy(names: ["Ava"], total: 1)) == "Followed by Ava")
        #expect(SuggestionDisplayModel.reasonText(.followedBy(names: ["Ava"], total: 3)) == "Followed by Ava + 2")
        // A connector list that never resolved a name is not a reason.
        #expect(SuggestionDisplayModel.reasonText(.followedBy(names: [], total: 4)) == "Suggested for you")
    }

    @Test func handleIsPrefixedAndEmptyHandlesStayEmpty() {
        let named = SuggestionDisplayModel(account: account("p1"), isFollowing: false)
        #expect(named.handleText == "@p1")
        #expect(named.monogram == "NP") // "Name p1"

        let anonymous = SuggestedAccount(
            id: ProfileID("p2"), handle: "", displayName: "Zed", avatarURL: nil, reason: .suggestedForYou
        )
        #expect(SuggestionDisplayModel(account: anonymous, isFollowing: true).handleText.isEmpty)
    }
}
