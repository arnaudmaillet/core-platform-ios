import PostGrid
import UIKit

/// Select Text on a card's caption (#1498 §4), for a page of list cards: one
/// card at most is selecting, and a tap anywhere else on the page, the start
/// of a drag or a new long press ends it — the comments' rule
/// (`ThreadRowContextMenu`).
///
/// ⚠️ AFTER THE MENU. The row's action runs while its menu is still leaving;
/// a selection begun then loses its callout to the dismissal. A long press's
/// menu is waited out (`menuWillDisplay` / `menuWillEnd`); a "..." menu has
/// no such callback, so its start waits one turn of the run loop.
@MainActor
final class CaptionSelectionSession: NSObject {
    private weak var selecting: PostGridListRowCell?
    private var isMenuUp = false
    private var pending: (() -> Void)?
    private lazy var dismissTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissTapped))
        // The tap that ends a selection does nothing else: it must not also
        // open the card under it.
        tap.cancelsTouchesInView = true
        tap.delegate = self
        tap.isEnabled = false
        return tap
    }()

    func install(on view: UIView) {
        view.addGestureRecognizer(dismissTap)
    }

    var isActive: Bool { selecting?.isSelectingCaption ?? false }

    /// Selects `cell`'s caption, ending any other selection.
    func begin(in cell: PostGridListRowCell) {
        let start = { [weak self, weak cell] in
            guard let self, let cell, cell.window != nil else { return }
            end()
            cell.beginCaptionSelection()
            guard cell.isSelectingCaption else { return }
            selecting = cell
            dismissTap.isEnabled = true
        }
        if isMenuUp { pending = start } else { DispatchQueue.main.async(execute: start) }
    }

    func end() {
        selecting?.endCaptionSelection()
        selecting = nil
        dismissTap.isEnabled = false
    }

    /// A long press's menu is showing: a selection in progress ends.
    func menuWillDisplay() {
        end()
        isMenuUp = true
    }

    /// The menu is leaving: a selection asked for from it begins once it has.
    func menuWillEnd(animator: (any UIContextMenuInteractionAnimating)?) {
        let finish = { [weak self] in
            guard let self else { return }
            isMenuUp = false
            let work = pending
            pending = nil
            work?()
        }
        guard let animator else { return finish() }
        animator.addCompletion(finish)
    }

    @objc private func dismissTapped() {
        end()
    }
}

extension CaptionSelectionSession: UIGestureRecognizerDelegate {
    /// Taps inside the selected text stay the text view's (handles, the
    /// callout); everything else ends the selection.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(selecting?.captionSelectionContains(touch.view) ?? false)
    }
}
