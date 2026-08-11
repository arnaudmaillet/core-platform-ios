import CoreModels
import CoreStorage
import Foundation

/// The inbox's global search: one query answered across every category at once,
/// plus the wider directory.
///
/// **Global, not per-tab.** The three inbox tabs are a *partition of one
/// dataset* — `InboxCatalog` loads once and `MessageRequestPolicy` splits it,
/// with the follow-graph lookup deliberately failing open. Scoping search to
/// whichever tab happened to be showing would make "can I find Sofía?" depend
/// on a client-side heuristic the viewer can't see, didn't choose, and which is
/// documented as approximate. Someone typing a name wants the thread, not a quiz
/// about its classification — so the query runs over everything and the answer
/// says which section it came from.
///
/// **Three sources, deliberately unequal in cost.** Messages and Requests are
/// already in memory, so they narrow on the keystroke itself — no debounce, no
/// round trip. Only the directory spends a request, and only per debounced
/// query, extending the list rather than replacing it. Typing therefore never
/// blanks the screen waiting on the network.
///
/// The conversation sections read the catalog's **projection**
/// (`snapshot.active` / `snapshot.requests`), not its raw load: a thread the
/// viewer deleted or a request they declined this session has left the inbox,
/// and search resurrecting it would undo a decision they just made. The People
/// section is the one place raw truth is consulted — via
/// `directConversationID(with:)`, so tapping someone whose thread is hidden
/// still opens that real thread instead of starting a blank draft.
@MainActor
final class InboxSearchViewModel {
    nonisolated enum SectionKind: Hashable, Sendable {
        case messages
        case requests
        case people
        /// The device-local search history — queries, not threads.
        case recents
    }

    /// A result row, as the diffable data source's identifier. The two cases
    /// carry different id types and can never collide, and the conversation
    /// partition is disjoint — so the same identifier cannot appear twice in one
    /// snapshot, which the data source would trap on.
    nonisolated enum Row: Hashable, Sendable {
        case conversation(ConversationID)
        case person(ProfileID)
        /// A query the viewer has run before, from the device-local history the
        /// global search screen writes to.
        case recentQuery(String)
    }

    nonisolated struct Section: Equatable, Sendable, Identifiable {
        let kind: SectionKind
        let title: String
        let rows: [Row]

        var id: SectionKind { kind }
    }

    nonisolated enum Phase: Equatable, Sendable {
        /// The field is open and empty. Mostly unseen — the system dims the
        /// inbox behind an empty query — but the state has to exist, because
        /// clearing a query lands here rather than in "no results".
        case prompt
        /// A query with nothing to show for it *yet*: no local match, and the
        /// directory still out. Distinct from `noResults`, which is a verdict.
        case loading
        case content([Section])
        /// A non-empty query that matched nothing, anywhere.
        case noResults(query: String)
        case failed(message: String)
    }

    var onPhaseChange: ((Phase) -> Void)?
    /// Where a tapped row leads. A *target*, resolved synchronously — the same
    /// seam the compose picker uses, so no result opens slower than another and
    /// this view model never navigates.
    var onOpenConversation: ((ConversationTarget) -> Void)?

    private enum SearchState: Equatable {
        case idle
        case loading(query: String)
        case results(query: String, [DirectoryPerson])
        case failed(message: String)
    }

    /// Display models for whatever the current phase contains, keyed by row.
    /// Held here rather than inlined into `Section` so the sections stay cheap
    /// to diff — they are identifiers only.
    private(set) var conversationModels: [ConversationID: ConversationDisplayModel] = [:]
    private(set) var peopleModels: [ProfileID: PersonDisplayModel] = [:]
    /// The DM peers already represented by a conversation row this projection,
    /// so the People section can exclude them without re-walking the snapshot.
    private var matchedPeerIDs: Set<ProfileID> = []

    private let catalog: InboxCatalog
    /// Shared with the global search screen — the same history, both directions.
    private let recents: RecentSearchStore?
    private let viewer: any ViewerIdentityProviding
    private let people: (any PeopleDirectoryProviding)?
    private let debounce: Duration
    private let pageSize: Int32
    private let now: @Sendable () -> Date

