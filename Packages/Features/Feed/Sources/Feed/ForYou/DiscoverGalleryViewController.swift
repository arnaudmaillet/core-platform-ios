import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// Discover's whole mosaic, pushed from a chunk's "View all": the chaotic grid
/// that WAS the Discover tab until the tab became a list (2026-09-28), now a
/// screen of its own with the platform's back button.
///
/// # What it is, and what it borrows
///
/// A `ForYouGridPage` in its `.grid` style over For You's own corpus — the
/// media-only state (`ForYouViewModel.Snapshot.media`), the same posts the
/// tab's chunks draw from — driven by `ForYouViewController`, which forwards
/// each snapshot, the paging spinner and the refresh while this screen is on
/// the stack. One view model, so the gallery and the list page the same
/// cursor and never disagree about what is loaded.
///
/// # Why it opens posts the way the place page does, not the way For You does
///
/// A tile opens through `presentSnapFeedHero` — the builder's flight, the one
/// the place page and the search results use — not through For You's own
/// `openFeed`. For You's machinery is keyed to its PAGER (the pages, the
/// selector strip, the view's coordinate space, its appearance callbacks), and
/// this screen covers the pager while it is up; lending it that machinery
/// would mean either re-plumbing all of it through a second host or keeping
/// For You's appearance hooks alive for a screen that is not appearing. The
/// shared flight gives this screen everything a mosaic needs — the hero out of
/// the tile, a grab and a chevron that fly home to it, the settled post's
/// picture blended in on the way back, the dock through UIKit — and differs
/// from For You's grid in one stated way: a close after paging lands on the
/// tile the viewer OPENED (wearing the picture they ended on), rather than
/// swapping the post they ended on into that slot. The same answer every other
/// pushed gallery in the app gives.
///
/// The tab bar stays up (no `hidesBottomBarWhenPushed`): this is a place to
/// browse, one level into the tab, and the bar is how the viewer leaves it.
@MainActor
final class DiscoverGalleryViewController: UIViewController {
    static let title = "Discover"

    private let page: ForYouGridPage

    /// Opens a post WITH a flight — the builder's `presentSnapFeedHero`,
    /// handed down through For You. Nil leaves a tap doing nothing, which is
    /// only the case in a test.
    private let openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?

    /// The page scrolled near its end: the host fetches the next page.
    var onNearEnd: (() -> Void)?
    /// Pull to refresh.
    var onRefresh: (() -> Void)?

    /// How many posts follow the tapped one into the feed — For You's own
    /// number, because this is For You's mosaic.
    private static let seedWindow = 40

    init(
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?
    ) {
        page = ForYouGridPage(imagePipeline: imagePipeline, style: .grid, videoPlayback: videoPlayback)
        self.openPost = openPost
        super.init(nibName: nil, bundle: nil)
        title = Self.title
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        page.pin(to: view)
        page.onItemTapped = { [weak self] index in self?.openTile(at: index) }
        page.onNearEnd = { [weak self] in self?.onNearEnd?() }
        page.onRefresh = { [weak self] in self?.onRefresh?() }
    }

    // MARK: - Content, from the host

    func render(_ state: ForYouViewModel.PageState) {
        loadViewIfNeeded()
        page.render(state)
    }

    func setPaging(_ paging: Bool) {
        page.setPaging(paging)
    }

    func endRefreshing() {
        page.endRefreshing()
    }

    /// The posts on screen, in display order — what a test and a debug hook
    /// read.
    var posts: [GalleryPost] { page.posts }

    // MARK: - Appearance

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from a post: the dock is UIKit's to bring back, at the
        // moment the policy allows (the feed normally has already asked —
        // this is the backstop). Only where this stack shows the app's bar.
        guard let navigationController, navigationController.showsAppTabBar(for: self) else { return }
        revealBottomChromeWhenAllowed(animated: animated) { [weak self] animated in
            guard let tabs = self?.tabBarController, tabs.isTabBarHidden else { return }
            if animated { tabs.showTabBarNatively() } else { tabs.setTabBarHidden(false, animated: false) }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The bar floats over the grid without insetting it; measured now,
        // while it is up, for the reveal that runs when the next post covers
        // this screen. See `ForYouGridPage.footChromeCover`.
        tabBarController?.view.layoutIfNeeded()
        page.footChromeCover = floatingBarCover
        // Nothing on this screen may be invisible once it is back, whoever
        // finished the close — see `ForYouViewController.viewDidAppear`, which
        // makes the same sweep for the same reason.
        page.clearRevealConcealment()
        page.clearHeroConcealment()
        // The handoff a tap opened is over: the post is a tile among tiles
        // again, and every visible one may claim a player.
        page.endPlaybackHandoff()
        page.setAutoplayActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Off screen — covered by a post, or popped — this grid holds no claim
        // on the shared pool. The tapped post's player is exempt: it is in
        // the handoff scope, flying.
        page.setAutoplayActive(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The tapped tile, settled clear of the chrome now that a post covers
        // the grid — where the move costs nothing to look at, and before a
        // close reads the tile's rect.
        page.applyPendingReveal()
    }

    /// How much of this screen's foot the tab bar covers.
    private var floatingBarCover: CGFloat {
        guard let bar = tabBarController?.tabBar, !bar.isHidden, let host = bar.superview
        else { return view.safeAreaInsets.bottom }
        let inPage = view.convert(bar.frame, from: host)
        return max(view.safeAreaInsets.bottom, view.bounds.maxY - inPage.minY)
    }

    // MARK: - Opening a tile

    /// The departure, described for the shared flight — the place page's and
    /// the search results' `openTile`, for a page that is only ever a grid.
    private func openTile(at index: Int) {
        let posts = page.posts
        guard posts.indices.contains(index), let openPost else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        let hero = page.hero(for: tapped.id, in: view)
        let appearance = page.heroAppearance(for: tapped.id)
        // The tapped tile's player is the flight's from here: the grid's own
        // reconcile must neither restart nor stop it while it is in the air.
        page.beginPlaybackHandoff(of: tapped.id)
        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            style: .tile,
            frame: { [weak page] space in page?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak page] in page?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak page] concealed in
                page?.setHeroHidden(concealed, for: tapped.id)
            },
            // The card takes off PLAYING, joining the tile's own surface.
            donateLiveMedia: { [weak page] in page?.liveFlightSurface(for: tapped.id) },
            depthView: { [weak page] in page }
        )
        openPost(self, origin, stream.map(\.id))
    }

    #if DEBUG
    /// Taps tile `index` through the page's own selection path, the one a
    /// finger reaches. False while that tile is not loaded yet.
    func debugOpenTile(at index: Int) -> Bool {
        page.debugSelectItem(at: index)
    }

    /// Whether tile `index` has a cover to fly — what a scripted open waits
    /// on, as `-foryou-open` does.
    func debugTileIsReady(at index: Int) -> Bool {
        guard page.posts.indices.contains(index) else { return false }
        return page.heroAppearance(for: page.posts[index].id)?.cover != nil
    }
    #endif
}
