import FeedInterface
import PostGrid
import UIKit

/// For You's page, vended across the package line (#1273): the profile's pages
/// are these. Internal witnesses satisfy the public protocol — nothing in Feed
/// becomes public for it.
extension ForYouGridPage: PostGridPage {
    func show(_ state: PostGridPageState) {
        switch state {
        case .loading:
            render(ForYouViewModel.PageState.loading)
        case .content(let posts):
            render(ForYouViewModel.PageState.content(posts))
        case .status(let status):
            showStatus(
                symbolName: status.symbolName, title: status.title, subtitle: status.subtitle,
                actionTitle: status.actionTitle,
                action: status.actionTitle == nil ? nil : { [weak self] in self?.onRefresh?() }
            )
        }
    }

    var postMenuActions: ((PostGridAuthorMenuContext) -> [PostCardMenuAction])? {
        get { authorMenuActions }
        set { authorMenuActions = newValue }
    }

    var scrollView: UIScrollView { collectionView }

    func setAutoplayActive(_ active: Bool) {
        setAutoplayActive(active, keeping: nil)
    }
}

extension ForYouGridPage.Style {
    init(_ style: PostGridPageStyle) {
        switch style {
        case .grid: self = .grid
        case .list: self = .list
        case .discover: self = .discover
        }
    }
}
