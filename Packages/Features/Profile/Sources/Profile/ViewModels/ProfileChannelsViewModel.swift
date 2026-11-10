import CoreModels
import Foundation
import PostGrid

/// A profile's Channels tab (#2232, behind `-channels`): the channels the
/// profile owns, and what a row's button does.
///
/// - **Read through Chat's seam** (`ProfileChannelsProviding`): Profile
///   can't depend on Chat, which owns the conversations. With no seam (the
///   flag off) there is no model, and no tab.
/// - **The tab shows only with a channel in it** (#742's rule for every
///   tab): `hasChannels`.
/// - **What is listed** is the server's answer (core-platform-backend#995):
///   the channels the profile OWNS — not the ones it admins — that the
///   viewer may see. The model holds the rule again (`visible`): someone
///   else's private channel never shows, whatever a read says, since a
///   private conversation can't be probed; the viewer's own carry a lock.
///   The order is the server's: the most subscribed first.
/// - **The viewer's own profile** leads with "Create a Channel" — only once
///   there is a channel: with none there is no tab, and creation stays in
///   the "+" menu and the inbox search (#2230).
/// - **A row's button is the showcase card's** (`ChannelEmbed.action`,
///   `ChannelEmbedActing`): Join, Request, Requested (a tap offers the
///   cancel), Open. The answer shows on the row at once and on every card
///   of that channel (`PostEmbedView.announceChannelStanding`); a card's own
///   tap reaches the row the same way.
@MainActor
final class ProfileChannelsViewModel: NSObject {
    /// One row of the tab.
    enum Row: Equatable {
        /// "Create a Channel", leading the viewer's own tab.
        case create
        case channel(ProfileChannel)

        /// What the list keys the row by.
        var id: RowID {
            switch self {
            case .create: .create
            case .channel(let channel): .channel(channel.id)
            }
        }
    }

    /// A row's identity: the same channel stays the same row through a
    /// change of standing, so its button morphs rather than reloads.
    enum RowID: Hashable, Sendable {
        case create
        case channel(ConversationID)
    }

    enum Phase: Equatable {
        /// Nothing asked yet: the profile isn't known.
        case idle
        case loading
        case loaded
        /// The read failed: no tab (nothing to show), and the next refresh
        /// asks again.
        case failed
    }

    let isOwnProfile: Bool
    /// "Create a Channel" leads the own tab only when something can create one.
    let offersCreation: Bool
    private(set) var owner: ProfileID?
    private(set) var phase: Phase = .idle
    /// The channels listed, in the server's order.
    private(set) var channels: [ProfileChannel] = []
    /// The channels whose write is in flight: their buttons load.
    private(set) var pending: Set<ConversationID> = []

    /// Anything the list draws changed.
    var onChange: (() -> Void)?
    /// A write was refused: that row's button says so (`AppButton.fail`).
    var onActionFailed: ((ConversationID) -> Void)?
    /// "Create a Channel" was tapped: the screen presents the new channel's
    /// sheet (Chat's, the "+" menu's).
    var onCreate: (() -> Void)?

    /// "Create a Channel", tapped — only where the row is offered.
    func requestCreation() {
        guard offersCreation else { return }
        onCreate?()
    }

    private let provider: any ProfileChannelsProviding
    /// The card's actions, asked when a button is tapped — the app's, made
    /// on the first tap like the card's (`PostEmbedView.resolvedChannelActions`).
    private let actions: @MainActor () -> (any ChannelEmbedActing)?
    /// Tells every card of a channel its new standing.
    private let announce: @MainActor (ConversationID, ChannelEmbed.ViewerState, ChannelEmbed.ViewerState) -> Void
    /// Which read is current: an answer for an earlier owner is dropped.
    private var generation = 0

    init(
        provider: any ProfileChannelsProviding,
        isOwnProfile: Bool,
        offersCreation: Bool,
        actions: @escaping @MainActor () -> (any ChannelEmbedActing)? = { PostEmbedView.resolvedChannelActions },
        announce: @escaping @MainActor (ConversationID, ChannelEmbed.ViewerState, ChannelEmbed.ViewerState) -> Void = {
            PostEmbedView.announceChannelStanding($0, from: $1, to: $2)
        }
    ) {
        self.provider = provider
        self.isOwnProfile = isOwnProfile
        self.offersCreation = offersCreation && isOwnProfile
        self.actions = actions
        self.announce = announce
        super.init()
        // A card's tap on one of these channels — a showcase on this very
        // profile's Posts — shows on its row too.
        NotificationCenter.default.addObserver(
            self, selector: #selector(standingDidChange(_:)), name: PostEmbedView.channelStateDidChange, object: nil
        )
    }

    // MARK: - What the tab shows

    /// Whether the profile shows the tab (#742): at least one channel the
    /// viewer may see.
    var hasChannels: Bool { !channels.isEmpty }

    /// The list, top to bottom: "Create a Channel" first on the viewer's
    /// own, then the channels. Empty with no channel — there is no tab.
    var rows: [Row] {
        guard hasChannels else { return [] }
        let channelRows = channels.map(Row.channel)
        return offersCreation ? [.create] + channelRows : channelRows
    }

