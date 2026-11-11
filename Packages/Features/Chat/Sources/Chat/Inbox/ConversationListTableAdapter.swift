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
/// ## One section, always
///
/// One list, no header (#2292, the owner 2026-11-11): the New / Recent split
/// went. The one section is there even when empty, which keeps section
/// insert/delete out of the update entirely, so every change is rows-only and
/// the batch arithmetic stays small enough to be obviously right.
///
/// ## What it deliberately does not do
///
/// No diffing of content. A row whose *content* changed without moving is
/// re-configured directly through `reconfigure(_:)`, because with a hand-driven
/// table that is just "call configure on the visible cell" — no snapshot, no
/// reload, and none of the reconfigure-versus-move conflict that made the
/// pinned row fade in the first place.
final class ConversationListTableAdapter: NSObject, UITableViewDataSource {
    private weak var tableView: UITableView?
    private let cellProvider: (UITableView, IndexPath, ConversationID) -> UITableViewCell
    /// The rows, in display order: the one section's.
    private var rows: [ConversationID] = []

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

    var isEmpty: Bool { rows.isEmpty }

    var allIdentifiers: [ConversationID] { rows }

    func itemIdentifier(for indexPath: IndexPath) -> ConversationID? {
        guard indexPath.section == 0, rows.indices.contains(indexPath.row) else { return nil }
        return rows[indexPath.row]
    }

    func indexPath(for id: ConversationID) -> IndexPath? {
        rows.firstIndex(of: id).map { IndexPath(row: $0, section: 0) }
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
    func apply(_ models: [ConversationDisplayModel], animated: Bool) {
        let new = models.map(\.id)
        guard let tableView, animated, !rows.isEmpty else {
            // The same rows in the same places: nothing to reload. The inbox
            // reloads its catalog on every appearance, and a full
            // `reloadData` of an unchanged list re-dequeued every visible row
            // in the turn after a tab switch or a pop — a ~70 ms hang right
            // as the screen arrived (#2116). Content changes reach the live
            // cells through the controller's `reconfigureVisible`.
            let unchanged = new == rows && !new.isEmpty
            rows = new
            if !unchanged { tableView?.reloadData() }
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

    private static func indexPaths(in rows: [ConversationID]) -> [ConversationID: IndexPath] {
        var paths: [ConversationID: IndexPath] = [:]
        for (row, id) in rows.enumerated() {
            paths[id] = IndexPath(row: row, section: 0)
        }
        return paths
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? rows.count : 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let id = itemIdentifier(for: indexPath) else { return UITableViewCell() }
        return cellProvider(tableView, indexPath, id)
    }
}
