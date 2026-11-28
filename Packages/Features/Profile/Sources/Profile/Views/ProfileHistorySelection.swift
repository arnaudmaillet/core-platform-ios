import CoreModels
import DesignSystem
import PostGrid
import UIKit

/// What History's select mode asks of its screen (#2522): whose profile it
/// is and the tab on screen, the threshold, the pager and the bar it
/// recomposes.
@MainActor
protocol ProfileHistorySelectionHost: UIViewController {
    var isAccountRoot: Bool { get }
    var viewModel: ProfileViewModel { get }
    var shownTab: ProfileTab? { get }
    var isPastThreshold: Bool { get }
    var galleryPager: ProfileGalleryPagerView { get }
    func applyNavigationState(animated: Bool)
}

/// History's select mode, out of `ProfileViewController` (#2522): the rows'
/// selection, Select and Done in ✎'s place, and "Remove from History (n)"
/// in the selector's place in the bar (#2475).
///
/// ⚠️ SELECT AND DONE ARE KEPT INSTANCES (R3): the bar morphs one into the
/// other by reference, and Select's enabling changes in place.
@MainActor
final class ProfileHistorySelection {
    private unowned let host: any ProfileHistorySelectionHost

    init(host: any ProfileHistorySelectionHost) {
        self.host = host
    }

    /// History's rows wear their selection circles; the bar says Done, and
    /// "Remove from History (n)" in the selector's place.
    private(set) var isSelectingHistory = false
    private var historySelection: [PostID] = []

    /// The own profile, on its History page, in ✎'s place (#2307, #2475 §4):
    ///
    /// | History                       | the corner          |
    /// |-------------------------------|---------------------|
    /// | at rest                       | ✎ (nil here)        |
    /// | past the threshold            | Select (disabled with no history) |
    /// | selecting, wherever scrolled  | Done                |
    ///
    /// No Select at rest: it comes in past the threshold, as the selector
    /// does. Done holds while selecting, even back at the top — without it
    /// there would be no way out; after it, the scroll's rule again. The
    /// word: iOS's word for the mode (Photos, Files, Mail).
    var historySelectBarItem: UIBarButtonItem? {
        guard host.isAccountRoot, !host.viewModel.namesNoOne, host.shownTab == .history else { return nil }
        if isSelectingHistory { return historyDoneItem.item }
        guard host.isPastThreshold else { return nil }
        setSelectEnabled(host.viewModel.hasHistory)
        return historySelectItem.item
    }

    /// "Remove from History (n)", while selecting: in the selector's place
    /// in the bar, after the bell (#2475 — the selector's band at the foot,
    /// which wore it until then, went with the tab bar's accessory), in red.
    ///
    /// ⚠️ A NEW ITEM WHEN ITS WORD CHANGES, under the same identifier: a bar
    /// freezes an item's width when the item is made, and the count changes
    /// the word's width. The bar morphs one into the other (R3).
    var historyRemoveBarItem: UIBarButtonItem? {
        guard isSelectingHistory else { return nil }
        let title = historyRemoveTitle
        if let kept = historyRemoveItem, kept.title == title {
            kept.label.isEnabled = !historySelection.isEmpty
            return kept.item
        }
        let made = BarItems.labeled(
            id: Self.historyRemoveItemID, title: title, image: nil, ink: .systemRed, textStyle: .headline
        ) { [weak self] in self?.removeSelectedHistory() }
        made.label.isEnabled = !historySelection.isEmpty
        made.label.accessibilityLabel = historyRemoveAccessibilityLabel
        historyRemoveItem = (made.item, made.label, title)
        return made.item
    }

    static let historyRemoveItemID = "profile.history.remove"

    /// The Remove item, its view and the word it was made with.
    private var historyRemoveItem: (item: UIBarButtonItem, label: StretchedBarLabel, title: String)?

    /// Select and Done: the corner's word, in the primary (the owner,
    /// 2026-11-28), as wide as the word up to `cornerWordMaximumWidth` and
    /// truncated past it, so a longer translation never sweeps the bar into
    /// a `•••` — and the selector's budget reads the width drawn
    /// (`BarItems.word`), not a stock title's estimate, which swept Select
    /// on the owner's iPhone with four pages.
    private lazy var historySelectItem = Self.cornerWord(id: "profile.history.select", title: "Select") {
        [weak self] in self?.setSelectingHistory(true)
    }

    private lazy var historyDoneItem = Self.cornerWord(id: "profile.history.done", title: "Done") {
        [weak self] in self?.setSelectingHistory(false)
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
        historySelectItem.item.isEnabled = enabled
        historySelectItem.label.isEnabled = enabled
    }

    /// Into, or out of, History's select mode. `restoresFoot` false: the
    /// screen is leaving (the bar recomposes at rest).
    func setSelectingHistory(_ selecting: Bool, restoresFoot: Bool = true) {
        guard selecting != isSelectingHistory else { return }
        guard !selecting || (host.shownTab == .history && host.viewModel.hasHistory) else { return }
        isSelectingHistory = selecting
        // Selecting holds the viewer on History: no paging to the other tabs.
        host.galleryPager.allowsPaging = !selecting
        let page = host.galleryPager.builtPage(for: .history)
        page?.onRowSelectionChanged = { [weak self] ids in self?.historySelectionChanged(ids) }
        page?.setSelectingRows(selecting)
        historySelection = page?.selectedRowPostIDs ?? []
        if !selecting { historyRemoveItem = nil }
        host.applyNavigationState(animated: host.view.window != nil && restoresFoot)
    }

    /// History changed: Select is offered while there is something to
    /// select, and the select mode ends with the last row.
    func historyChanged() {
        setSelectEnabled(host.viewModel.hasHistory)
        if isSelectingHistory, !host.viewModel.hasHistory { setSelectingHistory(false) }
    }

    private func historySelectionChanged(_ ids: [PostID]) {
        historySelection = ids
        // The count is in the word: the bar takes the new item.
        host.applyNavigationState(animated: host.view.window != nil)
    }

    private var historyRemoveTitle: String {
        let count = historySelection.count
        return count == 0 ? "Remove from History" : "Remove from History (\(count))"
    }

    private var historyRemoveAccessibilityLabel: String {
        let count = historySelection.count
        return count == 0 ? "Remove from History" : "Remove \(count) from History"
    }

    /// The selected rows leave the history, with the list's own animation;
    /// the select mode ends there, as Photos' does after a delete.
    private func removeSelectedHistory() {
        let ids = historySelection
        guard !ids.isEmpty else { return }
        host.viewModel.removeFromHistory(ids)
        setSelectingHistory(false)
    }

    #if DEBUG
    var debugHistoryRemoveTitle: String? { isSelectingHistory ? historyRemoveTitle : nil }
    var debugHistoryRemoveEnabled: Bool { isSelectingHistory && !historySelection.isEmpty }
    func debugTapHistoryRemove() { removeSelectedHistory() }
    #endif
}
