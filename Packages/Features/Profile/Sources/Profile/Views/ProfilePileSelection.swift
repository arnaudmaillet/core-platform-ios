import CoreModels
import DesignSystem
import PostGrid
import UIKit

/// What the piles' select mode asks of its screen (#2522): whose profile it
/// is and the tab on screen, the threshold, the pager, the piles and the bar
/// it recomposes.
@MainActor
protocol ProfilePileSelectionHost: UIViewController {
    var isAccountRoot: Bool { get }
    var viewModel: ProfileViewModel { get }
    var shownTab: ProfileTab? { get }
    var isPastThreshold: Bool { get }
    var galleryPager: ProfileGalleryPagerView { get }
    func applyNavigationState(animated: Bool)
}

/// The viewer's piles' select mode — History's (the owner, 2026-11-08) and
/// Saved's (the owner, 2026-11-28: "the History tab's mechanics, made
/// generic"): the rows' selection, Select and Done at the bar's corner, and
/// "Remove from History (n)" / "Remove from Saved (n)" in the selector's
/// place in the bar (#2475).
///
/// One mode for both: the same words, the same items, the same steps; only
/// what a pile holds and how a post leaves it differ (`Pile`).
///
/// ⚠️ SELECT AND DONE ARE KEPT INSTANCES (R3): the bar morphs one into the
/// other by reference, and Select's enabling changes in place.
@MainActor
final class ProfilePileSelection {
    private unowned let host: any ProfilePileSelectionHost

    init(host: any ProfilePileSelectionHost) {
        self.host = host
    }

    /// A pile the viewer can select in: its tab, its name in the words,
    /// whether it holds anything, and how posts leave it.
    struct Pile {
        let tab: ProfileTab
        let name: String
    }

    /// The selectable piles, by tab: History and Saved.
    static func pile(for tab: ProfileTab?) -> Pile? {
        switch tab {
        case .history: Pile(tab: .history, name: "History")
        case .saved: Pile(tab: .saved, name: "Saved")
        default: nil
        }
    }

    /// The pile whose rows wear their selection circles now; nil when no
    /// select mode runs. The bar says Done, and "Remove from … (n)" stands in
    /// the selector's place.
    private(set) var selecting: Pile?
    var isSelecting: Bool { selecting != nil }
    private var selection: [PostID] = []

    private func holdsAnything(_ pile: Pile) -> Bool {
        switch pile.tab {
        case .saved: host.viewModel.hasSaved
        default: host.viewModel.hasHistory
        }
    }

    /// The own profile, on History or Saved (#2307, #2475 §4, the owner
    /// 2026-11-28):
    ///
    /// | the pile's page               | the corner          |
    /// |-------------------------------|---------------------|
    /// | at rest                       | ✎ (nil here)        |
    /// | past the threshold            | Select (disabled with nothing in the pile) |
    /// | selecting, wherever scrolled  | Done                |
    ///
    /// No Select at rest: it comes in past the threshold, as the selector
    /// does. Done holds while selecting, even back at the top — without it
    /// there would be no way out; after it, the scroll's rule again. The
    /// word: iOS's word for the mode (Photos, Files, Mail).
    var selectBarItem: UIBarButtonItem? {
        guard host.isAccountRoot, !host.viewModel.namesNoOne, let pile = Self.pile(for: host.shownTab) else {
            return nil
        }
        if selecting != nil { return doneItem.item }
        guard host.isPastThreshold else { return nil }
        setSelectEnabled(holdsAnything(pile))
        return selectItem.item
    }

    /// "Remove from History (n)" / "Remove from Saved (n)", while selecting:
    /// in the selector's place in the bar, after the bell (#2475), in red.
    ///
    /// ⚠️ A NEW ITEM WHEN ITS WORD CHANGES, under the same identifier: a bar
    /// freezes an item's width when the item is made, and the count changes
    /// the word's width. The bar morphs one into the other (R3).
    var removeBarItem: UIBarButtonItem? {
        guard let pile = selecting else { return nil }
        let title = removeTitle(pile)
        if let kept = removeItem, kept.title == title {
            kept.label.isEnabled = !selection.isEmpty
            return kept.item
        }
        let made = BarItems.labeled(
            id: Self.removeItemID, title: title, image: nil, ink: .systemRed, textStyle: .headline
        ) { [weak self] in self?.removeSelected() }
        made.label.isEnabled = !selection.isEmpty
        made.label.accessibilityLabel = removeAccessibilityLabel(pile)
        removeItem = (made.item, made.label, title)
        return made.item
    }

