import CacheKit
import CoreModels
import CoreNetworking
import Foundation
import LocalStore
import Synchronization
import Testing
@testable import Chat

// The inbox and the last conversations on the device (#897): a cold start
// opens on them offline, then revalidates; paging goes on from the stored
// cursors; a sent message is one row with the load that carries it; another
// viewer reads none of it.

private let alice = LocalStoreViewer.member(account: "acct-alice", profile: "prof-alice")
private let bob = LocalStoreViewer.member(account: "acct-bob", profile: "prof-bob")

/// Who is using the app, as a test sets it (the app's `StorageScope`).
private final class ViewerBox: Sendable {
    private let current = Mutex<LocalStoreViewer?>(alice)

    var viewer: LocalStoreViewer? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

/// A private folder per test, deleted with it: the device across launches.
private final class DeviceFolder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ChatLocalCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }
}

private func row(_ id: String, at seconds: TimeInterval, unread: Bool = false) -> Conversation {
    Conversation(
        id: ConversationID(id), title: "Title \(id)", lastMessage: "last in \(id)",
        lastActivityAt: Date(timeIntervalSince1970: seconds), otherMemberIDs: [ProfileID("peer-\(id)")],
        directPeerHandle: "peer\(id)", lastMessageID: "\(id)-latest", isUnread: unread, unreadCount: unread ? 2 : 0
    )
}

private func message(_ index: Int, mine: Bool = false) -> ChatMessage {
    ChatMessage(
        id: String(format: "m%03d", index), senderID: ProfileID(mine ? "me" : "them"), body: "message \(index)",
        createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)), isMine: mine
    )
}

private func messages(_ range: ClosedRange<Int>) -> [ChatMessage] { range.map { message($0) } }

private func ids(_ range: ClosedRange<Int>) -> [String] { range.map { String(format: "m%03d", $0) } }

/// The network: each folder's and each history page by token, or no
/// network at all.
private actor DeviceTestNetwork: ChatProviding {
    private var inbox: [InboxFolder: [String?: InboxPage]] = [:]
    private var history: [String?: MessagePage] = [:]
    private var offline = false
    private var sentID = "m900"
    private(set) var inboxAsks: [(InboxFolder, String?)] = []
    private(set) var historyAsks: [String?] = []

    func goOffline(_ value: Bool) { offline = value }
    func setInbox(_ page: InboxPage, of folder: InboxFolder, for token: String? = nil) { inbox[folder, default: [:]][token] = page }
    func setHistory(_ page: MessagePage, for token: String? = nil) { history[token] = page }
    func setSentID(_ id: String) { sentID = id }

    private func checkOnline() throws {
        if offline { throw ChatError.transport(message: "offline", failure: .offline) }
    }

    func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        inboxAsks.append((folder, pageToken))
        try checkOnline()
        return inbox[folder]?[pageToken] ?? InboxPage(conversations: [], nextPageToken: nil)
    }

    func loadMessagesPage(in conversationID: ConversationID, before pageToken: String?) async throws -> MessagePage {
        historyAsks.append(pageToken)
        try checkOnline()
        return history[pageToken] ?? MessagePage(messages: [], olderPageToken: nil)
    }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { [] }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        try checkOnline()
        return ChatMessage(id: sentID, senderID: ProfileID("me"), body: body, createdAt: Date(timeIntervalSince1970: 5_000), isMine: true)
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
}

@MainActor
struct ChatLocalCacheTests {
    private let folder = DeviceFolder()
    private let viewer = ViewerBox()
    private let conversation = ConversationID("conv-1")

