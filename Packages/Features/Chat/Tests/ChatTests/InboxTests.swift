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
        isUnread: isUnread
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
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
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

    @Test func unreadIsTheUnreadSubsetOfTheActiveList() async {
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
        #expect(latest?.unreadIDs == [ConversationID("unread")])
        #expect(latest?.requests.map(\.id) == [ConversationID("unread-request")])
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

    @Test func clearingAllRequestsEmptiesThemInOneProjection() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("r1", peer: "a"), conversation("r2", peer: "b"),
                conversation("active", peer: "friend", lastMessageIsMine: true)
            ]),
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        var emissions = 0
        var latest: InboxCatalog.Snapshot?
        let token = catalog.observe { latest = $0; emissions += 1 }
        catalog.reload()
        await settle()
        let before = emissions

        catalog.declineAll()

        #expect(latest?.requests.isEmpty == true)
        #expect(latest?.active.map(\.id) == [ConversationID("active")]) // untouched
        #expect(emissions == before + 1) // one projection, not one per request
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
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
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
        #expect(requests.count == 1)

        requests.accept(ConversationID("request"))
        guard case .content(let rows) = listPhase else {
            Issue.record("expected content, got \(String(describing: listPhase))")
            return
        }
        #expect(rows.map(\.id) == [ConversationID("request")])
        #expect(requestsPhase == .empty)
        #expect(requests.count == 0)
    }

    /// Unread is marked IN the All list now, not split into a tab: the rows
    /// stay put and carry a flag, and the count rides the All tab.
    @Test func unreadRowsAreFlaggedInPlaceAndCounted() async {
        let provider = StubInboxProvider(conversations: [
            conversation("read", peer: "friend"),
            conversation("unread", peer: "friend", isUnread: true)
        ])
        let catalog = InboxCatalog(
            repository: provider,
            relations: StubRelations(followed: [ProfileID("friend")])
        )
        let list = ConversationListViewModel(catalog: catalog)
        var counts: [Int] = []
        var phase: ConversationListViewModel.Phase?
        list.onUnreadCountChange = { counts.append($0) }
        list.onPhaseChange = { phase = $0 }

        list.viewWillAppear()
        await settle()

        guard case .content(let rows) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        // Both rows are present; only one is flagged.
        #expect(rows.map(\.id) == [ConversationID("read"), ConversationID("unread")])
        #expect(rows.map(\.isUnread) == [false, true])
        #expect(counts == [1])
        #expect(list.unreadCount == 1)
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

        guard case .content(let rows) = phase else {
            Issue.record("expected content, got \(String(describing: phase))")
            return
        }
        #expect(rows.count == 2)
        #expect(rows.map(\.isUnread) == [false, true])
        #expect(list.unreadCount == 1)
    }

    @Test func requestCountEmitsForTheHeaderBadge() async {
        let catalog = InboxCatalog(
            repository: StubInboxProvider(conversations: [
                conversation("r1", peer: "a"), conversation("r2", peer: "b")
            ]),
            relations: StubRelations()
        )
        let requests = MessageRequestsViewModel(catalog: catalog)
        var counts: [Int] = []
        requests.onCountChange = { counts.append($0) }
        requests.refresh()
        await settle()

        #expect(counts == [2])
        requests.decline(ConversationID("r1"))
        #expect(counts == [2, 1])
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
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
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
        #expect(router.routes == [.messageUser(ProfileID("p1")), .profile(ProfileID("p1"), stub: nil)])
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

// MARK: - Batch pin resolution

struct BatchPinActionTests {
    private func resolve(_ ids: [String], pinned: Set<String>) -> BatchPinAction {
        BatchPinAction.resolve(selected: ids.map { ConversationID($0) }) { pinned.contains($0.rawValue) }
    }

    @Test func anAllUnpinnedSelectionOffersPin() {
        #expect(resolve(["a", "b"], pinned: []) == .pin)
        #expect(resolve(["a", "b"], pinned: []).title == "Pin")
    }

    @Test func anAllPinnedSelectionOffersUnpin() {
        #expect(resolve(["a", "b"], pinned: ["a", "b"]) == .unpin)
        #expect(resolve(["a", "b"], pinned: ["a", "b"]).title == "Unpin")
    }

    /// The rule that matters: neither verb is honest about a mixed selection —
    /// "Pin" would skip the pinned rows and "Unpin" would silently drop pins
    /// the viewer never chose to lose. The button withdraws instead.
    @Test func aMixedSelectionOffersNothing() {
        #expect(resolve(["a", "b"], pinned: ["a"]) == .unavailable)
        #expect(resolve(["a", "b", "c"], pinned: ["b"]) == .unavailable)
        #expect(resolve(["a", "b", "c"], pinned: ["a", "c"]) == .unavailable)
        #expect(resolve(["a", "b"], pinned: ["a"]).title == nil)
    }

    @Test func anEmptySelectionOffersNothing() {
        #expect(resolve([], pinned: []) == .unavailable)
        #expect(resolve([], pinned: ["a"]) == .unavailable)
    }

    @Test func aSingleRowResolvesByItsOwnState() {
        #expect(resolve(["a"], pinned: []) == .pin)
        #expect(resolve(["a"], pinned: ["a"]) == .unpin)
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
