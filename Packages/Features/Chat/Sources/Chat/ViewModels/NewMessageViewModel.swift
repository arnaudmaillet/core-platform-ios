import CoreModels
import Foundation

/// The compose picker's view model: who the viewer can write to, and what
/// happens when they pick someone.
///
/// Three sources, deliberately unequal in cost. **Recent** is free — the inbox
/// catalog has already loaded the viewer's conversations, so the picker opens
/// with content rather than a spinner. **Suggested** rides the same social-graph
/// fan-out the Suggestions tab pays for. Only **search** spends a request, and
/// only per debounced query.
///
/// A query narrows all three, but not on the same clock: the two in-memory
/// sources are filtered synchronously on the keystroke, and the directory
/// extends that list when it answers. Typing therefore never leaves the screen
/// blank waiting on the network.
///
/// Picking, by contrast, is uniformly free: it resolves a *destination*, never
/// a conversation. A known correspondent yields their id outright and anyone
/// else yields a draft the thread screen finds-or-creates once it is already
/// on screen — so no section taps slower than another.
@MainActor
public final class NewMessageViewModel {
    public nonisolated struct Section: Equatable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case recent
            case suggested
            case results
        }

        public let kind: Kind
        /// `nil` for search results: a header over the only thing on screen is
        /// noise, and the search field above it is already the label.
        public let title: String?
        public let people: [PersonDisplayModel]

        public init(kind: Kind, title: String?, people: [PersonDisplayModel]) {
            self.kind = kind
            self.title = title
            self.people = people
        }

        public var id: Kind { kind }
    }

    public nonisolated enum Phase: Equatable, Sendable {
        /// Nothing has arrived yet.
        case loading
        case content([Section], loading: Loading)
        /// A non-empty query that matched nobody.
        case noResults(query: String)
        /// Nothing to browse: no conversations, no suggestions.
        case empty
        case failed(message: String)
    }

    /// What, if anything, is still on its way — and therefore what the list
    /// shows for it. The two cases look nothing alike and must not be
    /// conflated: the first fan-out has no rows to sit under, so it shimmers
    /// the unfilled screen; a further page arrives beneath a full list, where
    /// anything more than a modest spinner would be noise.
    public nonisolated enum Loading: Equatable, Sendable {
        case none
        /// Recents/suggestions still arriving on first load.
        case fillingScreen
        /// Another page of suggestions is in flight.
        case appendingSuggestions
    }

    public var onPhaseChange: ((Phase) -> Void)?
    /// Where the pick leads, decided synchronously. The presenter owns the
    /// navigation, so this view model never navigates — and never waits: it
    /// hands over a *target*, not a conversation, precisely so that no network
    /// call sits between the finger going down and the screen appearing.
    public var onOpenConversation: ((ConversationTarget) -> Void)?

    private enum SearchState: Equatable {
        case idle
        case loading(query: String)
        case results(query: String, [DirectoryPerson])
        case failed(message: String)
    }

    private let catalog: InboxCatalog
    /// Narrowed to identity on purpose: the picker reads who the viewer is
    /// (to keep them out of their own lists) and writes nothing. Creating
    /// the conversation belongs to the thread that will show it.
    private let viewer: any ViewerIdentityProviding
    private let suggestionsRepository: (any SuggestionsProviding)?
    private let people: (any PeopleDirectoryProviding)?
    private let debounce: Duration
    /// A hard cap, not a page: recents come from a catalog that is already
    /// fully in memory, so there is nothing to fetch beyond it — past this many
    /// the list stops being a shortcut and search is the better tool.
    private let recentLimit: Int
    /// How many suggestions arrive per page, first and subsequent.
    private let suggestionPageSize: Int

    private let pageSize: Int32

    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var observation: InboxCatalog.ObservationToken?

    private var recents: [Conversation] = []
    private var suggestions: [SuggestedAccount] = []
    private var searchState: SearchState = .idle
    /// The last non-empty result set, held so a keystroke mid-query leaves the
    /// rows on screen instead of blinking them out for a spinner and back.
    private var lastResults: [DirectoryPerson] = []
    /// Excluded from every section: the viewer cannot message themselves, and
    /// searching your own handle otherwise lists you.
    private var viewerID: ProfileID?

    private var query = ""
    private var searchTask: Task<Void, Never>?
    private var hasLoaded = false
    /// Whether the one source that can arrive late has arrived. Without it an
    /// empty inbox shows "no one to message" for as long as the social-graph
    /// fan-out takes, then fills in — an empty state that turns out to be a lie.
    private var suggestionsDidSettle = false
    /// True while a further page of suggestions is in flight.
    private var isAppendingSuggestions = false
    /// Set once the graph stops producing new suggestions, so scrolling to the
    /// bottom of an exhausted list doesn't re-ask forever.
    private var suggestionsExhausted = false

    init(
        catalog: InboxCatalog,
        viewer: any ViewerIdentityProviding,
        suggestions suggestionsRepository: (any SuggestionsProviding)? = nil,
        people: (any PeopleDirectoryProviding)? = nil,
        debounce: Duration = .milliseconds(300),
        recentLimit: Int = 15,
        suggestionPageSize: Int = 20,
        pageSize: Int32 = 25
    ) {
        self.catalog = catalog
        self.viewer = viewer
        self.suggestionsRepository = suggestionsRepository
        self.people = people
        self.debounce = debounce
        self.recentLimit = recentLimit
        self.suggestionPageSize = suggestionPageSize
        self.pageSize = pageSize
        observation = catalog.observe { [weak self] _ in self?.projectRecents() }
    }

    // MARK: - Loading

    /// The picker deliberately does NOT reload the inbox. Compose is only
    /// reachable from a loaded inbox, and `InboxCatalog.reload` costs a
    /// `ListMembers` + `GetHistory` per conversation — an entire inbox refetch
    /// to redraw a list of names the catalog is already holding.
    public func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        projectRecents()
        resolveViewer()
        loadSuggestions()
    }

    private func resolveViewer() {
        Task { [weak self] in
            guard let self else { return }
            guard let id = try? await self.viewer.viewerProfileID() else { return }
            self.viewerID = id
            self.emit()
        }
    }

    private func loadSuggestions() {
        guard let suggestionsRepository else {
            suggestionsDidSettle = true
            emit()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // A suggestions failure is not a picker failure: search still
            // works, recents are already on screen, and the viewer came here
            // to write to someone specific anyway.
            let first = (try? await suggestionsRepository.suggestions(limit: self.suggestionPageSize)) ?? []
            self.suggestions = first
            self.suggestionsExhausted = first.count < self.suggestionPageSize
            self.suggestionsDidSettle = true
            self.emit()
        }
    }

    /// Asks for the next page of suggestions. Called as the list approaches its
    /// end; safe to call repeatedly, which it will be — `willDisplay` fires
    /// again on every bounce and every row that scrolls back into view.
    public func loadMoreSuggestionsIfNeeded() {
        guard suggestionsDidSettle,
              !isAppendingSuggestions,
              !suggestionsExhausted,
              let suggestionsRepository
        else { return }

        // The flag is set synchronously so the repeat calls are absorbed here,
        // but the PUBLISH is not: this is called from `willDisplay`, which the
        // collection view runs while it is applying a snapshot, and emitting
        // now would apply a second one underneath the first — which the
        // diffable data source treats as a deadlock and traps on. Hopping to a
        // task moves the spinner's apply to the next runloop turn, clear of the
        // layout pass that asked for it.
        isAppendingSuggestions = true
        Task { [weak self] in
            guard let self else { return }
            self.emit()
            let offset = self.suggestions.count
            let page = (try? await suggestionsRepository.suggestions(
                limit: self.suggestionPageSize, offset: offset
            )) ?? []

            // Deduplicated against what is already held, not just appended: the
            // ranking is stable but not guaranteed disjoint across pages, and a
            // repeat would put one profile id in the list twice — which the
            // diffable data source traps on.
            let known = Set(self.suggestions.map(\.id))
            let fresh = page.filter { !known.contains($0.id) }
            self.suggestions.append(contentsOf: fresh)
            // A short page, or one that added nothing new, means the graph has
            // no more to give. Both checks matter: a full page of duplicates
            // would otherwise loop forever.
            if page.count < self.suggestionPageSize || fresh.isEmpty {
                self.suggestionsExhausted = true
            }
            self.isAppendingSuggestions = false
            self.emit()
        }
    }

    private func projectRecents() {
        recents = catalog.directConversations()
        emit()
    }

    // MARK: - Search

    /// Called on every keystroke. Debounced, and cancels any in-flight search
    /// so the rows always reflect the latest query.
    public func queryChanged(_ text: String) {
        query = text
        searchTask?.cancel()

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

    private func runSearch(_ trimmed: String) async {
        guard let people else {
            searchState = .results(query: trimmed, [])
            emit()
            return
        }
        do {
            let found = try await people.searchPeople(matching: trimmed, limit: pageSize)
            // A late response for a superseded query must not overwrite newer
            // state — the same guard the people-search surface carries.
            guard !Task.isCancelled,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            searchState = .results(query: trimmed, found)
            emit()
        } catch {
            guard !Task.isCancelled,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            searchState = .failed(message: "Couldn't search. Please try again.")
            emit()
        }
    }

    // MARK: - Selection

    /// Decides where a picked row leads. Synchronous, in every section.
    ///
    /// The two cases differ only in what the destination has to do once it is
    /// on screen. A correspondent the inbox already knows hands over a real
    /// conversation id; anyone else hands over their identity, and the thread
    /// finds-or-creates underneath itself. Neither costs a round trip *here*,
    /// which is the whole point — the tap and the push are the same runloop
    /// turn, so the row can't feel laggy in one section and instant in another.
    public func didSelect(_ id: ProfileID) {
        guard let person = person(for: id) else { return }
        if let existing = person.existingConversationID ?? catalog.directConversationID(with: id) {
            onOpenConversation?(.existing(existing))
        } else {
            onOpenConversation?(.draft(peer: id, displayName: person.displayName))
        }
    }

    private func person(for id: ProfileID) -> PersonDisplayModel? {
        guard case .content(let sections, _) = phase else { return nil }
        return sections.lazy.flatMap(\.people).first { $0.id == id }
    }

    // MARK: - Projection

    private func emit() {
        switch searchState {
        case .idle:
            emitBrowsing()
        case .loading(let query):
            // Hold the previous DIRECTORY rows steady through the debounce; only
            // a search with nothing behind it shows a spinner. Typing a fourth
            // letter should refine a list, not strobe it. The local matches
            // beside them are recomputed per keystroke and cost nothing.
            emitSearching(query: query, directory: lastResults)
        case .results(let query, let found):
            let visible = found.filter { $0.id != viewerID }
            lastResults = visible
            emitSearching(query: query, directory: visible)
        case .failed(let message):
            phase = .failed(message: message)
        }
    }

    private func emitBrowsing() {
        let sections = browsingSections()

        // Either source still in flight on FIRST load leaves the rest of the
        // screen shimmering rather than blank — the catalog can be mid-load
        // too, on a cold start or a slow link. That state outranks paging:
        // there is no list yet to append to.
        let isFirstLoad = !suggestionsDidSettle || catalog.snapshot.phase == .loading
        guard !sections.isEmpty else {
            phase = isFirstLoad ? .loading : .empty
            return
        }
        let loading: Loading = if isFirstLoad {
            .fillingScreen
        } else if isAppendingSuggestions {
            .appendingSuggestions
        } else {
            .none
        }
        phase = .content(sections, loading: loading)
    }

    /// The query-active projection: what the app ALREADY holds, narrowed on the
    /// spot, plus whatever the directory has to add.
    ///
    /// The local pass is what makes typing feel immediate. Recents and
    /// suggestions are in memory, so they can be narrowed on the keystroke
    /// itself — no debounce, no round trip — while `search.v1` is still being
    /// asked about everyone else. The directory then *extends* that list rather
    /// than replacing it, so the rows that appeared instantly don't jump out
    /// from under the finger a third of a second later.
    private func emitSearching(query: String, directory: [DirectoryPerson]) {
        var sections = browsingSections(matching: query)
        // Someone can be a recent correspondent AND a directory hit. Local wins:
        // that copy carries a conversation id, so the row opens instantly — and
        // a duplicate identifier across sections would trap the diffable data
        // source besides.
        let alreadyShown = Set(sections.lazy.flatMap(\.people).map(\.id))
        let extra = directory.filter { $0.id != viewerID && !alreadyShown.contains($0.id) }
        if !extra.isEmpty {
            sections.append(resultsSection(extra, isAccompanied: !sections.isEmpty))
        }

        guard sections.isEmpty else {
            phase = .content(sections, loading: .none)
            return
        }
        // Nothing local, nothing from the directory. Which empty state this is
        // depends on whether the directory has actually answered yet: calling it
        // "no results" mid-flight would flash a verdict the search hasn't
        // reached.
        if case .loading = searchState {
            phase = .loading
        } else {
            phase = .noResults(query: query)
        }
    }

    /// Recent and Suggested, optionally narrowed to `query`.
    ///
    /// One builder for both the browsing list and the local half of search, so
    /// the two can't drift on capping, viewer exclusion, or cross-section
    /// dedupe — all three of which have already had a bug in them.
    private func browsingSections(matching query: String = "") -> [Section] {
        let recentPeople = recents
            .compactMap(PersonDisplayModel.init(recent:))
            .filter { $0.id != viewerID && matches($0, query) }
            .prefix(recentLimit)
        // Recent wins over Suggested for anyone in both: the row carries a
        // conversation id (so it opens instantly), and a duplicate identifier
        // across sections would trap the diffable data source besides. Matched
        // against the rows Recent actually SHOWS — someone past the cap is not
        // in the list, so suggesting them is not a duplicate.
        let recentIDs = Set(recentPeople.map(\.id))
        let suggestedPeople = suggestions
            .filter { $0.id != viewerID && !recentIDs.contains($0.id) }
            .map { PersonDisplayModel(account: $0, existingConversationID: nil) }
            .filter { matches($0, query) }

        var sections: [Section] = []
        if !recentPeople.isEmpty {
            sections.append(Section(kind: .recent, title: "Recent", people: Array(recentPeople)))
        }
        if !suggestedPeople.isEmpty {
            sections.append(Section(kind: .suggested, title: "Suggested", people: suggestedPeople))
        }
        return sections
    }

    /// Case- and diacritic-insensitive match on display name or handle — so
    /// "sofia" finds "Sofía Reyes" and "AVA" finds "Ava Moreau", neither of
    /// which an exact match would. Substring rather than prefix: the viewer
    /// types the part of the name they remember, which is often the surname.
    private func matches(_ person: PersonDisplayModel, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return person.displayName.range(of: query, options: options) != nil
            || person.handle.range(of: query, options: options) != nil
    }

    /// Search results are never capped: the viewer typed a query to narrow the
    /// field themselves, and trimming matches after they did that is answering
    /// a question they already answered.
    private func resultsSection(_ found: [DirectoryPerson], isAccompanied: Bool) -> Section {
        Section(
            kind: .results,
            // No header when this is the only thing on screen: the search field
            // above it is already the label. When locally-matched sections sit
            // above, the third one has to say what distinguishes it.
            title: isAccompanied ? "More People" : nil,
            people: found.map {
                PersonDisplayModel(
                    person: $0,
                    existingConversationID: catalog.directConversationID(with: $0.id)
                )
            }
        )
    }
}
