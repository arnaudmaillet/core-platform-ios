import CoreModels
import CoreNavigation
import Foundation

/// The Channels tab's view model (#2215): the channels the viewer runs or
/// follows, from the inbox's shared catalog (its Channels folder), with —
/// for the ones the viewer runs — their pending join requests counted into
/// ONE row at the top.
///
/// The rows are the catalog's, so a post from a channel's thread, a mute or
/// a leave shows here as it does everywhere; only the request count is
/// asked here, one `joinRequests` per channel the viewer runs.
@MainActor
final class ChannelsViewModel {
    nonisolated enum Item: Hashable, Sendable {
        /// "3 requests to join": the requests list.
        case joinRequests
        /// "Create a Channel".
        case create
        case channel(ConversationID)
    }

    nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([Item])
        /// No channel: what channels are, with "Create a Channel".
        case empty
        case failed(String)
    }

    /// A channel the viewer runs, for the requests list.
    nonisolated struct RunChannel: Equatable, Sendable {
        let id: ConversationID
        let name: String
        let photoURL: URL?
    }

    var onPhaseChange: ((Phase) -> Void)?
    /// How many channels have news since the app opened, for the tab's
    /// badge — the watermark every inbox tab counts with.
    var onNewCountChange: ((Int) -> Void)?

    private(set) var phase: Phase = .loading { didSet { if phase != oldValue { onPhaseChange?(phase) } } }
    private(set) var newCount = 0 { didSet { if newCount != oldValue { onNewCountChange?(newCount) } } }
    /// The rows, by id, as the list draws them.
    private(set) var rows: [ConversationID: ConversationDisplayModel] = [:]
    /// Pending requests across the channels the viewer runs.
    var requestCount: Int { requestCounts.values.reduce(0, +) }
    /// Pending requests per channel the viewer runs, as last counted.
    private(set) var requestCounts: [ConversationID: Int] = [:]
    /// The names of the channels with a request waiting, in the list's
    /// order — what the requests row names (#2215 follow-up).
    var requestingChannelNames: [String] {
        runChannels.filter { (requestCounts[$0.id] ?? 0) > 0 }.map(\.name)
    }
    /// The channels the viewer runs, in the list's order.
    private(set) var runChannels: [RunChannel] = []
    private(set) var hasMore = false

    private let catalog: InboxCatalog
    private let service: (any ConversationManaging)?
    private let router: (any Router)?
    private let now: @Sendable () -> Date
    private var observation: InboxCatalog.ObservationToken?
    private let watermark: InboxTabWatermark
    private var snapshot = InboxCatalog.Snapshot()
    /// The channels whose requests were counted last, so a snapshot that
    /// leaves them alone asks nothing.
    private var countedFor: [ConversationID] = []
    private var countLoad: Task<Void, Never>?

    init(
        catalog: InboxCatalog,
        service: (any ConversationManaging)?,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.service = service
        self.router = router
        self.now = now
        watermark = InboxTabWatermark(openedAt: now())
        observation = catalog.observe { [weak self] snapshot in self?.project(snapshot) }
    }

    // MARK: - Projection

    /// What the list shows (#2215), in order: the requests row while any
    /// wait, "Create a Channel", then every channel. Nothing for no channel —
    /// the empty state carries the creation instead. Pure, for tests.
    nonisolated static func items(channels: [ConversationID], requestCount: Int) -> [Item] {
        guard !channels.isEmpty else { return [] }
        return (requestCount > 0 ? [.joinRequests] : []) + [.create] + channels.map(Item.channel)
    }

    /// The channels of `rows` the viewer runs (#2215).
    nonisolated static func runChannels(in rows: [Conversation]) -> [RunChannel] {
        rows.compactMap { row in
            guard let identity = row.identity, identity.viewerState.runsChannel else { return nil }
            return RunChannel(id: row.id, name: row.title, photoURL: identity.photoURL)
        }
    }

    private func project(_ next: InboxCatalog.Snapshot) {
        snapshot = next
        let channels = next.channels
        let date = now()
        rows = Dictionary(channels.map { row in
            (row.id, ConversationDisplayModel(
                conversation: row, now: date, isMuted: next.muted.contains(row.id),
                isUnread: next.unreadIDs.contains(row.id),
                unreadCount: next.unreadIDs.contains(row.id) ? row.unreadCount : 0
            ))
        }, uniquingKeysWith: { first, _ in first })
        runChannels = Self.runChannels(in: channels)
        hasMore = next.hasMore.contains(.channels)
        newCount = watermark.newCount(in: channels.filter { next.unreadIDs.contains($0.id) })
        countRequestsIfNeeded()
        render()
    }

    private func render() {
        let channels = snapshot.channels.map(\.id)
        switch snapshot.phase {
        case .loading where channels.isEmpty:
            phase = .loading
        case .failed(let message) where channels.isEmpty:
            phase = .failed(message)
        default:
            phase = channels.isEmpty ? .empty : .content(Self.items(channels: channels, requestCount: requestCount))
        }
    }

    // MARK: - Join requests

    /// The requests waiting on the channels the viewer runs, counted again
    /// when that set changes.
    private func countRequestsIfNeeded() {
        let ids = runChannels.map(\.id)
        guard ids != countedFor else { return }
        countedFor = ids
        refreshRequests()
    }

    /// Counts the pending requests again — after the requests list answered
    /// some, or when the tab comes back.
    func refreshRequests() {
        countLoad?.cancel()
        guard let service, !countedFor.isEmpty else {
            requestCounts = [:]
            render()
            return
        }
        let ids = countedFor
        countLoad = Task { [weak self] in
            let counts = await Self.countRequests(on: ids, service: service)
            guard let self, !Task.isCancelled else { return }
            self.requestCounts = counts
            self.render()
        }
    }

    /// The pending requests on each of `ids`, asked concurrently; a channel
    /// whose answer failed counts none.
    nonisolated private static func countRequests(
        on ids: [ConversationID], service: any ConversationManaging
    ) async -> [ConversationID: Int] {
        await withTaskGroup(of: (ConversationID, Int).self) { group in
            for id in ids {
                group.addTask { (id, (try? await service.joinRequests(to: id).count) ?? 0) }
            }
            var counts: [ConversationID: Int] = [:]
            for await (id, count) in group { counts[id] = count }
            return counts
        }
    }

    // MARK: - Intents

    func didSelect(_ id: ConversationID) {
        router?.route(to: .conversation(id))
    }

    func refresh() { catalog.refresh() }
    func retry() { catalog.reload() }
    func loadMore() { catalog.loadMore(.channels) }

    /// The row's mute, the inbox's (#719).
    func toggleMute(_ id: ConversationID) { catalog.toggleMute(id) }
}
