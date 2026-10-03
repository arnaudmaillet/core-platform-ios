import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// Discover's whole mosaic, pushed from a chunk's "View all" or the "For you ›"
/// heading over the list (`ForYouRailsView`): the chaotic grid that WAS the
/// Discover tab until the tab became a list (2026-09-28), now a screen of its
/// own with the platform's back button.
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
/// # Its chrome
///
/// No tab bar (`hidesBottomBarWhenPushed`, UIKit's own choreography) and no
/// title: the header is `[‹] ———— [points][search]`, the one every screen For
/// You pushes wears (`PushedScreenHeader`, product call 2026-09-29; #323's
/// "For you" large title was taken back on 2026-09-30). The back chevron is
/// how the viewer leaves; the mosaic has the whole screen.
///
/// # Holding still under a post
///
/// The mosaic's inset is pinned from a tap until the screen is back
/// (`ForYouGridPage.openHoldingStill`), for the reason
/// `ForYouPostListViewController` gives: a gallery that tracked the safe area
/// while covered came back shifted.
@MainActor
final class DiscoverGalleryViewController: UIViewController {
    private let page: ForYouGridPage
    /// `[points][search]`, held for the screen's life — see `PushedScreenHeader`.
    private let header: PushedScreenHeader

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

    /// - Parameter staking: where the tiles' hearts read the viewer's stake
    ///   (red once staked) — For You's own, so the gallery and the list
    ///   behind it agree. The hearts are readouts; nothing here spends.
    init(
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        header: PushedScreenHeader,
        staking: PostCardStaking? = nil,
        openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?
    ) {
        page = ForYouGridPage(imagePipeline: imagePipeline, style: .grid, videoPlayback: videoPlayback)
        page.staking = staking
        // The large tiles wear their author and caption start (`PostTileInfo`),
        // as Discover's chunks do.
        page.showsTileInfo = true
        self.header = header
        self.openPost = openPost
        super.init(nibName: nil, bundle: nil)
        // UIKit takes the bar down with the push and brings it back with the
        // pop — the pushed profile's arrangement. A post opened from here then
        // finds no dock to give back (`showsAppTabBar(for:)` reads this flag),
        // which is right: this screen never shows one.
        hidesBottomBarWhenPushed = true
        header.install(on: self)
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

    // NO DOCK REVEAL on the way back from a post, and none is owed: this screen
    // is pushed with `hidesBottomBarWhenPushed`, so there is no bar here to
    // give back — the flight's backstop asks `showsAppTabBar(for:)` and gets
    // the same answer.

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if DEBUG
        PushedListJumpTrace.begin("gallery will-appear", page: page, host: view)
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back: the inset tracks the safe area again, offset carried across.
        page.endHeroFreeze()
        #if DEBUG
        PushedListJumpTrace.mark("gallery did-appear", page: page, host: view)
        #endif
        // Nothing floats over this grid's foot — the tab bar is down for the
        // screen's whole life — so the safe area is the whole cover. See
        // `ForYouGridPage.footChromeCover`.
        page.footChromeCover = view.safeAreaInsets.bottom
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
        #if DEBUG
        PushedListJumpTrace.mark("gallery open", page: page, host: view)
        #endif
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
            depthView: { [weak page] in page },
            // ⚠️ THE CLOSE FROM A TEXT PAGE. The feed is a pager: page from
            // the tile's picture onto a post with only words, and there is no
            // picture left to fly — both grabs refuse the `.card` page and the
            // flight declines the chevron. The tile's own window is what that
            // close lands through (`RowCardCloseLanding`), as the tile's
            // picture rather than as a post card.
            textReveal: page.tileWindow(
                for: tapped,
                willStageDismissal: { [weak page] in
                    // Pinned before the landing is measured, the list's order.
                    page?.beginHeroFreeze()
                    page?.revealPost(tapped.id)
                },
                // No thaw here: `viewDidAppear` hands the inset back, once the
                // pop has settled the chrome — a window's close ends before
                // it, and a thaw then re-bases the mosaic on a mid-flight
                // inset (`ForYouPostListViewController.textRowReveal`).
                dismissalDidEnd: { [weak page] committed in
                    if !committed { page?.clearRevealConcealment() }
                }
            ),
            // A large tile's words (`PostTileInfo`), worn by the card
            // at the tile's end and faded as it grows — the Following row's
            // arrangement. Nil for a tile that wears none.
            restingOverlay: { [weak page] in page?.restingOverlay(for: tapped.id) },
            // A tile's heart flies red once the viewer has staked.
            viewerStake: { [weak page] in page?.viewerStake(on: tapped.id) ?? 0 },
            // Pinned since the tap; the close measures a mosaic holding still.
            willStageDismissal: { [weak page] in page?.pinForPushedClose() }
        )
        page.openHoldingStill(from: self) { openPost(self, origin, stream.map(\.id)) }
    }

    #if DEBUG
    /// Taps tile `index` through the page's own selection path, the one a
    /// finger reaches. False while that tile is not loaded yet.
    func debugOpenTile(at index: Int) -> Bool {
        page.debugSelectItem(at: index)
    }

    /// Scrolls `offset` points into the content — `-foryou-pushed-scroll`.
    func debugScroll(to offset: CGFloat) {
        page.setVerticalOffset(offset)
    }

    /// Tile `index`'s size on screen — nil while it is not realized. What
    /// picks a tile large enough for words (`PostTileInfo`) to film or test.
    /// Whether the mosaic's tiles wear their words (`PostTileInfo`).
    var debugShowsTileInfo: Bool { page.showsTileInfo }

    func debugTileSize(at index: Int) -> CGSize? {
        guard page.posts.indices.contains(index) else { return nil }
        return page.debugCell(for: page.posts[index].id)?.bounds.size
    }

    /// Whether tile `index` has a cover to fly — what a scripted open waits
    /// on, as `-foryou-open` does.
    func debugTileIsReady(at index: Int) -> Bool {
        guard page.posts.indices.contains(index) else { return false }
        return page.heroAppearance(for: page.posts[index].id)?.cover != nil
    }
    #endif
}