    private var phase: Phase = .prompt { didSet { onPhaseChange?(phase) } }
    private var observation: InboxCatalog.ObservationToken?

    private var snapshot = InboxCatalog.Snapshot()
    private var searchState: SearchState = .idle
    /// The last non-empty directory result set, held so a keystroke mid-query
    /// leaves rows on screen instead of blinking them out for a spinner and back.
    private var lastResults: [DirectoryPerson] = []
    /// Excluded everywhere: you cannot message yourself, and searching your own
    /// handle otherwise lists you.
    private var viewerID: ProfileID?

    private var query = ""
    private var searchTask: Task<Void, Never>?
    private var hasResolvedViewer = false

    init(
        catalog: InboxCatalog,
        viewer: any ViewerIdentityProviding,
        people: (any PeopleDirectoryProviding)? = nil,
        recents: RecentSearchStore? = nil,
        debounce: Duration = .milliseconds(300),
        pageSize: Int32 = 25,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.viewer = viewer
        self.people = people
        self.recents = recents
        self.debounce = debounce
        self.pageSize = pageSize
        self.now = now
        // Observed rather than snapshotted once: a reload landing while results
        // are on screen (the viewer read a thread, then searched) has to be
        // reflected, and re-projecting is free.
        observation = catalog.observe { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.emit()
        }
    }

    // MARK: - Query

    /// Called on every keystroke, plus the system's clear glyph and the cancel
    /// that collapses the field.
    ///
    /// Search deliberately does NOT reload the inbox. It is only reachable from
    /// a loaded one, and `InboxCatalog.reload` costs a `ListMembers` +
    /// `GetHistory` per conversation — an entire refetch to narrow a list the
    /// catalog is already holding.
    func queryChanged(_ text: String) {
        query = text
        searchTask?.cancel()
        // Deferred to the first keystroke rather than construction: the viewer's
        // id is only needed to exclude them from results, and most inbox
        // sessions never open search at all.
        resolveViewerIfNeeded()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchState = .idle
            lastResults = []
            emit()
            return
        }

