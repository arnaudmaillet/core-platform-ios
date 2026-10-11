import CoreModels
import MapsInterface

/// What the sub-filter row remembers for the session, and the pure rules that
/// read it: the people behind each primary, the viewer's own arrangement of
/// each row, and who they muted.
///
/// Kept apart from `MapsViewController`, which still owns the row on screen,
/// its fetches and its transitions. Everything here is a value and a rule —
/// session-scoped and in memory, never sent to the backend — so the rules
/// are pinned without a screen (`MapSubFilterRowMemoryTests`).
struct MapSubFilterRowMemory {
    /// Session cache of the people rows, prefetched at screen load so a
    /// primary tap renders its sub-filter row SYNCHRONOUSLY — the row must
    /// never wait on the social graph. Keyed by `.friends` / `.following`.
    var people: [MapFilter: [MapFavorite]] = [:]
    /// Everyone a primary COULD offer — the social graph behind it, ignoring
    /// curation. Kept apart from `people` since the rails became curated
    /// lists: the row is what the viewer kept, the catalogue is what the
    /// sheet offers them to add back, and an empty row must still be able to
    /// present a full sheet.
    var catalogue: [MapFilter: [MapFavorite]] = [:]
    /// The viewer's manual sub-filter order per primary, set by dragging rows
    /// in the full-list sheet. Session-scoped: it outlives primary switches
    /// and background refreshes, not the process.
    private(set) var order: [MapFilter: [MapSubFilter]] = [:]
    /// Refinements deleted in the sheet's edit mode, per primary — the social
    /// graph still returns them, so the row has to remember they're gone.
    private(set) var hidden: [MapFilter: Set<MapSubFilter>] = [:]
    /// Accounts muted from the sheet's swipe action. Session-local, like the
    /// conversation list's mute: `social_graph.v1` has no mute concept, and
    /// muting can't filter the map either until `RadarPin` carries an author
    /// id (the same Phase-2 gate as the filter header). Today it marks the
    /// row, and nothing more — a deliberately honest half of the feature.
    private(set) var muted: Set<ProfileID> = []

    // MARK: - Primaries

    /// The rail a people primary curates. Places have no rail — their
    /// refinements are a fixed client-side vocabulary, not a list of accounts.
    static func railCategory(for primary: MapFilter) -> MapFavoriteCategory? {
        switch primary {
        case .friends: .friends
        case .following: .following
        default: nil
        }
    }

    /// The primary's display name — the sheet's title, and the test for
    /// whether a primary has a refinement dimension at all (All and the
    /// favorite pills answer nil, and get no sheet).
    static func title(for filter: MapFilter?) -> String? {
        switch filter {
        case .friends: "Friends"
        case .following: "Following"
        case .pinned: "Places"
        default: nil
        }
    }

    /// Every refinement `filter` can offer, edits ignored — the catalogue the
    /// sheet splits into Active and Available.
    func catalogueOptions(for filter: MapFilter?) -> [MapSubFilterOption] {
        switch filter {
        case .friends, .following:
            guard let primary = filter else { return [] }
            return MapSubFilterOption.people(catalogue[primary] ?? [])
        case .pinned:
            return MapSubFilterOption.placeCategories
        default:
            return []
        }
    }

    /// The row's state as the refresh describes it — built in ONE place, so
    /// what an edit records and what a refresh compares against cannot drift
    /// into disagreeing.
    func rowState(primary: MapFilter, people: [MapFavorite]) -> MapSubFilterRowState {
        MapSubFilterRowState(
            primary: primary,
            people: people,
            hasCatalogue: MapSubFilterOption.rowSurvivesEmpty(
                catalogue: MapSubFilterOption.people(catalogue[primary] ?? [])
            )
        )
    }

    // MARK: - The viewer's arrangement

    /// Re-applies the viewer's edits to a freshly built option list: deleted
    /// rows stay gone, known items keep their dragged seats, anything the
    /// refresh added lands at the end (the sort is written as two passes
    /// because `sorted(by:)` is not stable — a rank-or-`Int.max` comparator
    /// would shuffle the newcomers).
    func ordered(_ options: [MapSubFilterOption], for primary: MapFilter?) -> [MapSubFilterOption] {
        guard let primary else { return options }
        let gone = hidden[primary] ?? []
        let kept = gone.isEmpty ? options : options.filter { !gone.contains($0.subFilter) }
        guard let dragged = order[primary], !dragged.isEmpty else { return kept }
        let rank = Dictionary(uniqueKeysWithValues: dragged.enumerated().map { ($1, $0) })
        let known = kept.filter { rank[$0.subFilter] != nil }
            .sorted { rank[$0.subFilter, default: 0] < rank[$1.subFilter, default: 0] }
        let newcomers = kept.filter { rank[$0.subFilter] == nil }
        return known + newcomers
    }

    /// Remembers the row the viewer committed for `primary`: its order, and —
    /// recomputed rather than accumulated, so a promotion out of the
    /// Available section un-hides in the same stroke a demotion hides — what
    /// is in the catalogue but not in the row. Without the hidden set the
    /// next background refresh would resurrect every removed row: they are
    /// still in the social graph.
    mutating func adopt(_ options: [MapSubFilterOption], for primary: MapFilter) {
        order[primary] = options.map(\.subFilter)
        hidden[primary] = Set(catalogueOptions(for: primary).map(\.subFilter))
            .subtracting(options.map(\.subFilter))
    }

    // MARK: - Mute

    func isMuted(_ profileID: ProfileID) -> Bool { muted.contains(profileID) }

    mutating func toggleMute(_ profileID: ProfileID) {
        muted.formSymmetricDifference([profileID])
    }

    // MARK: - Viewer change

    /// Signed in or out: the people rows were someone else's. The viewer's
    /// arrangement and mutes are left as they were.
    mutating func forgetPeople() {
        catalogue.removeAll()
        people.removeAll()
    }
}
