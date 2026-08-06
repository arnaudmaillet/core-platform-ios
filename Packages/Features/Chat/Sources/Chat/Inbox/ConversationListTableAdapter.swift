import CoreModels
import UIKit

/// The All list's table contents, driven by hand so a reordered row MOVES.
///
/// ## Why this replaced a diffable data source
///
/// `UITableViewDiffableDataSource` resolves a reorder as a delete/insert pair,
/// which renders as a fade: the row vanishes where it was and reappears at the
/// top. Measured on a pin, with the apply reduced to a clean same-section
/// reorder — same sections, same counts, nothing reconfigured — and it faded
/// anyway. The snapshot API offers no way to ask for a move, so pinning could
/// never look like the row travelling to the top.
///
/// This computes the update itself and issues `moveRow(at:to:)` inside
/// `performBatchUpdates`, which is UIKit's real move animation: the row slides,
/// and the rows it passes shift to make room.
///
/// ## Two sections, always
///
/// The sections are fixed at `[.new, .earlier]` and an empty one simply holds
/// no rows. That is not cosmetic — it removes section insert/delete from the
/// update entirely, so every change is rows-only and the batch arithmetic stays
/// small enough to be obviously right. `headedSection(at:)` still returns nil
/// unless BOTH sections have rows, so a single-block list renders unlabelled
/// exactly as it did before.
///
/// ## What it deliberately does not do
///
/// No diffing of content. A row whose *content* changed without moving is
/// re-configured directly through `reconfigure(_:)`, because with a hand-driven
/// table that is just "call configure on the visible cell" — no snapshot, no
/// reload, and none of the reconfigure-versus-move conflict that made the
/// pinned row fade in the first place.
final class ConversationListTableAdapter: NSObject, UITableViewDataSource {
    /// Section order, fixed. Index 0 is New, index 1 is Recent.
    static let sectionOrder: [InboxListSection] = [.new, .earlier]

    private weak var tableView: UITableView?
    private let cellProvider: (UITableView, IndexPath, ConversationID) -> UITableViewCell
    private var rows: [[ConversationID]] = [[], []]

    init(
        tableView: UITableView,
        cellProvider: @escaping (UITableView, IndexPath, ConversationID) -> UITableViewCell
    ) {
        self.tableView = tableView
        self.cellProvider = cellProvider
        super.init()
        tableView.dataSource = self
    }

    // MARK: - Contents

    var isEmpty: Bool { rows.allSatisfy(\.isEmpty) }

    var allIdentifiers: [ConversationID] { rows.flatMap(\.self) }

    func itemIdentifier(for indexPath: IndexPath) -> ConversationID? {
        guard rows.indices.contains(indexPath.section),
              rows[indexPath.section].indices.contains(indexPath.row)
        else { return nil }
        return rows[indexPath.section][indexPath.row]
    }

    func indexPath(for id: ConversationID) -> IndexPath? {
        for (section, ids) in rows.enumerated() {
            if let row = ids.firstIndex(of: id) { return IndexPath(row: row, section: section) }
        }
        return nil
    }

    /// The section at an index, or nil when the list is one unlabelled block —
    /// titling the whole list says nothing, so it goes unheaded.
    func headedSection(at index: Int) -> InboxListSection? {
        guard rows.allSatisfy({ !$0.isEmpty }), Self.sectionOrder.indices.contains(index) else {
            return nil
        }
        return Self.sectionOrder[index]
    }

    func index(of section: InboxListSection) -> Int? {
        Self.sectionOrder.firstIndex(of: section)
    }

    // MARK: - Updates

    /// Applies a new arrangement, moving the rows that moved.
    ///
    /// Deletes are expressed in the OLD coordinate space and inserts in the
    /// new, which is what `performBatchUpdates` expects; a row present in both
    /// arrangements at a different index path is a MOVE, never a delete plus an
    /// insert — that distinction is the entire point of this type.
    ///
    /// The backing store is updated before the batch so the table can query it
    /// during the animation.
    func apply(_ sections: InboxListSections, animated: Bool) {
        let new = [sections.new.map(\.id), sections.earlier.map(\.id)]
        guard let tableView, animated, !(rows.allSatisfy(\.isEmpty)) else {
            rows = new
            tableView?.reloadData()
            return
        }

        let oldPaths = Self.indexPaths(in: rows)
        let newPaths = Self.indexPaths(in: new)
        guard oldPaths != newPaths else {
            rows = new
            return
        }

        let deletes = oldPaths.filter { newPaths[$0.key] == nil }.map(\.value)
        let inserts = newPaths.filter { oldPaths[$0.key] == nil }.map(\.value)
        let moves = newPaths.compactMap { id, to -> (from: IndexPath, to: IndexPath)? in
            guard let from = oldPaths[id], from != to else { return nil }
            return (from, to)
        }

        rows = new
        tableView.performBatchUpdates {
            if !deletes.isEmpty { tableView.deleteRows(at: deletes, with: .fade) }
            if !inserts.isEmpty { tableView.insertRows(at: inserts, with: .fade) }
            for move in moves { tableView.moveRow(at: move.from, to: move.to) }
        }
    }

    /// Puts a section's first row directly under the header, which is what
    /// tapping that header's pill means: "show me this part".
    ///
    /// A no-op for an empty section, and for a list too short to scroll —
    /// `scrollToRow` cannot invent content.
    func scroll(_ tableView: UITableView, toSectionAt index: Int) {
        guard rows.indices.contains(index), !rows[index].isEmpty else { return }
        tableView.scrollToRow(at: IndexPath(row: 0, section: index), at: .top, animated: true)
    }

    private static func indexPaths(in rows: [[ConversationID]]) -> [ConversationID: IndexPath] {
        var paths: [ConversationID: IndexPath] = [:]
        for (section, ids) in rows.enumerated() {
            for (row, id) in ids.enumerated() {
                paths[id] = IndexPath(row: row, section: section)
            }
        }
        return paths
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { rows.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows[section].count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let id = itemIdentifier(for: indexPath) else { return UITableViewCell() }
        return cellProvider(tableView, indexPath, id)
    }
}