        searchState = .loading(query: trimmed)
        emit()

        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.runSearch(trimmed)
        }
    }

    private func resolveViewerIfNeeded() {
        guard !hasResolvedViewer else { return }
        hasResolvedViewer = true
        Task { [weak self] in
            guard let self else { return }
            guard let id = try? await self.viewer.viewerProfileID() else { return }
            self.viewerID = id
            self.emit()
        }
    }

    private func runSearch(_ trimmed: String) async {
        guard let people else {
            // No directory in this composition: the local halves still answer,
            // and an empty People section simply never appears.
            searchState = .results(query: trimmed, [])
            emit()
            return
        }
        do {
            let found = try await people.searchPeople(matching: trimmed, limit: pageSize)
            // A late response for a superseded query must not overwrite newer
            // state — the same guard every other search surface carries.
            guard !Task.isCancelled, isCurrent(trimmed) else { return }
            searchState = .results(query: trimmed, found)
            emit()
        } catch {
            guard !Task.isCancelled, isCurrent(trimmed) else { return }
            // A directory failure is not a search failure: the local matches are
            // already on screen and are most of what the viewer came for. Only a
            // query with nothing local behind it surfaces the error.
            searchState = .failed(message: "Couldn't search for people. Please try again.")
            emit()
        }
    }

    private func isCurrent(_ trimmed: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
    }

    // MARK: - Selection

    /// Resolves where a row leads, synchronously in every section.
    ///
    /// A conversation row is already a destination. A person row is not: they
    /// may have a thread the inbox is hiding (declined, deleted) or none at all,
    /// so it resolves to a real id when one exists and a draft otherwise — the
    /// thread screen finds-or-creates underneath itself.
    func didSelect(_ row: Row) {
        switch row {
        case .conversation(let id):
            onOpenConversation?(.existing(id))
        case .person(let id):
            guard let person = peopleModels[id] else { return }
            if let existing = person.existingConversationID ?? catalog.directConversationID(with: id) {
                onOpenConversation?(.existing(existing))
            } else {
                onOpenConversation?(.draft(peer: id, displayName: person.displayName))
            }
        case .recentQuery(let text):
            // A history row is not a destination — it is the query again.
            replayRecentQuery(text)
        }
    }

    // MARK: - Projection

    private func emit() {
        switch searchState {
        case .idle:
            // ⚠️ NOT a placeholder. An open, empty field shows what a viewer is
            // most likely to be reaching for — recent threads, then the people
            // waiting in requests — which is what the global search does and what
            // "Search Messages / find a conversation…" was standing in for.
            let sections = idleSections()
            guard sections.isEmpty else {
                publish(sections)
                return
            }
            conversationModels = [:]
            peopleModels = [:]
            phase = .prompt
        case .loading(let query):
            // Hold the previous DIRECTORY rows steady through the debounce; the
            // local matches beside them are recomputed per keystroke and cost
            // nothing. Typing a fourth letter should refine a list, not strobe it.
            project(query: query, directory: lastResults, directoryDidAnswer: false)
        case .results(let query, let found):
            let visible = found.filter { $0.id != viewerID }
            lastResults = visible
            project(query: query, directory: visible, directoryDidAnswer: true)
        case .failed(let message):
            // Local matches outrank the error: they are complete, correct, and
            // the reason most searches happen.
            let local = conversationSections(matching: query.trimmingCharacters(in: .whitespacesAndNewlines))
            guard local.isEmpty else {
                publish(local)
                return
            }
            conversationModels = [:]
            peopleModels = [:]
            phase = .failed(message: message)
        }
    }

    private func project(query: String, directory: [DirectoryPerson], directoryDidAnswer: Bool) {
        var sections = conversationSections(matching: query)

        // Someone can be a correspondent AND a directory hit. The conversation
        // wins: that row opens a real thread instantly, where the directory copy
        // would re-resolve it. Deduping also keeps one person from appearing
        // twice on a screen whose whole job is to be scanned.
        let extra = directory.filter { $0.id != viewerID && !matchedPeerIDs.contains($0.id) }
        if !extra.isEmpty {
            let models = extra.map {
                PersonDisplayModel(
                    person: $0,
                    // Raw truth on purpose — see the type comment. A hidden
                    // thread is still the thread this row should open.
                    existingConversationID: catalog.directConversationID(with: $0.id)
                )
            }
            for model in models { peopleModels[model.id] = model }
            sections.append(Section(kind: .people, title: "People", rows: models.map { .person($0.id) }))
        }

        guard sections.isEmpty else {
            publish(sections)
            return
        }
        // Nothing local, nothing from the directory. Which empty state this is
        // depends on whether the directory has actually answered: calling it
        // "no results" mid-flight would flash a verdict the search hasn't reached.
        conversationModels = [:]
        peopleModels = [:]
        phase = directoryDidAnswer ? .noResults(query: query) : .loading
    }

    /// Messages and Requests, narrowed to `query`, with their display models
    /// stamped into `conversationModels` as a side effect.
    ///
    /// One builder for both sections so they cannot drift on matching rules,
    /// ordering, or unread/pin treatment — the partition is the only difference
    /// between them, and it belongs to the catalog rather than here.
    private func conversationSections(matching query: String) -> [Section] {
        conversationModels = [:]
        peopleModels = [:]
        matchedPeerIDs = []
        // One timestamp for the whole projection: two rows built a microsecond
        // apart must not be able to render "59m" and "1h" for the same minute.
        let stamp = now()
        let sources: [(SectionKind, String, [Conversation])] = [
            (.messages, "Messages", snapshot.active),
            (.requests, "Requests", snapshot.requests)
        ]
        return sources.compactMap { kind, title, conversations in
            let matched = conversations.filter { matches($0, query) }
            guard !matched.isEmpty else { return nil }
            for conversation in matched {
                conversationModels[conversation.id] = ConversationDisplayModel(
                    conversation: conversation,
                    now: stamp,
                    isPinned: snapshot.pinned.contains(conversation.id),
                    isMuted: snapshot.muted.contains(conversation.id),
                    isUnread: snapshot.unreadIDs.contains(conversation.id)
                )
                if let peer = conversation.directPeerID { matchedPeerIDs.insert(peer) }
            }
            return Section(kind: kind, title: title, rows: matched.map { .conversation($0.id) })
        }
    }

    /// Matched on the correspondent, not the transcript: only the *last* message
    /// of each thread is in memory, so matching previews would answer "search
    /// your messages" with whichever fragment happened to be cached — a search
    /// that finds a word in one thread and misses the same word in the next.
    /// Full-text history search is a `chat.v1` capability, not a client one.
    private func matches(_ conversation: Conversation, _ query: String) -> Bool {
        TextMatch.matchesAny(
            [conversation.title, conversation.directPeerHandle ?? ""],
            query: query
        )
    }

    /// What an empty field offers: recent threads, then requests as suggestions.
    ///
    /// Both come from the catalog already in memory, so the list is there the
    /// instant the field opens — no fetch, no spinner, nothing to wait for.
    /// Recent *queries* would be a different source: the device-local store the
    /// global search screen uses lives in `CoreStorage`, which this package does
    /// not depend on.
    private func idleSections() -> [Section] {
        conversationModels = [:]
        peopleModels = [:]
        matchedPeerIDs = []
        let stamp = now()
        var sections: [Section] = []
        // ⚠️ Recent QUERIES first, from the shared device-local store. These are
        // things the viewer typed, which is what "recent searches" means
        // everywhere else in the app; the threads below are a suggestion, not a
        // history, and conflating the two was the shortcut this replaces.
        let queries = (recents?.recents ?? [])
            .filter { $0.kind == .query }
            .prefix(Self.idleRowLimit)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-inbox-recents-trace") {
            print("[recents] store=\(recents == nil ? "nil" : "present") "
                + "total=\(recents?.recents.count ?? -1) queries=\(queries.count)")
        }
        #endif
        if !queries.isEmpty {
            sections.append(
                Section(kind: .recents, title: "Recent Searches",
                        rows: queries.map { .recentQuery($0.text) })
            )
        }
        let sources: [(SectionKind, String, [Conversation])] = [
            (.messages, "Recent", Array(snapshot.active.prefix(Self.idleRowLimit))),
            (.requests, "Suggestions", Array(snapshot.requests.prefix(Self.idleRowLimit)))
        ]
        sections.append(contentsOf: sources.compactMap { kind, title, conversations in
            guard !conversations.isEmpty else { return nil }
            for conversation in conversations {
                conversationModels[conversation.id] = ConversationDisplayModel(
                    conversation: conversation,
                    now: stamp,
                    isPinned: snapshot.pinned.contains(conversation.id),
                    isMuted: snapshot.muted.contains(conversation.id),
                    isUnread: snapshot.unreadIDs.contains(conversation.id)
                )
                if let peer = conversation.directPeerID { matchedPeerIDs.insert(peer) }
            }
            return Section(kind: kind, title: title, rows: conversations.map { .conversation($0.id) })
        })
        return sections
    }

    /// Records what the viewer actually searched for, so it is offered next time
    /// — here and on the global search screen, which reads the same store.
    func rememberQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let entry = recents?.recordQuery(trimmed)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-inbox-recents-trace") {
            print("[recents] recorded=\(entry?.text ?? "nil") "
                + "storeNow=\(recents?.recents.count ?? -1)")
        }
        #endif
    }

    /// Re-runs a row from the history.
    func replayRecentQuery(_ text: String) {
        onReplayQuery?(text)
        queryChanged(text)
    }

    /// Lets the screen put the text back in the field when a history row is tapped.
    var onReplayQuery: ((String) -> Void)?

    /// Enough to be useful, few enough that the field still reads as the subject.
    private static let idleRowLimit = 8

    private func publish(_ sections: [Section]) {
        phase = .content(sections)
    }
}
