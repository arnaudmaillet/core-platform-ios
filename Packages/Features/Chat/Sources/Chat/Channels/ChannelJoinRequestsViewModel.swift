import CoreModels
import CoreNetworking
import Foundation

/// The join requests waiting on the channels the viewer runs (#2215): who
/// asked, when, and Approve / Decline — one by one, or all at once. Opened
/// for one channel: from its row in Requests' Join requests section
/// (#2230), or from its info screen.
///
/// An answer leaves the list at once and is written; a refusal puts it back
/// and says so. The server's list is read again after "all".
@MainActor
final class ChannelJoinRequestsViewModel {
    nonisolated struct Row: Equatable, Sendable, Identifiable {
        let id: ProfileID
        let channelID: ConversationID
        let name: String
        let handle: String?
        let avatarURL: URL?
        let requestedAt: Date
    }

    nonisolated struct Group: Equatable, Sendable {
        let channel: RunChannel
        var rows: [Row]
    }

    nonisolated enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    nonisolated struct State: Equatable, Sendable {
        var phase: Phase = .loading
        /// One group per channel with requests, in the channels' order.
        var groups: [Group] = []
        var isWorking = false

        var count: Int { groups.reduce(0) { $0 + $1.rows.count } }
        var isEmpty: Bool { count == 0 }
    }

    var onStateChange: ((State) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Some were answered: Requests' count and the info screen read again.
    var onChange: (() -> Void)?

    private(set) var state = State() { didSet { if state != oldValue { onStateChange?(state) } } }
    let channels: [RunChannel]
    private let service: any GroupChatServicing

    init(channels: [RunChannel], service: any GroupChatServicing) {
        self.channels = channels
        self.service = service
    }

    // MARK: - Reads

    func load() {
        let requestService = service
        let list = channels
        Task { [weak self] in
            var groups: [Group] = []
            var failure: Error?
            for channel in list {
                do {
                    let requests = try await requestService.joinRequests(to: channel.id)
                    guard !requests.isEmpty else { continue }
                    let profiles = await requestService.profiles(requests.map(\.profileID))
                    groups.append(Group(channel: channel, rows: Self.rows(requests, of: channel.id, profiles: profiles)))
                } catch {
                    failure = error
                }
            }
            guard let self else { return }
            if groups.isEmpty, let failure, self.state.phase != .loaded {
                self.state.phase = .failed(FailureCopy.message(for: failure, fallback: "Couldn't load the requests."))
                return
            }
            self.state.groups = groups
            self.state.phase = .loaded
        }
    }

    /// Newest request first, each named as far as profile.v1 says.
    nonisolated static func rows(
        _ requests: [ConversationJoinRequest], of channelID: ConversationID, profiles: [ProfileID: ChatProfile]
    ) -> [Row] {
        requests
            .sorted { $0.requestedAt > $1.requestedAt }
            .map { request in
                let profile = profiles[request.profileID]
                let named = profile.flatMap { $0.name.isEmpty ? $0.handle : $0.name } ?? "Someone"
                return Row(
                    id: request.profileID, channelID: channelID, name: named, handle: profile?.handle,
                    avatarURL: profile?.avatarURL, requestedAt: request.requestedAt
                )
            }
    }

    // MARK: - Answers

    /// Approve (the requester subscribes) or Decline one request.
    func answer(_ profileID: ProfileID, in channelID: ConversationID, approve: Bool) {
        guard let groupIndex = state.groups.firstIndex(where: { $0.channel.id == channelID }),
              let rowIndex = state.groups[groupIndex].rows.firstIndex(where: { $0.id == profileID }) else { return }
        let removed = state.groups[groupIndex].rows.remove(at: rowIndex)
        if state.groups[groupIndex].rows.isEmpty { state.groups.remove(at: groupIndex) }
        let requestService = service
        Task { [weak self] in
            do {
                try await requestService.answerJoinRequest(from: profileID, to: channelID, approve: approve)
                self?.onChange?()
            } catch {
                guard let self else { return }
                self.putBack(removed)
                self.onFailure?(FailureCopy.message(
                    for: error, fallback: approve ? "Couldn't approve the request" : "Couldn't decline the request"
                ))
            }
        }
    }

    /// Every request on the list, approved or declined; then the list is
    /// read again — whatever failed is still there.
    func answerAll(approve: Bool) {
        let pending = state.groups.flatMap(\.rows)
        guard !pending.isEmpty, !state.isWorking else { return }
        state.isWorking = true
        state.groups = []
        let requestService = service
        Task { [weak self] in
            var failed = 0
            for row in pending {
                do {
                    try await requestService.answerJoinRequest(from: row.id, to: row.channelID, approve: approve)
                } catch {
                    failed += 1
                }
            }
            guard let self else { return }
            self.state.isWorking = false
            if failed < pending.count { self.onChange?() }
            if failed > 0 {
                self.onFailure?(approve ? "Couldn't approve every request" : "Couldn't decline every request")
            }
            self.load()
        }
    }

    private func putBack(_ row: Row) {
        if let index = state.groups.firstIndex(where: { $0.channel.id == row.channelID }) {
            state.groups[index].rows.append(row)
            state.groups[index].rows.sort { $0.requestedAt > $1.requestedAt }
        } else if let channel = channels.first(where: { $0.id == row.channelID }) {
            let group = Group(channel: channel, rows: [row])
            let order = channels.map(\.id)
            state.groups.append(group)
            state.groups.sort { (order.firstIndex(of: $0.channel.id) ?? 0) < (order.firstIndex(of: $1.channel.id) ?? 0) }
        }
    }
}
