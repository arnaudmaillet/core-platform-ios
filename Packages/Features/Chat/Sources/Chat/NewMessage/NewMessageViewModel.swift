import CoreModels
import CoreNetworking
import Foundation

/// The "New message" sheet (#2411, the owner 2026-11-13): who to write to.
///
/// From the top: the actions — "New group" (#2214) and "New channel"
/// (#2230), each behind its flag, gone while there is a query — then three
/// sections of people:
/// 1. **Friends**, the people the viewer follows who follow back: a message
///    to anyone else lands in their Requests, so the people who will get it
///    for sure come first.
/// 2. **Recent**, the people the viewer last wrote to, most recent first, at
///    most `recentLimit` — the inbox's own rows, free.
/// 3. **Suggested**, the Suggestions tab's suggestions, paged as the list
///    scrolls.
///
/// **A person appears once**, in the first section that has them; **an
/// empty section is left out**; the sections arrive in order, the skeleton
/// where the loaded ones stop. With nothing at all to offer, the sheet says
/// "Search for someone" with the field focused (`Status.searchForSomeone`).
///
/// **A query narrows what is in memory on the keystroke** (case- and
/// diacritic-insensitive, name or handle: `TextMatch`, the inbox search's
/// rule), and the debounced directory search (`search.v1`) then EXTENDS the
/// list with "More people", deduped against what is shown — it never
/// replaces the rows already under the finger.
///
/// **A tap is a private message** — no multi-select; several people go
/// through "New group". It resolves synchronously, as the inbox search's
/// does (`PersonDisplayModel.conversationTarget(in:)`): the thread the inbox
/// knows, else a draft. This view model never navigates.
@MainActor
final class NewMessageViewModel {
    nonisolated enum SectionKind: Hashable, Sendable {
        case actions
        case friends
        case recent
        case suggested
        /// The directory's hits for a query, after the local matches.
        case morePeople
    }

    nonisolated enum Row: Hashable, Sendable {
        /// "New group" (#2214).
        case newGroup
        /// "New channel" (#2230).
        case newChannel
        case person(ProfileID)
    }

    nonisolated struct Section: Equatable, Sendable, Identifiable {
        let kind: SectionKind
        /// Empty for the actions: they wear no header.
        let title: String
        let rows: [Row]

        var id: SectionKind { kind }
    }

    nonisolated enum Status: Equatable, Sendable {
        case none
        /// Nothing at all to offer, and nothing on its way: the field is
        /// focused and the sheet says "Search for someone".
        case searchForSomeone
        /// A query the directory answered, with nobody anywhere.
        case noPeople
        /// A query with nobody local and a directory that failed (#794).
        case failed(message: String)
    }

    nonisolated struct State: Equatable, Sendable {
        var sections: [Section] = []
        /// A source the list waits on is out: skeleton rows close the list,
        /// where the loaded rows stop — never over them.
        var isLoading = false
        var status: Status = .none
    }

    var onStateChange: ((State) -> Void)?
    /// A person was picked: where the tap leads.
    var onPick: ((ConversationTarget) -> Void)?
    /// "New group" was picked (#2214): the member picker.
    var onNewGroup: (() -> Void)?
    /// "New channel" was picked (#2230): the channel's creation.
    var onNewChannel: (() -> Void)?

    private(set) var state = State() { didSet { if state != oldValue { onStateChange?(state) } } }
    /// Every person a row shows, by id, for the cells.
    private(set) var people: [ProfileID: PersonDisplayModel] = [:]
    /// The action rows the flags allow, in order.
    let actionRows: [Row]

    /// The most Recent shows.
    static let recentLimit = 15
    /// The most Friends shows: one read of the graph's Friends list.
    static let friendsLimit = 50
    /// A page of suggestions that adds nobody new leaves no new row to ask
    /// again, so the next one is asked at once — at most this many in a row.
    static let maxEmptyPagesInARow = 5

    private let catalog: InboxCatalog
    private let viewer: any ViewerIdentityProviding
    private let friendsSource: (any FriendsProviding)?
    private let suggestionsSource: any SuggestionsProviding
    private let directory: any PeopleDirectoryProviding
    private let debounce: Duration
    private let suggestionPageSize: Int
    private var observation: InboxCatalog.ObservationToken?

    /// Nil while the Friends list is on its way.
    private var friends: [PersonDisplayModel]?
    private var recents: [PersonDisplayModel] = []
    private var suggestions: [PersonDisplayModel] = []
    /// The first page of suggestions has answered (or failed).
    private var suggestionsAnswered = false
    /// Where the next page of suggestions starts; nil when none follows.
    private var suggestionsToken: String?
    private var suggestionPageLoad: Task<Void, Never>?
    /// Never offered: you cannot message yourself.
    private var viewerID: ProfileID?
    private var hasStarted = false

