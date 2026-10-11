import Foundation

/// The sub-filter row's contents split in two, which is what the full-list
/// sheet renders and what the horizontal bar mirrors:
///
/// - **active** — the refinements the bar currently shows, in the viewer's
///   own order, capped at `maxActive` (a row you have to scroll for a minute
///   to reach the end of is not a filter bar). The cap governs GROWING the
///   row from the sheet; it is never a reason to refuse what the row already
///   carries — see `maxActive`.
/// - **available** — everything else this primary could offer: what was
///   removed, unfollowed, or simply never promoted.
///
/// Pure value logic on purpose: capacity, membership and ordering are the
/// only rules in this feature that are worth getting exactly right, and they
/// are far cheaper to test here than through two collection views.
struct MapSubFilterSections: Equatable {
    /// How many refinements the horizontal row will carry at once.
    static let defaultMaxActive = 6

    private(set) var active: [MapSubFilterOption]
    private(set) var available: [MapSubFilterOption]
    /// The effective cap for this editing session: the requested one, or the
    /// size of the row the sheet was GIVEN when that is larger.
    ///
    /// People rows are not capped at `defaultMaxActive` upstream — the
    /// favorites repository serves rails of up to 12, and a curated row is as
    /// long as the viewer made it. Clamping to 6 here turned such a row into
    /// "12 of 6", refused every drag (any reorder leaves 12 in Active) and
    /// would have forced the viewer to delete people just to rearrange them
    /// (#867). Silently trimming the row on open would be worse: Done would
    /// publish a shorter row than the viewer asked for. So the sheet takes the
    /// row as it found it — "12 of 12", reorderable — and only refuses to grow
    /// it further. A row at or under the default keeps the default.
    let maxActive: Int

    var isFull: Bool { active.count >= maxActive }

    /// - Parameters:
    ///   - all: every refinement this primary can offer, in repository order.
    ///   - activeSubFilters: which of them the bar shows, in bar order.
    ///     Unknown ids are ignored; anything not listed lands in `available`.
    init(
        all: [MapSubFilterOption],
        activeSubFilters: [MapSubFilter],
        maxActive: Int = MapSubFilterSections.defaultMaxActive
    ) {
        let byID = Dictionary(all.map { ($0.subFilter, $0) }, uniquingKeysWith: { first, _ in first })
        let active = activeSubFilters.compactMap { byID[$0] }
        let activeIDs = Set(active.map(\.subFilter))
        self.active = active
        self.available = all.filter { !activeIDs.contains($0.subFilter) }
        self.maxActive = Swift.max(maxActive, active.count)
    }

    /// The Active header's counter, `3 of 6`. Never reads more active than
    /// allowed, because `maxActive` is never below what the sheet was given.
    var capacityLabel: String { "\(active.count) of \(maxActive)" }

    /// Promotes an available refinement to the end of the active list — the
    /// end, never the front: the order above it is the viewer's arrangement,
    /// and a newcomer has not earned a seat in it.
    ///
    /// - Returns: false when the active list is already full (the caller says
    ///   so out loud rather than silently dropping the gesture).
    @discardableResult
    mutating func activate(_ subFilter: MapSubFilter) -> Bool {
        guard !isFull else { return false }
        guard let index = available.firstIndex(where: { $0.subFilter == subFilter }) else {
            return false
        }
        active.append(available.remove(at: index))
        return true
    }

    /// Demotes an active refinement back to the available list, restoring the
    /// natural order there rather than appending — the available section is
    /// a catalogue, not a history.
    mutating func deactivate(_ subFilter: MapSubFilter, naturalOrder: [MapSubFilter]) {
        guard let index = active.firstIndex(where: { $0.subFilter == subFilter }) else { return }
        let option = active.remove(at: index)
        let rank = Dictionary(uniqueKeysWithValues: naturalOrder.enumerated().map { ($1, $0) })
        let position = rank[option.subFilter] ?? Int.max
        let insertion = available.firstIndex { (rank[$0.subFilter] ?? Int.max) > position }
        available.insert(option, at: insertion ?? available.count)
    }

    /// Adopts an arrangement the collection view produced (a drag that
    /// reordered the active section, or dropped an item across the divide).
    ///
    /// - Returns: false when the proposal exceeds capacity, in which case
    ///   nothing changes and the caller re-applies its snapshot.
    @discardableResult
    mutating func adopt(active proposedActive: [MapSubFilterOption],
                        available proposedAvailable: [MapSubFilterOption]) -> Bool {
        guard proposedActive.count <= maxActive else { return false }
        active = proposedActive
        available = proposedAvailable
        return true
    }
}
