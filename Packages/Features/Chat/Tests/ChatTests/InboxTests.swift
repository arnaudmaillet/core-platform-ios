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
    hasActivity: Bool = true
) -> Conversation {
    Conversation(
        id: ConversationID(id),
        title: "Ava",
        lastMessage: "hi",
        lastActivityAt: hasActivity ? Date(timeIntervalSince1970: 0) : nil,
        otherMemberIDs: (peers ?? [peer].compactMap(\.self)).map { ProfileID($0) },
        lastMessageIsMine: lastMessageIsMine
    )
}

private actor StubInboxProvider: ChatProviding {
    var conversations: [Conversation]

    init(conversations: [Conversation]) { self.conversations = conversations }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { conversations }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "m", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
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

    /// The batch action has ONE direction, unlike the row's toggle — a mixed
    /// selection must not unfollow whoever was already followed.
    @Test func batchFollowOnlyFollowsAccountsThatArentFollowed() async {
        let repository = StubSuggestions(accounts: [account("p1"), account("p2")])
        let viewModel = SuggestionsViewModel(repository: repository)
        viewModel.loadIfNeeded()
        await settle()
        viewModel.toggleFollow(ProfileID("p1"))
        await settle()

        viewModel.follow([ProfileID("p1"), ProfileID("p2")])
        await settle()

        #expect(viewModel.isFollowing(ProfileID("p1")))
        #expect(viewModel.isFollowing(ProfileID("p2")))
        #expect(await repository.followed == [ProfileID("p1"), ProfileID("p2")]) // p1 not re-sent
        #expect(await repository.unfollowed.isEmpty)
    }

    @Test func batchDismissRemovesEveryySelectedRowAtOnce() async {
        let viewModel = SuggestionsViewModel(
            repository: StubSuggestions(accounts: [account("p1"), account("p2"), account("p3")])
        )
        var phases: [SuggestionsViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.loadIfNeeded()
        await settle()

        viewModel.dismiss([ProfileID("p1"), ProfileID("p3")])

        guard case .content(let rows) = phases.last else {
            Issue.record("expected content, got \(String(describing: phases.last))")
            return
        }
        #expect(rows.map(\.id) == [ProfileID("p2")])
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
