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
            lastMessage: message.summary,
            lastActivityAt: message.createdAt,
            otherMemberIDs: otherMemberIDs,
            lastMessageIsMine: true,
            lastMessageID: message.id,
            isUnread: false
        )
    }
}

/// The inbox's shared source of truth: it loads the viewer's two inbox
/// folders — the conversations (All) and the message requests (Requests) —
/// and owns the session-local management state both surfaces mutate.
///
/// Why a shared object rather than a view model per tab doing its own fetch:
/// accepting a request moves it from one list to the other, and a
/// conversation the viewer answers leaves Requests — one owner for both
/// folders keeps those moves atomic. The catalog owns loading and truth; each
/// surface's view model still owns its own phases, ordering, and display
/// models — the tabs share data, not presentation.
///
/// ⚠️ REQUESTS ARE THE SERVER'S FOLDER (#593). They used to be a client-side
/// guess (an unfollowed peer the viewer hadn't answered), from the days
/// chat.v1 had no request plane. `ListInbox` sorts
/// them itself now, so a conversation the viewer started or answered is
/// never a request, whoever they follow.
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
        /// Which conversations the viewer hasn't read, across BOTH partitions.
        ///
        /// Requests are in here too. They were not, back when unread was only
        /// ever asked about the All list — but a request nobody has opened is
        /// unread by exactly the same test, and the Requests rows now wear the
        /// same bold preview and avatar count the All rows do. One definition,
        /// one read-ahead bridge, both lists.
        ///
        /// Ids rather than rows: the unread set marks conversations in place
        /// rather than forming a list of its own.
        var unreadIDs: Set<ConversationID> = []
        /// Pending requests, most recent first.
        var requests: [Conversation] = []
        /// Pending requests the viewer's hidden words or offensive filter
        /// caught (#552), most recent first. Never counted in a badge and
        /// never searched: the server sends no push for them either.
        var hiddenRequests: [Conversation] = []
        var pinned: Set<ConversationID> = []
        var muted: Set<ConversationID> = []
        /// The folders with another page to load (#593).
        var hasMore: Set<InboxFolder> = []
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
    private let directory: ConversationDirectory?

    /// The INBOX folder's rows, the REQUESTS folder's and the HIDDEN
    /// REQUESTS folder's, as loaded.
    private var conversations: [Conversation] = []
    private var requestRows: [Conversation] = []
    private var hiddenRequestRows: [Conversation] = []
    /// Every loaded row, whichever folder it sits in.
    private var allRows: [Conversation] { conversations + requestRows + hiddenRequestRows }
    private var observers: [UUID: (Snapshot) -> Void] = [:]
    private var load: Task<Void, Never>?
    private var loadGeneration = 0

    /// Where each folder's next page starts; absent when it has no more.
    private var nextTokens: [InboxFolder: String] = [:]
    /// The page each folder is fetching — one at a time per folder.
    private var pageLoads: [InboxFolder: Task<Void, Never>] = [:]
    /// Folders showing pages beyond the first: a reload merges its first
    /// page over them rather than cutting the list back to one page.
    private var hasLaterPages: Set<InboxFolder> = []
    /// A page filtered down to nothing still carries a token; this many in a
    /// row are walked through before waiting for the next approach.
    static let maxEmptyPagesInARow = 5

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

    init(repository: any ChatProviding, directory: ConversationDirectory? = nil) {
        self.repository = repository
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
            // The hidden requests alongside (#552), best-effort like Requests:
            // a failure keeps the ones already shown.
            async let hidden = try? self.repository.loadInbox(.hiddenRequests, after: nil)
            do {
                // Both folders at once. Requests are best-effort: a failure
                // there keeps the requests already shown rather than failing
                // the whole inbox over its smaller half.
                //
                // ⚠️ The inbox is asked from THIS task, not an `async let`: a
                // child task runs on the concurrent executor, so two reloads in
                // a row asked in either order — and the superseded one could
                // be served the newer state while the current one got the
                // older (the flaky `aSupersededLoadNeverPublishesItsTruncatedResult`).
                // From the main actor, reloads ask in the order they were made.
                async let requests = try? self.repository.loadInbox(.requests, after: nil)
                let inboxPage = try await self.repository.loadInbox(.inbox, after: nil)
                let requestPage = await requests
                // A superseded load must not touch state. Cancellation is
                // best-effort — the work may already have produced a partial
                // result — so being current is checked after EVERY await
                // rather than trusted to `CancellationError` alone. Publishing
                // here is what made returning from a thread flash a
                // near-empty inbox before the real load landed.
                guard self.loadGeneration == generation else { return }
                let hiddenPage = await hidden
                guard self.loadGeneration == generation else { return }

                // Both folders land TOGETHER: accepting moves a row from one
                // to the other, so one assigned before the other could show a
                // conversation in both lists, or in neither.
                self.adopt(firstPage: inboxPage, of: .inbox)
                if let requestPage { self.adopt(firstPage: requestPage, of: .requests) }
                if let hiddenPage { self.adopt(firstPage: hiddenPage, of: .hiddenRequests) }
                let loaded = self.allRows
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

    /// Forgets everything — rows, follow state and the in-session pin, mute,
    /// delete and request choices — and supersedes any load in flight, so a
    /// late answer for the previous viewer cannot land. Observers see the
    /// empty loading state at once.
    func reset() {
        load?.cancel()
        load = nil
        loadGeneration += 1
        for task in pageLoads.values { task.cancel() }
        pageLoads = [:]
        nextTokens = [:]
        hasLaterPages = []
        conversations = []
        requestRows = []
        hiddenRequestRows = []
        pinned = []
        muted = []
        readAheadOfServer = []
        deleted = []
        accepted = []
        declined = []
        snapshot = Snapshot()
        emit()
    }

    /// Reloads unless one is already in flight — the pull-to-refresh and
    /// became-active entry point.
    func refresh() {
        guard load == nil else { return }
        reload()
    }

    // MARK: - Paging

    /// A first page landing: the folder's rows, or — with later pages on
    /// screen — merged over them, the cursor past the last page kept.
    private func adopt(firstPage page: InboxPage, of folder: InboxFolder) {
        if hasLaterPages.contains(folder) {
            setRows(Self.merging(firstPage: page.conversations, over: rows(of: folder)), of: folder)
        } else {
            setRows(page.conversations, of: folder)
            nextTokens[folder] = page.nextPageToken
        }
    }

    /// The viewer neared the end of `folder`'s list: its next page, if it
    /// has one and none is already on the way. Appended, never reordering
    /// what is shown; a failure is retried on the next approach.
    func loadMore(_ folder: InboxFolder) {
        guard pageLoads[folder] == nil, let token = nextTokens[folder] else { return }
        let generation = loadGeneration
        pageLoads[folder] = Task { [weak self] in
            await self?.appendPages(of: folder, after: token, generation: generation)
        }
    }

    private func appendPages(of folder: InboxFolder, after token: String, generation: Int) async {
        var token = token
        var fresh: [Conversation] = []
        for _ in 0..<Self.maxEmptyPagesInARow {
            guard let page = try? await repository.loadInbox(folder, after: token),
                  // A reset forgot the list, or a reload replaced it.
                  loadGeneration == generation, nextTokens[folder] == token
            else {
                // A reset already emptied the slot, and may have refilled it.
                if loadGeneration == generation { pageLoads[folder] = nil }
                return
            }
            nextTokens[folder] = page.nextPageToken
            // A conversation can sit on both sides of a page boundary, or
            // have moved folders since the first page.
            let known = Set(allRows.map(\.id))
            fresh = page.conversations.filter { !known.contains($0.id) }
            // Filtered down to nothing: no new row reaches the end to ask
            // again, so the next page is asked now.
            guard fresh.isEmpty, let next = page.nextPageToken else { break }
            token = next
        }
        // ⚠️ THE SLOT FREES BEFORE THE ROWS RENDER. They render inside
        // `emit()`, and a page that lands wholly on screen asks for the next
        // one right there, from the rows' `willDisplay` — freed afterwards, that
        // ask found the slot taken and was dropped, and with every row already
        // displayed nothing ever asked again: the list stopped short under a
        // spinning footer.
        pageLoads[folder] = nil
        if !fresh.isEmpty {
            hasLaterPages.insert(folder)
            setRows(rows(of: folder) + fresh, of: folder)
            directory?.remember(fresh)
        }
        emit()
    }

    private func rows(of folder: InboxFolder) -> [Conversation] {
        switch folder {
        case .inbox: conversations
        case .requests: requestRows
        case .hiddenRequests: hiddenRequestRows
        }
    }

    private func setRows(_ rows: [Conversation], of folder: InboxFolder) {
        switch folder {
        case .inbox: conversations = rows
        case .requests: requestRows = rows
        case .hiddenRequests: hiddenRequestRows = rows
        }
    }

    /// A refreshed first page over a list that runs past it: the page
    /// replaces every row at least as recent as its oldest, and every older
    /// row stays where it is. The server lists newest activity first, so a
    /// row missing from the fresh page either slid down (older: kept) or went
    /// away (newer: dropped). Pure, for tests.
    static func merging(firstPage: [Conversation], over shown: [Conversation]) -> [Conversation] {
        let fresh = Set(firstPage.map(\.id))
        // No dated row on the fresh page says nothing about where it ends:
        // everything below stays.
        let oldest = firstPage.compactMap(\.lastActivityAt).min() ?? .distantFuture
        return firstPage + shown.filter { !fresh.contains($0.id) && ($0.lastActivityAt ?? .distantPast) < oldest }
    }

    // MARK: - Correspondents

    /// The viewer's one-to-one conversations, most recent first.
    ///
    /// Explicitly re-sorted rather than taken from `snapshot.active`, whose
    /// order is pin-hoisted: pinning is an inbox affordance, and a list titled
    /// "Recent" that opens with a months-old pinned thread is simply wrong.
    /// Group shapes are dropped — "the peer" is not a meaningful concept there.
    func directConversations() -> [Conversation] {
        snapshot.active
            .filter { $0.directPeerID != nil }
            .sorted(by: Conversation.isOrderedBefore)
    }

    /// The existing DM with `peer`, if the inbox has already loaded one.
    ///
    /// A hit here is what lets the compose picker open a known correspondent
    /// with no round trip at all — `directConversation(with:)` costs a
    /// `ListSubscriptions` plus a `ListMembers` per conversation to rediscover
    /// what this list already knows.
    ///
    /// Searched over every conversation the load returned, NOT `snapshot.active`.
    /// The projection is about what the inbox *displays*: a request sits in
    /// Requests, and a conversation deleted or declined this session is
    /// hidden entirely — but all of them still exist, still have history,
    /// and are exactly what find-or-create would hand back. Asking the
    /// projection instead was why picking someone with a real thread opened
    /// a blank draft and then made their history appear a moment later.
    func directConversationID(with peer: ProfileID) -> ConversationID? {
        allRows.first { $0.directPeerID == peer }?.id
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

    /// Lets a request through: it leaves Requests (or Hidden requests) and
    /// joins the active inbox, permanently for the session even though the
    /// peer stays unfollowed.
    func accept(_ id: ConversationID) {
        declined.remove(id)
        accepted.insert(id)
        emit()
    }

    /// Dismisses a request. It leaves the inbox entirely — the conversation
    /// still exists server-side (`RespondToMessageRequest` isn't wired yet),
    /// it simply stops being surfaced.
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
    ///
    /// A reply to a REQUEST answers it: the server moves it to the INBOX
    /// folder, and so does this, ahead of the next load saying so.
    func recordSentMessage(_ message: ChatMessage, in id: ConversationID) {
        if let index = requestRows.firstIndex(where: { $0.id == id }) {
            conversations.append(requestRows.remove(at: index))
        } else if let index = hiddenRequestRows.firstIndex(where: { $0.id == id }) {
            conversations.append(hiddenRequestRows.remove(at: index))
        }
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        // To the top, as the next load will list it — and ONLY it moves: the
        // rows keep the server's order, which a full re-sort would not (a
        // conversation with no message sorts last on the client).
        conversations.insert(conversations.remove(at: index).sending(message), at: 0)
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

    // MARK: - Projection

    /// One projection of the loaded folders through every piece of
    /// management state. Pinning reorders only the active list — a pinned
    /// request is not a concept.
    private func emit() {
        let hidden = deleted.union(declined)
        // A request accepted this session reads as a conversation until the
        // server has a word for it.
        let acceptedRequests = (requestRows + hiddenRequestRows).filter { accepted.contains($0.id) }
        var active = conversations.filter { !hidden.contains($0.id) }
        if !acceptedRequests.isEmpty {
            active = (active + acceptedRequests.filter { !hidden.contains($0.id) }).sorted(by: Conversation.isOrderedBefore)
        }
        snapshot.active = active.filter { pinned.contains($0.id) } + active.filter { !pinned.contains($0.id) }
        // Sorted here rather than inherited from whatever order the load
        // happened to produce: the Requests projection states its own key, so
        // its row order can't drift with an upstream change.
        snapshot.requests = requestRows
            .filter { !hidden.contains($0.id) && !accepted.contains($0.id) }
            .sorted(by: Conversation.isOrderedBefore)
        snapshot.hiddenRequests = hiddenRequestRows
            .filter { !hidden.contains($0.id) && !accepted.contains($0.id) }
            .sorted(by: Conversation.isOrderedBefore)
        let readAhead = readAheadOfServer
        // Hidden requests included: their rows wear the same unread treatment
        // when opened from Hidden requests. Nothing counts this set into a
        // badge, so they still announce nothing.
        snapshot.unreadIDs = Set(
            (snapshot.active + snapshot.requests + snapshot.hiddenRequests).lazy
                .filter { $0.isUnread && !readAhead.contains($0.id) }
                .map(\.id)
        )
        snapshot.pinned = pinned
        snapshot.muted = muted
        snapshot.hasMore = Set(nextTokens.keys)
        for observer in observers.values { observer(snapshot) }
    }
}
