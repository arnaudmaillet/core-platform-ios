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

    // MARK: - After the menu

    /// A menu is up, or on its way down.
    private var isMenuUp = false
    private var isMenuDismissing = false
    private var afterDismissal: [() -> Void] = []

    /// Runs `work` once no menu is on screen: at once when none is, else when
    /// the dismissal animation has finished.
    ///
    /// ⚠️ **FOR ANYTHING AN ACTION PRESENTS.** An action's handler runs while
    /// the menu is still leaving, and a sheet presented then races that
    /// dismissal; a "next run-loop turn" hop guessed at its length and, when
    /// the guess was short, the presentation was refused (or dropped by a
    /// `presentedViewController` guard) — the tap did nothing, silently.
    func afterMenuDismissal(_ work: @escaping () -> Void) {
        guard isMenuUp || isMenuDismissing else { return work() }
        afterDismissal.append(work)
    }

    private func menuDidFinishDismissing() {
        isMenuDismissing = false
        let pending = afterDismissal
        afterDismissal.removeAll()
        pending.forEach { $0() }
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

    /// Displayed, not merely configured: a press that lifts before the menu
    /// shows ends nothing, so a flag set at configuration could stay up for
    /// good and hold every later action back.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        isMenuUp = true
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        isMenuUp = false
        isMenuDismissing = true
        guard let animator else { return menuDidFinishDismissing() }
        animator.addCompletion { [weak self] in self?.menuDidFinishDismissing() }
    }
}

extension ThreadRowContextMenu: UIGestureRecognizerDelegate {
    /// Taps inside the selected text stay the text view's — handles, the
    /// callout's anchor — and everything else on the stream ends the session.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(selectingCell?.selectionContains(touch.view) ?? false)
    }
}