    /// A ceiling, not a pace: returns as soon as `condition` holds.
    private func settle(until condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The device as a launch opens it: the same folder, a fresh store.
    private func launch() throws -> (LocalStore, ChatLocalCache) {
        let box = viewer
        let store = try LocalStore(directory: folder.url, viewer: { box.viewer })
        return (store, ChatLocalCache(store: store))
    }

    private func catalog(_ network: DeviceTestNetwork, _ cache: ChatLocalCache) -> InboxCatalog {
        let catalog = InboxCatalog(repository: network, deviceCache: cache)
        catalog.connectivity = ConnectivityMonitor(offlineGrace: 0)
        return catalog
    }

    private final class Transcript {
        var ids: [String] = []
        var phase: ConversationViewModel.Phase = .loading
    }

    private func openThread(_ network: DeviceTestNetwork, _ cache: ChatLocalCache) -> (ConversationViewModel, Transcript) {
        let viewModel = ConversationViewModel(conversationID: conversation, repository: network)
        viewModel.deviceCache = cache
        viewModel.connectivity = ConnectivityMonitor(offlineGrace: 0)
        let shown = Transcript()
        viewModel.onPhaseChange = { phase in
            shown.phase = phase
            if case .content(let models) = phase { shown.ids = models.map(\.id) }
        }
        return (viewModel, shown)
    }

    /// A first launch online: the inbox (two pages of All, one of Requests)
    /// and a thread (its newest page and one older) land on the device.
    private func firstLaunchOnline() async throws -> DeviceTestNetwork {
        let network = DeviceTestNetwork()
        await network.setInbox(InboxPage(conversations: [row("c1", at: 30, unread: true), row("c2", at: 20)], nextPageToken: "t1"), of: .inbox)
        await network.setInbox(InboxPage(conversations: [row("c3", at: 10)], nextPageToken: "t2"), of: .inbox, for: "t1")
        await network.setInbox(InboxPage(conversations: [row("r1", at: 25)], nextPageToken: nil), of: .requests)
        await network.setHistory(MessagePage(messages: messages(150...199), olderPageToken: "h150"))
        await network.setHistory(MessagePage(messages: messages(100...149), olderPageToken: "h100"), for: "h150")

        let (_, cache) = try launch()
        let inbox = catalog(network, cache)
        inbox.reload()
        await settle { inbox.snapshot.phase == .loaded }
        inbox.loadMore(.inbox)
        await settle { inbox.snapshot.active.count == 3 }

        let (thread, shown) = openThread(network, cache)
        thread.viewDidLoad()
        await settle { shown.ids.count == 50 }
        thread.loadOlder()
        await settle { shown.ids.count == 100 }
        cache.waitForPendingWrites()
        return network
    }

    // MARK: - Cold start

    @Test func theInboxOpensOnItsLastRowsOfflineAtTheFirstFrameThenRevalidates() async throws {
        let network = try await firstLaunchOnline()
        await network.goOffline(true)

        let (_, cache) = try launch()
        let inbox = catalog(network, cache)
        var first: InboxCatalog.Snapshot?
        let token = inbox.observe { snapshot in if first == nil { first = snapshot } }
        // In the first frame: no load has answered, nothing awaited.
        #expect(first?.phase == .loaded)
        #expect(first?.active.map(\.id.rawValue) == ["c1", "c2", "c3"])
        #expect(first?.requests.map(\.id.rawValue) == ["r1"])
        #expect(first?.unreadIDs == [ConversationID("c1")])
        #expect(first?.active.first == row("c1", at: 30, unread: true), "every field of the row comes back")

        // Offline, the failed load leaves the stored rows on screen.
        inbox.reload()
        await settle { await network.inboxAsks.count >= 7 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(inbox.snapshot.phase == .loaded)
        #expect(inbox.snapshot.active.count == 3)
        #expect(inbox.showsDeviceRows)

        // Back online: the rows revalidate in place.
        await network.setInbox(InboxPage(conversations: [row("c4", at: 40), row("c1", at: 30)], nextPageToken: "t1"), of: .inbox)
        await network.goOffline(false)
        inbox.reload()
        await settle { inbox.snapshot.active.first?.id.rawValue == "c4" }
        #expect(inbox.snapshot.active.map(\.id.rawValue) == ["c4", "c1", "c2", "c3"], "merged over the stored rows older than it")
        #expect(!inbox.showsDeviceRows)
        withExtendedLifetime(token) {}
    }

    @Test func pagingGoesOnFromTheStoredCursor() async throws {
        let network = try await firstLaunchOnline()
        let (_, cache) = try launch()
        let inbox = catalog(network, cache)
        let token = inbox.observe { _ in }
        #expect(inbox.snapshot.hasMore.contains(.inbox))
        let before = await network.inboxAsks.count
        inbox.loadMore(.inbox)
        await settle { await network.inboxAsks.count > before }
        let ask = await network.inboxAsks.last
        #expect(ask?.0 == .inbox)
        #expect(ask?.1 == "t2", "the next page after the two stored ones")
        withExtendedLifetime(token) {}
    }

    @Test func aThreadOpensOnItsLastMessagesOfflineThenPagesOnFromTheStoredCursor() async throws {
        let network = try await firstLaunchOnline()
        await network.goOffline(true)

        let (_, cache) = try launch()
        let (thread, shown) = openThread(network, cache)
        thread.viewDidLoad()
        // Inside `viewDidLoad`: the push's first frame shows them.
        #expect(shown.ids == ids(100...199))
        await settle { await network.historyAsks.count >= 3 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(shown.ids == ids(100...199), "offline, the failed load leaves them")
        if case .failed = shown.phase { Issue.record("a failed load must not replace stored messages") }

        // Online: older history goes on from the stored cursor.
        await network.goOffline(false)
        await network.setHistory(MessagePage(messages: messages(50...99), olderPageToken: "h50"), for: "h100")
        thread.loadOlder()
        await settle { shown.ids.count == 150 }
        #expect(await network.historyAsks.last == "h100")
        #expect(shown.ids == ids(50...199))
    }

    @Test func aConversationKeepsItsNewest200Messages() async throws {
        let network = DeviceTestNetwork()
        await network.setHistory(MessagePage(messages: messages(250...299), olderPageToken: "h250"))
        for start in stride(from: 200, through: 50, by: -50) {
            await network.setHistory(
                MessagePage(messages: messages(start...start + 49), olderPageToken: "h\(start)"), for: "h\(start + 50)"
            )
        }
        let (_, cache) = try launch()
        let (thread, shown) = openThread(network, cache)
        thread.viewDidLoad()
        await settle { shown.ids.count == 50 }
        for expected in stride(from: 100, through: 250, by: 50) {
            thread.loadOlder()
            await settle { shown.ids.count == expected }
        }
        #expect(shown.ids.count == 250, "on screen, the whole history read")
        cache.waitForPendingWrites()

        let stored = try #require(cache.transcript(of: conversation))
        #expect(stored.messages.map(\.id) == ids(100...299), "the newest 200 on the device")
        #expect(stored.olderCursor == "h100")
    }

    @Test func aNewestPageWithAGapBehindItReplacesTheStoredMessages() async throws {
        let network = try await firstLaunchOnline()
        // Days later: more new messages than a page.
        await network.setHistory(MessagePage(messages: messages(400...449), olderPageToken: "h400"))
        let (_, cache) = try launch()
        let (thread, shown) = openThread(network, cache)
        thread.viewDidLoad()
        #expect(shown.ids == ids(100...199))
        await settle { shown.ids.first == "m400" }
        #expect(shown.ids == ids(400...449), "no hole between the stored messages and the new ones")
        await network.setHistory(MessagePage(messages: messages(350...399), olderPageToken: "h350"), for: "h400")
        thread.loadOlder()
        await settle { shown.ids.count == 100 }
        #expect(await network.historyAsks.last == "h400")
    }

    // MARK: - Live updates

    @Test func aSentMessageAndTheLoadThatCarriesItAreOneMessage() async throws {
        let network = try await firstLaunchOnline()
        let (_, cache) = try launch()
        let (thread, shown) = openThread(network, cache)
        thread.viewDidLoad()
        await settle { await network.historyAsks.count >= 3 }
        await network.setSentID("m200")
        thread.send("hello")
        await settle { shown.ids.last == "m200" }
        cache.waitForPendingWrites()
        #expect(cache.transcript(of: conversation)?.messages.last?.body == "hello")

        // The next load carries it, as the server stored it.
        await network.setHistory(MessagePage(messages: messages(151...200), olderPageToken: "h151"))
        thread.refresh()
        await settle { await network.historyAsks.count >= 4 }
        try? await Task.sleep(for: .milliseconds(100))
        cache.waitForPendingWrites()
        let stored = try #require(cache.transcript(of: conversation))
        #expect(stored.messages.filter { $0.id == "m200" }.count == 1)
        #expect(stored.messages.map(\.id) == ids(100...200))
        #expect(shown.ids.filter { $0 == "m200" }.count == 1)

        // And a relaunch shows it once.
        let (_, relaunched) = try launch()
        let (reopened, reshown) = openThread(network, relaunched)
        await network.goOffline(true)
        reopened.viewDidLoad()
        #expect(reshown.ids == ids(100...200))
    }

    // MARK: - Viewers

    @Test func anotherAccountReadsNoneOfTheConversations() async throws {
        let network = try await firstLaunchOnline()
        await network.goOffline(true)
        // Logout, then sign-in as someone else.
        viewer.viewer = .guest
        viewer.viewer = bob

        let (store, cache) = try launch()
        #expect(cache.folder(.inbox) == nil)
        #expect(cache.folder(.requests) == nil)
        #expect(cache.transcript(of: conversation) == nil)

        let inbox = catalog(network, cache)
        var first: InboxCatalog.Snapshot?
        let token = inbox.observe { snapshot in if first == nil { first = snapshot } }
        #expect(first?.phase == .loading)
        #expect(first?.active.isEmpty == true)
        let (thread, shown) = openThread(network, cache)
        thread.viewDidLoad()
        #expect(shown.ids.isEmpty)
        // Back as alice: her rows were wiped, not hidden.
        store.waitForPendingWrites()
        viewer.viewer = alice
        #expect(cache.folder(.inbox) == nil)
        #expect(cache.transcript(of: conversation) == nil)
        withExtendedLifetime(token) {}
    }

    @Test func aLogoutWipeLeavesNothingReadable() async throws {
        _ = try await firstLaunchOnline()
        let (store, cache) = try launch()
        #expect(cache.folder(.inbox) != nil)
        // The coordinator's `.viewerChanged`.
        store.removeAll()
        #expect(cache.folder(.inbox) == nil)
        #expect(cache.transcript(of: conversation) == nil)
    }

    @Test func aViewerChangeInTheSameLaunchNeverRestoresTheDevice() async throws {
        let network = try await firstLaunchOnline()
        let (_, cache) = try launch()
        let inbox = catalog(network, cache)
        let token = inbox.observe { _ in }
        #expect(inbox.snapshot.active.count == 3)
        // A profile switch whose device wipe has not run yet.
        inbox.reset()
        await network.goOffline(true)
        inbox.reload()
        #expect(inbox.snapshot.active.isEmpty, "the previous viewer's rows are never put back")
        await settle {
            if case .failed = inbox.snapshot.phase { return true }
            return false
        }
        #expect(inbox.snapshot.active.isEmpty)
        withExtendedLifetime(token) {}
    }

    @Test func aRecoveryRevalidatesTheDevicesRows() async throws {
        let network = try await firstLaunchOnline()
        await network.goOffline(true)
        let (_, cache) = try launch()
        let monitor = ConnectivityMonitor(offlineGrace: 0)
        let inbox = InboxCatalog(repository: network, deviceCache: cache)
        inbox.connectivity = monitor
        inbox.reload()
        await settle { await network.inboxAsks.count >= 7 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(inbox.showsDeviceRows)

        await network.setInbox(InboxPage(conversations: [row("c9", at: 90)], nextPageToken: nil), of: .inbox)
        await network.goOffline(false)
        monitor.report(online: false)
        monitor.report(online: true)
        await settle { inbox.snapshot.active.first?.id.rawValue == "c9" }
        #expect(!inbox.showsDeviceRows)
    }
}
