import CoreModels
import Foundation

extension Conversation {
    /// This conversation as it reads once the viewer's own message lands: new
    /// preview, new activity time, and necessarily read (you cannot have
    /// unread mail from yourself).
    func sending(_ message: ChatMessage) -> Conversation {
        Conversation(
            id: id,
            title: title,
            lastMessage: message.body,
            lastActivityAt: message.createdAt,
            otherMemberIDs: otherMemberIDs,
            lastMessageIsMine: true,
            lastMessageID: message.id,
            isUnread: false
        )
    }
}

/// Whether the viewer follows given peers — the single social signal the
/// request partition needs. Separate from `ChatProviding` because it is
/// answered by `social_graph.v1`, and because a surface that can't reach it
/// must still work (see `InboxCatalog.load`).
public protocol PeerRelationProviding: Sendable {
    /// The subset of `peers` the viewer follows. Implementations should cache:
    /// this is called on every inbox reload.
    func followedPeers(among peers: [ProfileID]) async throws -> Set<ProfileID>
}

/// The inbox's shared source of truth: it loads the viewer's conversations
/// **once**, partitions them into active threads and pending requests, and
/// owns the session-local management state both surfaces mutate.
///
/// Why a shared object rather than a view model per tab doing its own fetch:
/// `loadConversations()` costs a `ListMembers` + `GetHistory` round trip *per
/// conversation* (`ChatRepository.hydrateConversation`), so two independent
/// loaders would double the inbox's entire network cost to render the same
/// rows twice. The catalog owns loading and truth; each surface's view model
/// still owns its own phases, ordering, and display models — the tabs share
/// data, not presentation.
///
/// Pin/mute/delete/accept/decline are IN-SESSION ONLY by design, the same
/// contract `ConversationListViewModel` shipped with: `chat.v1` has no plane
/// for any of them yet. When it grows one these become optimistic mirrors of
/// server calls and survive relaunch; the UI contract above them is final.
@MainActor
final class InboxCatalog {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(message: String)
    }

    struct Snapshot: Equatable {
        var phase: Phase = .loading
        /// Active conversations, most recent first, pinned hoisted to the top.
        var active: [Conversation] = []
        /// Which of `active` the viewer hasn't read. Ids rather than rows: the
        /// unread set marks conversations in place — a bold row, a dot, and a
        /// count on the All tab — rather than forming a list of its own.
        var unreadIDs: Set<ConversationID> = []
        /// Pending requests, most recent first.
        var requests: [Conversation] = []
        var pinned: Set<ConversationID> = []
        var muted: Set<ConversationID> = []
    }

    /// Cancels the registration when it is released — surfaces hold one for
    /// their lifetime, so observation ends with the view controller.
    final class ObservationToken: Sendable {
        private let remove: @Sendable () -> Void
        fileprivate init(remove: @escaping @Sendable () -> Void) { self.remove = remove }
        deinit { remove() }
    }

    private(set) var snapshot = Snapshot()

    private let repository: any ChatProviding
    private let relations: (any PeerRelationProviding)?
    private let directory: ConversationDirectory?

    private var conversations: [Conversation] = []
    private var followedPeers: Set<ProfileID> = []
    private var observers: [UUID: (Snapshot) -> Void] = [:]
    private var load: Task<Void, Never>?
    private var loadGeneration = 0

    private var pinned: Set<ConversationID> = []
    private var muted: Set<ConversationID> = []
    /// Conversations whose read cursor has moved but whose `last_read` the
    /// server hasn't reflected back yet.
    ///
    /// Entries are only ever added for writes that SUCCEEDED, and each is
    /// dropped the moment a load reports that conversation as read — so this
    /// is a lag bridge, never a substitute for truth. Clearing it wholesale on
    /// every load (the obvious implementation) resurrects the row the viewer
    /// just read whenever replication is slower than the reload, which is the
    /// original bug wearing a different hat.
    private var readAheadOfServer: Set<ConversationID> = []
    private var deleted: Set<ConversationID> = []
    private var accepted: Set<ConversationID> = []
    private var declined: Set<ConversationID> = []

    init(
        repository: any ChatProviding,
        relations: (any PeerRelationProviding)? = nil,
        directory: ConversationDirectory? = nil
    ) {
        self.repository = repository
        self.relations = relations
        self.directory = directory
    }

    // MARK: - Observation

    func observe(_ handler: @escaping (Snapshot) -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        handler(snapshot)
        // `deinit` carries no isolation guarantee, so the removal hops to the
        // main actor rather than touching the dictionary where it lands.
        return ObservationToken { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    // MARK: - Loading

    /// Reloads unconditionally, superseding any in-flight load.
    func reload() {
        load?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        load = Task { [weak self] in
            guard let self else { return }
            // Only the CURRENT load may clear the handle: a superseded task
            // finishing late would otherwise mark the fresh one as done and
            // let `refresh()` start a duplicate.
            defer { if self.loadGeneration == generation { self.load = nil } }
            do {
                let loaded = try await self.repository.loadConversations()
                // A superseded load must not touch state. Cancellation is
                // best-effort — the work may already have produced a partial
                // result — so being current is checked after EVERY await
                // rather than trusted to `CancellationError` alone. Publishing
                // here is what made returning from a thread flash a
                // near-empty inbox before the real load landed.
                guard self.loadGeneration == generation else { return }
                let peers = await self.resolveFollowedPeers(in: loaded)
                guard self.loadGeneration == generation else { return }

                // Rows and the peer set land TOGETHER: the request partition
                // reads both, so assigning one before awaiting the other opens
                // a window where any concurrent `emit()` classifies new rows
                // against stale follow state.
                self.conversations = loaded
                self.followedPeers = peers
                // Retire the bridge for every conversation the server now
                // agrees is read; keep it only where it is still catching up.
                self.readAheadOfServer.formIntersection(loaded.filter(\.isUnread).map(\.id))
                // Warm the thread screens' identity cache: a row tap must show
                // its header context at push-frame zero, synchronously.
                self.directory?.remember(loaded)
                self.snapshot.phase = .loaded
                self.emit()
            } catch is CancellationError {
                // Superseded.
            } catch {
                // Same rule for failures: a superseded load's error is not the
                // current load's problem, and must not put the inbox into a
                // failed state while a live fetch is still running.
                guard self.loadGeneration == generation, self.snapshot.phase != .loaded else { return }
                self.snapshot.phase = .failed(message: "Couldn't load your messages. Pull to retry.")
                self.emit()
            }
        }
    }

    /// Reloads unless one is already in flight — the pull-to-refresh and
    /// became-active entry point.
    func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// Follow edges for every DM peer in the inbox.
    ///
    /// A failure here (or no relation provider at all) resolves to "the viewer
    /// follows everyone", which collapses Requests to empty rather than
    /// quarantining real conversations behind a tab the user may never open.
    /// Failing open is the only safe direction for a heuristic partition.
    private func resolveFollowedPeers(in conversations: [Conversation]) async -> Set<ProfileID> {
        let peers = conversations.compactMap(\.directPeerID)
        guard let relations, !peers.isEmpty else { return Set(peers) }
        do {
            return try await relations.followedPeers(among: peers)
        } catch {
            return Set(peers)
        }
    }

    // MARK: - Management

    func isPinned(_ id: ConversationID) -> Bool { pinned.contains(id) }
    func isMuted(_ id: ConversationID) -> Bool { muted.contains(id) }

    func togglePin(_ id: ConversationID) {
        pinned.formSymmetricDifference([id])
        emit()
    }

    func toggleMute(_ id: ConversationID) {
        muted.formSymmetricDifference([id])
        emit()
    }

    /// Removes conversations from the inbox (context menu or batch edit). The
    /// filter is re-applied across reloads so deleted rows never resurface
    /// mid-session.
    func delete(_ ids: Set<ConversationID>) {
        deleted.formUnion(ids)
        emit()
    }

    /// Lets a request through: it leaves Requests and joins the active inbox,
    /// permanently for the session even though the peer stays unfollowed.
    func accept(_ id: ConversationID) {
        declined.remove(id)
        accepted.insert(id)
        emit()
    }

    /// Dismisses a request. It leaves the inbox entirely — the conversation
    /// still exists server-side (there is no decline RPC), it simply stops
    /// being surfaced.
    func decline(_ id: ConversationID) {
        accepted.remove(id)
        declined.insert(id)
        emit()
    }

    /// The viewer sent a message in a conversation, and it was accepted.
    ///
    /// Every other inbox action is local, so it lands the instant it is
    /// invoked. Sending was the exception: the row's preview, timestamp and
    /// position all change, but the catalog only learned of it by reloading —
    /// so the list underneath a thread stayed stale until a fetch completed,
    /// which on any real network is after the back swipe has finished. The
    /// row is re-sorted here exactly as `loadConversations` would order it, so
    /// the optimistic state matches what the next load will return.
    func recordSentMessage(_ message: ChatMessage, in id: ConversationID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index] = conversations[index].sending(message)
        conversations.sort(by: Conversation.isOrderedBefore)
        emit()
    }

    /// A single conversation has been read — the thread screen has already
    /// moved its cursor server-side and is reporting the fact.
    ///
    /// Applied immediately rather than waited for: the next load is what
    /// confirms it, and a viewer coming back from a thread should not watch
    /// the row they just read sit in Unread until a fetch completes.
    func markRead(_ id: ConversationID) {
        guard !readAheadOfServer.contains(id) else { return }
        readAheadOfServer.insert(id)
        emit()
        // Pick up whatever else changed while the viewer was in the thread.
        refresh()
    }

    /// That read didn't stick — the write failed. Put the row back rather than
    /// leave it hidden on a promise nobody kept.
    func markReadDidFail(_ id: ConversationID) {
        guard readAheadOfServer.contains(id) else { return }
        readAheadOfServer.remove(id)
        emit()
    }

    /// Declines everything currently pending, in one projection.
    func declineAll() {
        let pending = snapshot.requests.map(\.id)
        guard !pending.isEmpty else { return }
        accepted.subtract(pending)
        declined.formUnion(pending)
        emit()
    }

    // MARK: - Projection

    /// One projection of the loaded conversations through every piece of
    /// management state. Pinning reorders only the active list — a pinned
    /// request is not a concept.
    private func emit() {
        let partition = MessageRequestPolicy.partition(
            conversations,
            followedPeers: followedPeers,
            accepted: accepted,
            declined: declined,
            deleted: deleted
        )
        let active = partition.active
        snapshot.active = active.filter { pinned.contains($0.id) } + active.filter { !pinned.contains($0.id) }
        let readAhead = readAheadOfServer
        snapshot.unreadIDs = Set(
            snapshot.active.lazy
                .filter { $0.isUnread && !readAhead.contains($0.id) }
                .map(\.id)
        )
        // Sorted here rather than inherited from whatever order the load
        // happened to produce: the Requests projection states its own key, so
        // its row order can't drift with an upstream change.
        snapshot.requests = partition.requests.sorted(by: Conversation.isOrderedBefore)
        snapshot.pinned = pinned
        snapshot.muted = muted
        for observer in observers.values { observer(snapshot) }
    }
}
