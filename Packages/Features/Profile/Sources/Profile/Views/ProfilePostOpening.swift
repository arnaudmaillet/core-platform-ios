import CoreModels
import FeedInterface
import PostGrid
import ProfileData
import UIKit

/// What opening a post asks of its screen (#2522): the view model, the
/// pager and its tabs, the feed's hero seam, the grid pages' factory, the
/// handle and the last gallery.
@MainActor
protocol ProfilePostOpeningHost: UIViewController {
    var viewModel: ProfileViewModel { get }
    var galleryPager: ProfileGalleryPagerView { get }
    var tabs: [ProfileTab] { get }
    var feedHero: (([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)? { get }
    var makeGridPage: ProfileGridPageFactory { get }
    var currentHandle: String? { get }
    var lastGallerySnapshot: ProfileViewModel.GallerySnapshot? { get }
}

/// Opening a gallery post, and the media gallery "View all" pushes, out of
/// `ProfileViewController` (#2522).
///
/// ⚠️ ONE OPENING AT A TIME, and a refused open ends the playback handoff
/// (`endPlaybackHandoff`) — see `openGalleryPost`.
@MainActor
final class ProfilePostOpening {
    private unowned let host: any ProfilePostOpeningHost

    init(host: any ProfilePostOpeningHost) {
        self.host = host
    }

    /// That gallery while it is up, so the pages landing reach it.
    private(set) weak var mediaGallery: ProfileMediaGalleryViewController?

    /// "View all" under one of Posts' chunks: the profile's photos and videos
    /// as the media mosaic (#631) — what the Gallery tab was.
    ///
    /// Fed from here as pages land (`onGalleryChange`), under the same
    /// source, and its posts open through `openGalleryPost` measured against
    /// ITS mosaic, so a close lands on the tile it left from.
    /// What "View all" pushes is the page on screen's media (#696): Reposts
    /// and Tagged have their own, on every profile since #772.
    private var mediaGalleryTitle: String {
        switch host.tabs[host.galleryPager.activePageIndex] {
        case .reposts: "Reposted Media"
        case .tagged: "Tagged Media"
        default: ProfileTab.format(.media).title
        }
    }

    func pushMediaGallery() {
        guard host.navigationController?.transitionCoordinator == nil else { return }
        let savesPosts = host.viewModel.bookmarks != nil
        let makeGridPage = host.makeGridPage
        let gallery = ProfileMediaGalleryViewController(
            handle: host.currentHandle, title: mediaGalleryTitle
        ) { [makeGridPage] style in makeGridPage(style, savesPosts) }
        gallery.loadViewIfNeeded()
        gallery.render(host.lastGallerySnapshot?.media ?? .loading)
        gallery.onOpen = { [weak self, weak gallery] post, stream, showingComments in
            guard let self, let gallery else { return }
            openGalleryPost(
                post, stream: stream, showingComments: showingComments,
                from: gallery.grid, presenter: gallery, format: .media
            )
        }
        gallery.onNearEnd = { [weak self] in self?.host.viewModel.loadMoreGallery() }
        // ⚠️ THE LIST ON SCREEN IS THE MEDIA NOW, and the model pages for it:
        // a page of text posts adds no tile here, so no tile would come on
        // screen to ask for the next one — the model reads on instead, as it
        // does for whichever list is showing (`appendGalleryPages`).
        host.viewModel.setGalleryFormat(.media)
        gallery.onClose = { [weak self] in self?.host.viewModel.setGalleryFormat(.activity) }
        mediaGallery = gallery
        host.navigationController?.pushViewController(gallery, animated: true)
    }

    /// Opens a gallery post — from its card, or from its comment chip with the
    /// thread already up (`showingComments`, never set for a text post: its
    /// page IS its thread).
    ///
    /// `surface` is the list it was tapped in — the profile's pager unless
    /// said otherwise, or the media gallery its "View all" pushed (#631),
    /// which then also `presents` the feed and names its `format` for the
    /// feed's continuation.
    func openGalleryPost(
        _ post: GalleryPost, stream: [GalleryPost], showingComments: Bool,
        from surface: (any PostGridPage)? = nil,
        presenter: UIViewController? = nil,
        format: GalleryFilter.Format = .activity
    ) {
        let presenter: UIViewController = presenter ?? host
        // One opening at a time: a second tap while the first push is in the
        // air pushed a second feed over it.
        guard host.navigationController?.transitionCoordinator == nil else { return }
        let window = stream.isEmpty ? [post] : stream
        // ⚠️ EVERY tap goes through the hero seam, including the ones with
        // no hero to fly.
        //
        // It used to branch here: no geometry meant no flight, and no
        // flight meant falling out of the feature entirely onto
        // `AppRoute.postStream` — a bare push with no dismissal gesture, no
        // tab-bar hide and no projection. That branch was written as "the
        // animation degrades", but what actually degraded was the screen:
        // text-only posts opened under the tab bar, empty, and could not be
        // swiped away at all.
        //
        // The choice of presentation belongs to the feed, which owns both
        // the card and the dismissal — so this screen says only what it
        // has, and `hasHero` is the whole of what it knows about flying.
        guard let feedHero = host.feedHero else {
            // No composition root wired the seam (previews, tests). The
            // route is still the honest answer there — and it is the only
            // caller left that has to settle for it.
            host.viewModel.galleryItemTapped(post.id, stream: window.map(\.id))
            return
        }
        guard let page = surface ?? host.galleryPager.activePage else { return }
        // ⚠️ THE ONE TILE CONTRACT (#1273, epic #1269): For You's page
        // describes its tile — a take-off playing, the playhead continued on
        // a same-post close (this used to restart the clip), the tile's own
        // parked clip after paging on, the words faded in on a close, the
        // tile's or the card's window when there is no picture to fly.
        let origin = page.heroOrigin(
            opening: post, stream: window, in: presenter.view,
            textReveal: page.closeWindow(
                for: post, alignsPageToSource: true,
                willStageDismissal: {},
                dismissalDidEnd: { _ in }
            ),
            opensComments: showingComments,
            willStageDismissal: {},
            // The header floats over pages whose insets never move while a
            // post covers them (`contentInsetAdjustmentBehavior = .never`).
            pinsBeforeClose: false,
            continuation: { [weak self] after in
                await self?.host.viewModel.galleryPostIDs(after: after, in: format)
            }
        )
        feedHero(window.map(\.id), presenter, origin)
        // ⚠️ A REFUSED OPEN PUSHES NOTHING (the stack mid-transition), and the
        // scope opened above would then hold this still-visible grid silent:
        // only the screen's next appearance ends it, and it never disappeared.
        // The push is synchronous, so the stack already says which happened.
        if let navigation = presenter.navigationController,
           navigation.topViewController === presenter, presenter.presentedViewController == nil {
            page.endPlaybackHandoff()
        }
    }
}