    private var query = ""
    private var search: Task<Void, Never>?
    private var directoryState: DirectoryState = .idle
    /// The directory's last answer, held through the next query's debounce
    /// so a keystroke refines the list instead of blinking it.
    private var heldDirectory: [PersonDisplayModel] = []

    private enum DirectoryState: Equatable {
        case idle
        case asking(String)
        case answered(String)
        case failed(String, message: String)
    }

    init(
        catalog: InboxCatalog,
        viewer: any ViewerIdentityProviding,
        friends: (any FriendsProviding)?,
        suggestions: any SuggestionsProviding,
        directory: any PeopleDirectoryProviding,
        showsNewGroup: Bool,
        showsNewChannel: Bool,
        debounce: Duration = .milliseconds(300),
        suggestionPageSize: Int = 20
    ) {
        self.catalog = catalog
        self.viewer = viewer
        friendsSource = friends
        suggestionsSource = suggestions
        self.directory = directory
        self.debounce = debounce
        self.suggestionPageSize = suggestionPageSize
        actionRows = Self.actionRows(showsNewGroup: showsNewGroup, showsNewChannel: showsNewChannel)
        if friends == nil { self.friends = [] }
        // Observed, not read once: the inbox loading under the sheet fills
        // Recent as it lands.
        observation = catalog.observe { [weak self] _ in
            guard let self else { return }
            self.readRecents()
            self.project()
        }
    }

    /// The action rows for a pair of flags (#2214, #2230): each behind its
    /// own, none with neither. Pure, for tests.
    nonisolated static func actionRows(showsNewGroup: Bool, showsNewChannel: Bool) -> [Row] {
        var rows: [Row] = []
        if showsNewGroup { rows.append(.newGroup) }
        if showsNewChannel { rows.append(.newChannel) }
        return rows
    }

    // MARK: - Loading

