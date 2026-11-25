import CoreModels
import PostSurfaces
import UIKit

/// The screen's side of `-snap-layout-v2` (#2407): what a page's chrome — a
/// live cell's or the flight's replica — is told about the layout.
extension SnapFeedViewController {
    /// The column for `model` under the screen's flag (#2408): v2's bubbles
    /// on a media page, the post's saved star and its tap. Flag off, the
    /// column is the classic one and nothing here shows.
    func applyColumnLayout(to chrome: SnapChromeView, for model: FeedItemDisplayModel) {
        chrome.actionColumn.setLayoutV2(layoutV2)
        chrome.actionColumn.setSaved(bookmarks.isSaved(model.id.rawValue))
        let id = model.id
        chrome.actionColumn.onSaveRequested = { [weak self] in self?.toolbarComposer.toggleBookmark(for: id) }
    }
}
