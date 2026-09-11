import UIKit

/// The long press of a conversation and of a text post's resting comments: ONE
/// context-menu interaction on the stream, lifting whichever `ThreadRowCell` was
/// pressed.
///
/// On the stream rather than on each row for two reasons. The row is recycled,
/// and an interaction attached per dequeue is the kind of allocation the
/// comment cell was rebuilt to stop making. And the lift wants the row's PLATE
/// — a view the cell owns, with the platter's padding built in — which is
/// something only a host that can see the cell can hand over.
///
/// Installed only on streams whose rows are `ThreadRowCell`s. The other comment
/// surfaces — a media post's panel, the pushed comments screen — get nothing on
/// the stream, and their rows' own menus arbitrate exactly as before.
///
/// It also owns Select Text's session: one row at most is selecting, and a tap
/// anywhere else on the stream, a new long press, or the start of a drag ends
/// it.
@MainActor
final class ThreadRowContextMenu: NSObject {
    /// The menu for the row at an index path, or nil for rows that have none
    /// (a caption, a skeleton, a fold seam).
    var menuProvider: ((IndexPath) -> UIMenu?)?

    private weak var collectionView: UICollectionView?
    /// The row being lifted, for the two preview callbacks.
    private weak var liftedCell: ThreadRowCell?
    private weak var selectingCell: ThreadRowCell?
    private lazy var dismissSelectionTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissSelection))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tap.isEnabled = false
        return tap
    }()

    func install(on collectionView: UICollectionView) {
        self.collectionView = collectionView
        collectionView.addInteraction(UIContextMenuInteraction(delegate: self))
        collectionView.addGestureRecognizer(dismissSelectionTap)
    }

    /// Turns the row at `indexPath` into selectable text, ending any other.
    func beginTextSelection(at indexPath: IndexPath) {
        endTextSelection()
        guard let cell = collectionView?.cellForItem(at: indexPath) as? ThreadRowCell else { return }
        cell.beginTextSelection()
        selectingCell = cell
        dismissSelectionTap.isEnabled = true
    }

    func endTextSelection() {
        selectingCell?.endTextSelection()
        selectingCell = nil
        dismissSelectionTap.isEnabled = false
    }

    @objc private func dismissSelection() {
        endTextSelection()
    }
}

extension ThreadRowContextMenu: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        endTextSelection()
        guard let collectionView,
              let indexPath = collectionView.indexPathForItem(at: location),
              let cell = collectionView.cellForItem(at: indexPath) as? ThreadRowCell,
              cell.liftContains(collectionView.convert(location, to: cell)),
              let menu = menuProvider?(indexPath)
        else { return nil }
        liftedCell = cell
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        // Top-down in the order written, whichever side of the row the system
        // puts the menu on — the chat's rule.
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        liftedCell?.liftPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        // A row recycled while the menu was up has nowhere to land; the
        // system then fades the platter out in place.
        guard let cell = liftedCell, cell.window != nil else { return nil }
        return cell.liftPreview()
    }
}

extension ThreadRowContextMenu: UIGestureRecognizerDelegate {
    /// Taps inside the selected text stay the text view's — handles, the
    /// callout's anchor — and everything else on the stream ends the session.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(selectingCell?.selectionContains(touch.view) ?? false)
    }
}