    static let removeItemID = "profile.pile.remove"

    /// The Remove item, its view and the word it was made with.
    private var removeItem: (item: UIBarButtonItem, label: StretchedBarLabel, title: String)?

    /// Select and Done: the corner's word, in the primary (the owner,
    /// 2026-11-28), as wide as the word up to `cornerWordMaximumWidth` and
    /// truncated past it, so a longer translation never sweeps the bar into
    /// a `•••` — and the selector's budget reads the width drawn
    /// (`BarItems.word`), not a stock title's estimate, which swept Select
    /// on the owner's iPhone with four pages.
    private lazy var selectItem = Self.cornerWord(id: "profile.pile.select", title: "Select") {
        [weak self] in self?.setSelecting(true)
    }

    private lazy var doneItem = Self.cornerWord(id: "profile.pile.done", title: "Done") {
        [weak self] in self?.setSelecting(false)
    }

    /// The most Select or Done is ever wide, its margins included.
    static let cornerWordMaximumWidth: CGFloat = 120

    private static func cornerWord(
        id: String, title: String, action: @escaping () -> Void
    ) -> (item: UIBarButtonItem, label: StretchedBarLabel) {
        let made = BarItems.word(
            id: id, title: title, prominent: true, maximumWidth: cornerWordMaximumWidth, action: action
        )
        made.item.tintColor = Palette.prominentGlassTint
        return made
    }

    /// Select offered, or dimmed with nothing to select: the item and the
    /// word it draws.
    private func setSelectEnabled(_ enabled: Bool) {
        selectItem.item.isEnabled = enabled
        selectItem.label.isEnabled = enabled
    }

    /// Into, or out of, the shown pile's select mode. `restoresFoot` false:
    /// the screen is leaving (the bar recomposes at rest).
    func setSelecting(_ selecting: Bool, restoresFoot: Bool = true) {
        guard selecting != isSelecting else { return }
        let pile = selecting ? Self.pile(for: host.shownTab) : self.selecting
        guard let pile, !selecting || holdsAnything(pile) else { return }
        self.selecting = selecting ? pile : nil
        // Selecting holds the viewer on the pile: no paging to the other tabs.
        host.galleryPager.allowsPaging = !selecting
        let page = host.galleryPager.builtPage(for: pile.tab)
        page?.onRowSelectionChanged = { [weak self] ids in self?.selectionChanged(ids) }
        page?.setSelectingRows(selecting)
        selection = page?.selectedRowPostIDs ?? []
        if !selecting { removeItem = nil }
        host.applyNavigationState(animated: host.view.window != nil && restoresFoot)
    }

    /// A pile changed: Select is offered while there is something to select,
    /// and the select mode ends with the last row.
    func pilesChanged() {
        if let pile = Self.pile(for: host.shownTab) { setSelectEnabled(holdsAnything(pile)) }
        if let selecting, !holdsAnything(selecting) { setSelecting(false) }
    }

    private func selectionChanged(_ ids: [PostID]) {
        selection = ids
        // The count is in the word: the bar takes the new item.
        host.applyNavigationState(animated: host.view.window != nil)
    }

    private func removeTitle(_ pile: Pile) -> String {
        let count = selection.count
        return count == 0 ? "Remove from \(pile.name)" : "Remove from \(pile.name) (\(count))"
    }

    private func removeAccessibilityLabel(_ pile: Pile) -> String {
        let count = selection.count
        return count == 0 ? "Remove from \(pile.name)" : "Remove \(count) from \(pile.name)"
    }

    /// The selected rows leave the pile — History forgets them, Saved
    /// unsaves them — with the list's own animation; the select mode ends
    /// there, as Photos' does after a delete.
    private func removeSelected() {
        guard let pile = selecting else { return }
        let ids = selection
        guard !ids.isEmpty else { return }
        switch pile.tab {
        case .saved: host.viewModel.removeFromSaved(ids)
        default: host.viewModel.removeFromHistory(ids)
        }
        setSelecting(false)
    }

    #if DEBUG
    var debugRemoveTitle: String? { selecting.map(removeTitle) }
    var debugRemoveEnabled: Bool { isSelecting && !selection.isEmpty }
    func debugTapRemove() { removeSelected() }
    #endif
}