    /// Asks for the viewer, the friends and the first page of suggestions —
    /// once, as the sheet opens. Recent is the inbox's, already in memory.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { [weak self] in
            guard let self, let id = try? await self.viewer.viewerProfileID() else { return }
            self.viewerID = id
            self.project()
        }
        if let friendsSource {
            Task { [weak self] in
                let found = (try? await friendsSource.friends(limit: Self.friendsLimit)) ?? []
                guard let self else { return }
                self.friends = found.map { PersonDisplayModel(person: $0) }
                self.project()
            }
        }
        suggestionPageLoad = Task { [weak self] in
            guard let self else { return }
            let page = try? await self.suggestionsSource.suggestions(limit: self.suggestionPageSize, after: nil)
            self.suggestionPageLoad = nil
            self.suggestionsAnswered = true
            self.suggestionsToken = page?.nextPageToken
            self.appendSuggestions(page?.accounts ?? [])
            self.project()
        }
    }

    /// The viewer neared the end of Suggested: its next page, if it has one
    /// and none is on its way. Appended, never reordering what is shown; a
    /// failure is asked again on the next approach. Not while a query
    /// narrows the list.
    func loadMoreSuggestions() {
        guard suggestionPageLoad == nil, suggestionsAnswered, let token = suggestionsToken,
              TextMatch.normalize(query).isEmpty else { return }
        suggestionPageLoad = Task { [weak self] in
            guard let self else { return }
            var token = token
            for _ in 0..<Self.maxEmptyPagesInARow {
                guard let page = try? await self.suggestionsSource.suggestions(
                    limit: self.suggestionPageSize, after: token
                ) else { break }
                self.suggestionsToken = page.nextPageToken
                let added = self.appendSuggestions(page.accounts)
                guard !added, let next = page.nextPageToken else { break }
                token = next
            }
            self.suggestionPageLoad = nil
            self.project()
        }
    }

    /// Whether Suggested has another page.
    var hasMoreSuggestions: Bool { suggestionsToken != nil }

    /// Appends the suggestions not held yet; whether any of them will show
    /// (not the viewer, not someone an earlier section has).
    @discardableResult
    private func appendSuggestions(_ accounts: [SuggestedAccount]) -> Bool {
        var known = Set(suggestions.map(\.id))
        let shownElsewhere = Set((friends ?? []).map(\.id) + recents.map(\.id))
        var added = false
        for account in accounts where known.insert(account.id).inserted {
            suggestions.append(PersonDisplayModel(account: account))
            if account.id != viewerID && !shownElsewhere.contains(account.id) { added = true }
        }
        return added
    }

    private func readRecents() {
        recents = catalog.directConversations()
            .prefix(Self.recentLimit)
            .compactMap(PersonDisplayModel.init(recent:))
    }

    // MARK: - Query

    /// Every keystroke: the people in memory narrow at once; the directory
    /// is asked once the typing pauses.
    func queryChanged(_ text: String) {
        query = text
        search?.cancel()
        let needle = TextMatch.normalize(text)
        guard !needle.isEmpty else {
            directoryState = .idle
            heldDirectory = []
            project()
            return
        }
        directoryState = .asking(needle)
        project()
        let pause = debounce
        search = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self else { return }
            await self.askDirectory(needle)
        }
    }

    /// A failed directory search's way out (#1767).
    func retry() { queryChanged(query) }

    private func askDirectory(_ needle: String) async {
        do {
            let page = try await directory.searchPeoplePage(matching: needle, limit: 25, pageToken: nil)
            // A late answer for a superseded query must not overwrite newer state.
            guard !Task.isCancelled, isCurrent(needle) else { return }
            heldDirectory = page.people.map { PersonDisplayModel(person: $0) }
            directoryState = .answered(needle)
        } catch {
            guard !Task.isCancelled, isCurrent(needle) else { return }
            directoryState = .failed(needle, message: FailureCopy.message(
                for: error, fallback: "Couldn't search for people. Please try again."
            ))
        }
        project()
    }

    private func isCurrent(_ needle: String) -> Bool {
        TextMatch.normalize(query) == needle
    }

    // MARK: - Selection

    func didSelect(_ row: Row) {
        switch row {
        case .newGroup: onNewGroup?()
        case .newChannel: onNewChannel?()
        case .person(let id):
            guard let person = people[id] else { return }
            onPick?(person.conversationTarget(in: catalog))
        }
    }

    // MARK: - Projection

    private func project() {
        let needle = TextMatch.normalize(query)
        var seen: Set<ProfileID> = viewerID.map { [$0] } ?? []
        var sections: [Section] = []
        if needle.isEmpty, !actionRows.isEmpty {
            sections.append(Section(kind: .actions, title: "", rows: actionRows))
        }
        func add(_ kind: SectionKind, _ title: String, _ candidates: [PersonDisplayModel], narrows: Bool = true) {
            let shown = candidates.filter { person in
                (!narrows || TextMatch.matchesAny([person.displayName, person.handle], query: needle))
                    && seen.insert(person.id).inserted
            }
            guard !shown.isEmpty else { return }
            for person in shown { people[person.id] = person }
            sections.append(Section(kind: kind, title: title, rows: shown.map { .person($0.id) }))
        }
        add(.friends, "Friends", friends ?? [])
        // ⚠️ IN ORDER, NOTHING BELOW A SECTION STILL ON ITS WAY: Friends
        // landing above Recent would push the rows under the finger down.
        // So the empty field shows Recent once the friends have answered;
        // the skeleton stands where the loaded rows stop. A query narrows
        // whatever is in memory.
        if friends != nil || !needle.isEmpty {
            add(.recent, "Recent", recents)
            add(.suggested, "Suggested", suggestions)
        }
        if !needle.isEmpty {
            // Held through a new query's debounce, the last answer narrows
            // like the rest; an answer for this query is shown whole — the
            // directory matches more than a name or a handle.
            let answered = directoryState == .answered(needle)
            add(.morePeople, "More people", heldDirectory, narrows: !answered)
        }
        state = Self.state(sections: sections, needle: needle, waiting: waitingOnLists, directory: directoryState)
    }

    /// The first loads the empty field waits on.
    private var waitingOnLists: Bool { friends == nil || !suggestionsAnswered }

    /// What the sections amount to: the skeleton, and the status.
    private static func state(
        sections: [Section], needle: String, waiting: Bool, directory: DirectoryState
    ) -> State {
        var next = State(sections: sections)
        let hasPeople = sections.contains { $0.kind != .actions }
        guard !needle.isEmpty else {
            next.isLoading = waiting
            next.status = hasPeople || waiting ? .none : .searchForSomeone
            return next
        }
        switch directory {
        case .asking:
            // Bones only with nothing local to show: a match on the
            // keystroke is most of what the viewer came for.
            next.isLoading = !hasPeople
        case .answered:
            next.status = hasPeople ? .none : .noPeople
        case .failed(_, let message):
            next.status = hasPeople ? .none : .failed(message: message)
        case .idle:
            break
        }
        return next
    }
}
