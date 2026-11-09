import CoreModels
import DesignSystem
import Foundation

/// Picks the people of a group (#2214): to create one, or to add to one.
///
/// Who is offered: the viewer's recent correspondents — the people the
/// inbox search already offers on an empty field — and, once something is
/// typed, those of them who match plus the directory's hits. Who is picked
/// is kept in the order picked, as the chips at the top show them, whatever
/// the list below shows now: a chip stays while its person scrolls out of a
/// new query's results.
///
/// ⚠️ THE CAP IS THE BACKEND'S (chat.v1: 500 members, the creator
/// included). Creating, the viewer is a member already, so 499 may be
/// picked; adding, what the group has left. Reaching it is said
/// (`onCapReached`), never silently ignored.
@MainActor
final class GroupMemberPickerViewModel {
    nonisolated struct Section: Equatable, Sendable {
        let title: String
        let rows: [ProfileID]
    }

    nonisolated struct State: Equatable, Sendable {
        var sections: [Section] = []
        /// The people picked, in the order picked.
        var selected: [ProfileID] = []
        /// The directory is being asked about the current query.
        var isSearching = false
        /// Nothing matches the query, anywhere.
        var showsNoResults = false
        var canContinue = false
        var isAtCap = false
    }

    /// What the picker is for: a new group, or more people for one.
    nonisolated enum Purpose: Equatable, Sendable {
        case create
        /// `memberCount` counts everyone already in, the viewer included.
        case add(memberCount: Int)
    }

    var onStateChange: ((State) -> Void)?
    /// The cap was reached: the words to say.
    var onCapReached: ((String) -> Void)?

    private(set) var state = State() { didSet { if state != oldValue { onStateChange?(state) } } }
    /// Every person ever shown, so a chip outlives the row that put it there.
    private(set) var people: [ProfileID: PersonDisplayModel] = [:]

    let purpose: Purpose
    /// How many may be picked.
    let cap: Int
    /// How many must be picked to go on: two for a group (with the viewer,
    /// three people — two are a DM), one to add.
    let minimum: Int

    private let recents: [PersonDisplayModel]
    private let directory: (any PeopleDirectoryProviding)?
    /// Never offered: the viewer, and whoever is in the group already.
    private var excluded: Set<ProfileID>
    private let debounce: Duration
    private var query = ""
    private var found: [PersonDisplayModel] = []
    private var search: Task<Void, Never>?

    init(
        purpose: Purpose,
        recents: [PersonDisplayModel],
        directory: (any PeopleDirectoryProviding)?,
        excluded: Set<ProfileID> = [],
        debounce: Duration = .milliseconds(300)
    ) {
        self.purpose = purpose
        self.directory = directory
        self.excluded = excluded
        self.debounce = debounce
        switch purpose {
        case .create:
            cap = ConversationDraft.groupCap - 1
            minimum = 2
        case .add(let memberCount):
            cap = max(0, ConversationDraft.groupCap - memberCount)
            minimum = 1
        }
        var seen = Set<ProfileID>()
        self.recents = recents.filter { !excluded.contains($0.id) && seen.insert($0.id).inserted }
        for person in self.recents { people[person.id] = person }
        project()
    }

    /// What reaching the cap says (#2214).
    static func capMessage(cap: Int) -> String {
        "A group can have up to \(ConversationDraft.groupCap) people. You can add \(cap == 1 ? "1 more" : "\(cap) more") at most."
    }

    /// The viewer, once known: never offered.
    func exclude(_ ids: Set<ProfileID>) {
        excluded.formUnion(ids)
        state.selected.removeAll { ids.contains($0) }
        project()
    }

    // MARK: - Picking

    func isSelected(_ id: ProfileID) -> Bool { state.selected.contains(id) }

    /// Picks a person, or unpicks them. Past the cap, nothing is picked and
    /// the cap is said.
    func toggle(_ id: ProfileID) {
        if let index = state.selected.firstIndex(of: id) {
            state.selected.remove(at: index)
        } else {
            guard !excluded.contains(id), people[id] != nil else { return }
            guard state.selected.count < cap else {
                onCapReached?(Self.capMessage(cap: cap))
                return
            }
            state.selected.append(id)
        }
        project()
    }

    /// A chip's ✕.
    func remove(_ id: ProfileID) {
        guard state.selected.contains(id) else { return }
        toggle(id)
    }

    /// The picked people, in order — what "Next" carries.
    var selectedPeople: [PersonDisplayModel] { state.selected.compactMap { people[$0] } }

    // MARK: - Searching

    func queryChanged(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        search?.cancel()
        found = []
        guard !query.isEmpty, let directory else {
            state.isSearching = false
            project()
            return
        }
        state.isSearching = true
        project()
        let asked = query
        let pause = debounce
        search = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            let hits = (try? await directory.searchPeople(matching: asked, limit: 25)) ?? []
            guard !Task.isCancelled, let self, self.query == asked else { return }
            self.found = hits.map { PersonDisplayModel(person: $0) }
            for person in self.found where self.people[person.id] == nil { self.people[person.id] = person }
            self.state.isSearching = false
            self.project()
        }
    }

    // MARK: - Projection

    private func project() {
        var next = state
        var sections: [Section] = []
        let recentRows = recents
            .filter { query.isEmpty || TextMatch.matchesAny([$0.displayName, $0.handle], query: query) }
            .map(\.id)
        if !recentRows.isEmpty {
            sections.append(Section(title: query.isEmpty ? "Suggested" : "Recent", rows: recentRows))
        }
        let shown = Set(recentRows)
        let hitRows = found.map(\.id).filter { !excluded.contains($0) && !shown.contains($0) }
        if !hitRows.isEmpty { sections.append(Section(title: "People", rows: hitRows)) }
        next.sections = sections
        next.showsNoResults = !query.isEmpty && sections.isEmpty && !next.isSearching
        next.canContinue = next.selected.count >= minimum
        next.isAtCap = next.selected.count >= cap
        state = next
    }
}
