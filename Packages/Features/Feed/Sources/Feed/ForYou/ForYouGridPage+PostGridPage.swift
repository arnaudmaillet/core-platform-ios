import FeedInterface
import MediaCore
import MediaPlayback
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
        case .sections(let groups):
            applyGroups(groups)
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

    func refreshAuthorMenus() {
        for case let row as PostGridListRowCell in collectionView.subviews {
            row.refreshAuthorMenu()
        }
    }

    /// Activating a vended page also ends a round trip's handoff — the
    /// host's way back from a post it opened (the profile's rule, #951): the
    /// landing has run by then, and an unlanded return player is released.
    ///
    /// ⚠️ NEVER `setAutoplayActive(_:)` (#1292) — see the requirement.
    func setPageActive(_ active: Bool) {
        if active, playback?.isHandingOff == true { endPlaybackHandoff() }
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

#if DEBUG
extension ForYouGridPage: PostGridPageDebugging {}
#endif

/// For You's grid page, built outside the feature's own builder — the
/// composition root's (`FeedFeatureBuilder.makePostGridPage`) and the
/// profile's tests, which draw the profile on the real page (#1273).
public enum PostGridPages {
    @MainActor
    public static func make(
        style: PostGridPageStyle, imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?, savesPosts: Bool
    ) -> any PostGridPage {
        ForYouGridPage(
            imagePipeline: imagePipeline, style: ForYouGridPage.Style(style),
            videoPlayback: videoPlayback, bookmarks: savesPosts ? .shared : nil
        )
    }
}