    /// The channels a profile may list (#2232), in the order given: someone
    /// else's private ones never — a private conversation can't be probed —
    /// and none that can't be shown (deleted, blocked). The viewer's own keep
    /// their private ones, drawn with a lock. Pure, for tests.
    nonisolated static func visible(_ channels: [ProfileChannel], isOwnProfile: Bool) -> [ProfileChannel] {
        channels.filter { row in
            guard row.channel.availability == .available else { return false }
            return isOwnProfile || !row.isPrivate
        }
    }

    func channel(_ id: ConversationID) -> ProfileChannel? {
        channels.first { $0.id == id }
    }

    // MARK: - Reading

    /// Lists `owner`'s channels. Another owner than the last (an account
    /// switch on the own profile) forgets the last one's at once; the same
    /// one reads again (a pull to refresh, a return to the screen) and keeps
    /// its rows until the answer.
    func load(owner: ProfileID) {
        if self.owner != owner {
            self.owner = owner
            channels = []
            pending = []
            phase = .loading
            onChange?()
        } else if phase == .idle || phase == .failed {
            phase = .loading
        }
        generation += 1
        let asked = generation
        Task { [weak self, provider] in
            let result: Result<[ProfileChannel], any Error>
            do {
                result = .success(try await provider.channels(ownedBy: owner))
            } catch {
                result = .failure(error)
            }
            self?.land(result, generation: asked)
        }
    }

    /// Reads the same owner's channels again; nothing before one is known.
    func reload() {
        guard let owner else { return }
        load(owner: owner)
    }

    private func land(_ result: Result<[ProfileChannel], any Error>, generation asked: Int) {
        guard asked == generation else { return }
        switch result {
        case .success(let read):
            // A row whose write is in flight keeps what the tap last drew.
            let fresh = Self.visible(read, isOwnProfile: isOwnProfile).map { row in
                pending.contains(row.id) ? (channel(row.id) ?? row) : row
            }
            channels = fresh
            phase = .loaded
        case .failure:
            // A failed refresh keeps what was shown; a first read has nothing.
            phase = channels.isEmpty ? .failed : .loaded
        }
        onChange?()
    }

    // MARK: - A row's button

    /// What the button on `id`'s row offers, or nil for none (a banned
    /// viewer) — the card's table (`ChannelEmbed.action`).
    func action(for id: ConversationID) -> ChannelEmbed.Action? {
        channel(id)?.channel.action
    }

    /// A tap on the button: Join and Request write, Open opens; Requested's
    /// tap is its menu's (`cancelRequest`).
    func performAction(on id: ConversationID) {
        guard let action = action(for: id) else { return }
        switch action {
        case .open: open(id)
        case .join: write(id) { actions, id in try await actions.join(id) }
        case .requestToJoin: write(id) { actions, id in try await actions.requestToJoin(id) }
        case .requested: break
        }
    }

    /// The confirmed cancel of a waiting request.
    func cancelRequest(on id: ConversationID) {
        guard action(for: id) == .requested else { return }
        write(id) { actions, id in try await actions.cancelJoinRequest(id) }
    }

    /// A tap on the row: the channel's thread, which offers Join or Request
    /// to a non-member — what `core-platform.click/c/<id>` opens.
    func open(_ id: ConversationID) {
        actions()?.open(id)
    }

    private typealias Write = @MainActor (any ChannelEmbedActing, ConversationID) async throws -> ChannelEmbed.ViewerState

    private func write(_ id: ConversationID, _ write: @escaping Write) {
        guard let actions = actions(), !pending.contains(id), let before = channel(id)?.channel.viewerState else { return }
        pending.insert(id)
        onChange?()
        Task { [weak self] in
            do {
                let state = try await write(actions, id)
                self?.finish(id, from: before, to: state)
            } catch {
                self?.fail(id)
            }
        }
    }

    private func finish(_ id: ConversationID, from before: ChannelEmbed.ViewerState, to state: ChannelEmbed.ViewerState) {
        pending.remove(id)
        apply(state, to: id)
        // Every card of this channel follows (and remembers it for the
        // session) — which comes back here as a note, already applied.
        announce(id, before, state)
        onChange?()
    }

    private func fail(_ id: ConversationID) {
        pending.remove(id)
        onChange?()
        onActionFailed?(id)
    }

    /// `id`'s row with the viewer standing at `state`: the count follows a
    /// join or a leave (`ChannelEmbed.with(viewerState:)`).
    private func apply(_ state: ChannelEmbed.ViewerState, to id: ConversationID) {
        guard let index = channels.firstIndex(where: { $0.id == id }),
              channels[index].channel.viewerState != state else { return }
        channels[index].channel = channels[index].channel.with(viewerState: state)
    }

    /// A standing changed elsewhere — a card's tap.
    @objc private func standingDidChange(_ note: Notification) {
        guard let standing = PostEmbedView.channelStanding(in: note), !pending.contains(standing.id),
              let shown = channel(standing.id), shown.channel.viewerState != standing.state else { return }
        apply(standing.state, to: standing.id)
        onChange?()
    }
}
