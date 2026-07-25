import UIKit

/// A diffable table data source whose rows are all editable.
///
/// Diffable data sources report every row as NON-editable by default, which
/// silently disables editing-mode selection — the circled checkmarks never
/// appear and `indexPathsForSelectedRows` stays empty. Every inbox surface
/// offers multi-selection, so all three opt in through this one subclass
/// rather than each shipping its own two-line override.
final class EditableDiffableDataSource<
    Section: Hashable & Sendable,
    Item: Hashable & Sendable
>: UITableViewDiffableDataSource<Section, Item> {
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }
}
