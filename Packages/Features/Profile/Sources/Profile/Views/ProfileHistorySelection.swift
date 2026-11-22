import CoreModels
import DesignSystem
import PostGrid
import UIKit

/// What History's select mode asks of its screen (#2522): whose profile it
/// is and the tab on screen, the tray's place, the pager, the foot's
/// accessory and the bar it recomposes.
@MainActor
protocol ProfileHistorySelectionHost: UIViewController {
    var dayLeads: Bool { get }
    var viewModel: ProfileViewModel { get }
    var shownTab: ProfileTab? { get }
    var isTrayScrolledAway: Bool { get }
    var galleryPager: ProfileGalleryPagerView { get }
    var selectorAccessory: SelectorAccessory? { get }
    func applyNavigationState(animated: Bool)
}

/// History's select mode, out of `ProfileViewController` (#2522): the rows'
/// selection, Select and Done in the gear's place, and "Remove from History
/// (n)" at the foot.
///
/// ⚠️ SELECT AND DONE ARE KEPT INSTANCES (R3): the bar morphs one into the
/// other by reference, and Select's enabling changes in place.
@MainActor
final class ProfileHistorySelection {
    private unowned let host: any ProfileHistorySelectionHost

    init(host: any ProfileHistorySelectionHost) {
        self.host = host
    }

    /// History's rows wear their selection circles; the bar says Done and the
    /// foot of the screen "Remove from History (n)" in the tabs' place.
    private(set) var isSelectingHistory = false
    private var historySelection: [PostID] = []

    /// The own profile, on its History page, in the gear's place (#2307, the
    /// owner 2026-11-11):
    ///
    /// | History                    | the corner |
    /// |----------------------------|------------|
    /// | tray in sight              | the gear (nil here) |
    /// | tray scrolled away         | Select (disabled with no history) |
    /// | selecting, wherever scrolled | Done |
    ///
    /// No Select at rest: it comes in once the header's tray has gone under
    /// the bar, as someone else's Follow does (#2248). Done holds while
    /// selecting, even back at the top — without it there would be no way
    /// out; after it, the scroll's rule again. The word, not a pencil: iOS's
    /// word for the mode (Photos, Files, Mail), beside the header's Edit
    /// profile.
    var historySelectBarItem: UIBarButtonItem? {
        guard host.dayLeads, !host.viewModel.namesNoOne, host.shownTab == .history else { return nil }
        if isSelectingHistory { return historyDoneItem }
        guard host.isTrayScrolledAway else { return nil }
        historySelectItem.isEnabled = host.viewModel.hasHistory
        return historySelectItem
    }

    /// History's Select or Done, if the bar wears one now.
    var shownHistoryBarItem: UIBarButtonItem? {
        host.ownTrailingBarItems.first { $0 === historySelectItem || $0 === historyDoneItem }
    }

    private lazy var historySelectItem = BarItems.title(id: "profile.history.select", title: "Select") { [weak self] in
        self?.setSelectingHistory(true)
    }

    private lazy var historyDoneItem = BarItems.title(id: "profile.history.done", title: "Done", prominent: true) {
        [weak self] in self?.setSelectingHistory(false)
    }

    /// The select mode's one action, in the selector's place: "Remove from
    /// History (n)", in red, the accessory's own capsule around it.
    private lazy var historyRemoveButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .systemRed
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaledFont(forTextStyle: .headline, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.removeSelectedHistory() }, for: .primaryActionTriggered)
        return button
    }()

    /// Into, or out of, History's select mode. `restoresFoot` false: the
    /// screen is leaving, and its own disappearance takes the band down.
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
        applyHistoryRemoveTitle()
        swapFootForHistoryRemove(selecting, restoresFoot: restoresFoot)
        host.applyNavigationState(animated: host.view.window != nil)
    }

    /// History changed: Select is offered while there is something to
    /// select, and the select mode ends with the last row.
    func historyChanged() {
        historySelectItem.isEnabled = host.viewModel.hasHistory
        if isSelectingHistory, !host.viewModel.hasHistory { setSelectingHistory(false) }
    }

    private func historySelectionChanged(_ ids: [PostID]) {
        historySelection = ids
        applyHistoryRemoveTitle()
    }

    private func applyHistoryRemoveTitle() {
        let count = historySelection.count
        historyRemoveButton.configuration?.title = count == 0 ? "Remove from History" : "Remove from History (\(count))"
        historyRemoveButton.isEnabled = count > 0
        historyRemoveButton.accessibilityLabel = count == 0
            ? "Remove from History" : "Remove \(count) from History"
    }

    /// The selected rows leave the history, with the list's own animation;
    /// the select mode ends there, as Photos' does after a delete.
    private func removeSelectedHistory() {
        let ids = historySelection
        guard !ids.isEmpty else { return }
        host.viewModel.removeFromHistory(ids)
        setSelectingHistory(false)
    }

    /// The foot of the screen: the selector's own accessory wears "Remove
    /// from History (n)" in the strip's place while selecting — the same
    /// capsule, its content replaced (the owner, 2026-11-08) — and the strip
    /// again after. `restoresFoot` is kept for a screen leaving, whose band
    /// its own disappearance takes down with the stand-in in it.
    private func swapFootForHistoryRemove(_ selecting: Bool, restoresFoot: Bool) {
        let animated = host.view.window != nil && restoresFoot
        host.selectorAccessory?.showStandIn(selecting ? historyRemoveButton : nil, animated: animated)
    }

    #if DEBUG
    var debugHistoryRemoveTitle: String? { historyRemoveButton.configuration?.title }
    var debugHistoryRemoveEnabled: Bool { historyRemoveButton.isEnabled }
    func debugTapHistoryRemove() { removeSelectedHistory() }
    #endif
}
