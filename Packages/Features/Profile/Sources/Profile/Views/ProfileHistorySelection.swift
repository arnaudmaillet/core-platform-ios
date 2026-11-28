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
        if isSelectingHistory { return historyDoneItem }
        guard host.isPastThreshold else { return nil }
        historySelectItem.isEnabled = host.viewModel.hasHistory
        return historySelectItem
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

    private lazy var historySelectItem = BarItems.title(id: "profile.history.select", title: "Select") { [weak self] in
        self?.setSelectingHistory(true)
    }

    private lazy var historyDoneItem = BarItems.title(id: "profile.history.done", title: "Done", prominent: true) {
        [weak self] in self?.setSelectingHistory(false)
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
        historySelectItem.isEnabled = host.viewModel.hasHistory
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
