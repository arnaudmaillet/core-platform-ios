import CoreModels
import Foundation

/// A channel the viewer runs — owner or admin (#2215): what the join
/// requests list is opened on.
struct RunChannel: Equatable, Sendable {
    let id: ConversationID
    let name: String
    let photoURL: URL?
}

/// The join requests waiting on the channels the viewer runs, per channel
/// (#2230): what Requests' "Join requests" section lists, one row each, and
/// what its badge adds — one per request, as a message request counts one
/// (#2171).
///
/// They moved here from the Channels tab's single row (#2215) when the tab
/// went: a request to join waits on the viewer, as a message request does,
/// and Requests is where the inbox keeps what waits.
///
/// The channels come from the inbox's shared catalog (Chats lists them);
/// only the counts are asked here — one `joinRequests` per channel the
/// viewer runs, again when that set changes, and on `refresh()` (the page
/// coming back, the requests list having answered some).
@MainActor
final class ChannelJoinRequestsDigest {
    /// A channel with requests waiting, and how many.
    nonisolated struct Entry: Equatable, Sendable, Identifiable {
        let channel: RunChannel
        let count: Int
        var id: ConversationID { channel.id }
    }

    /// The channels with at least one request waiting, in Chats' order. A
    /// channel whose requests were all answered is not here.
    private(set) var entries: [Entry] = [] {
        didSet { if entries != oldValue { onChange?() } }
    }
    /// Every request waiting, across the channels the viewer runs.
    var total: Int { entries.reduce(0) { $0 + $1.count } }
    /// The entries changed.
    var onChange: (() -> Void)?

    private let service: any ConversationManaging
    private var observation: InboxCatalog.ObservationToken?
    /// The channels the viewer runs, as last seen in the catalog.
    private(set) var runChannels: [RunChannel] = []
    /// The counts as last answered, per channel.
    private var counts: [ConversationID: Int] = [:]
    /// The channels counted last, so a snapshot that leaves them alone asks
    /// nothing.
    private var countedFor: [ConversationID] = []
    private var countLoad: Task<Void, Never>?

    init(catalog: InboxCatalog, service: any ConversationManaging) {
        self.service = service
        observation = catalog.observe { [weak self] snapshot in self?.project(snapshot) }
    }

    /// The channels of `rows` the viewer runs (#2215), in their order.
    nonisolated static func runChannels(in rows: [Conversation]) -> [RunChannel] {
        rows.compactMap { row in
            guard row.kind == .channel, let identity = row.identity, identity.viewerState.runsChannel else { return nil }
            return RunChannel(id: row.id, name: row.title, photoURL: identity.photoURL)
        }
    }

    /// The channels of `channels` with requests waiting, in their order.
    /// Pure, for tests.
    nonisolated static func entries(_ channels: [RunChannel], counts: [ConversationID: Int]) -> [Entry] {
        channels.compactMap { channel in
            let count = counts[channel.id] ?? 0
            return count > 0 ? Entry(channel: channel, count: count) : nil
        }
    }

    private func project(_ snapshot: InboxCatalog.Snapshot) {
        runChannels = Self.runChannels(in: snapshot.active)
        let ids = runChannels.map(\.id)
        if ids != countedFor {
            countedFor = ids
            refresh()
        } else {
            // Same channels, maybe renamed: the rows say the new names.
            entries = Self.entries(runChannels, counts: counts)
        }
    }

    /// Counts the waiting requests again.
    func refresh() {
        countLoad?.cancel()
        let ids = countedFor
        guard !ids.isEmpty else {
            counts = [:]
            entries = []
            return
        }
        let requestService = service
        countLoad = Task { [weak self] in
            let answered = await Self.countRequests(on: ids, service: requestService)
            guard let self, !Task.isCancelled else { return }
            self.counts = answered
            self.entries = Self.entries(self.runChannels, counts: answered)
        }
    }

    /// The waiting requests on each of `ids`, asked concurrently; a channel
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
}
