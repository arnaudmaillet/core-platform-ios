import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// A row's whole list, pushed from its header: the people the viewer FOLLOWS,
/// or their FRIENDS (2026-09-29).
///
/// # What it is
///
/// A plain list of posts, one after another: the profile's Activity tab
/// without the profile — the same timeline cards (`PostGridListRowCell`) on
/// the same list layout, through a `ForYouGridPage` in its `.list` style. No
/// sections and no mosaic chunks (the product call of 2026-09-29: the "New" /
/// "Recent" halves the Following TAB had are gone with the tab; what is new
/// is the row's badge, not a division of this list). Driven by
/// `ForYouViewController`, which forwards each snapshot, the paging spinner
/// and the refresh while this screen is on the stack — one view model, so the
/// row, its badge and this list never disagree about what is loaded. Friends
/// is the same screen over the friends' posts.
///
/// # How it opens posts
///
/// Through `presentSnapFeedHero` — the builder's shared flight, the one the
/// place page, the search results and Discover's mosaic use — for the reason
/// `DiscoverGalleryViewController` gives: For You's own `openFeed` is keyed to
/// For You's page and its appearance, and this screen covers both. A media
/// row flies; a text row opens as a WINDOW shaped like the place page's
/// (`textRowReveal`), and a close lands on the row the viewer opened, order
/// untouched — the product rule for a list.
///
/// # Its chrome
///
/// No tab bar (`hidesBottomBarWhenPushed`) and no title: `[‹] ——
/// [points][search]`, the header every screen For You pushes wears
/// (`PushedScreenHeader`).
@MainActor
final class ForYouPostListViewController: UIViewController {
    /// Which row this list is the whole of.
    enum Kind: String {
        case following
        case friends
    }

    let kind: Kind
    private let page: ForYouGridPage
    private let header: PushedScreenHeader
    /// Opens a post WITH a flight — see the type's note. Nil leaves a tap
    /// doing nothing, which is only the case in a test.
    private let openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?

    /// The page scrolled near its end: the host fetches the next page.
    var onNearEnd: (() -> Void)?
    /// Pull to refresh.
    var onRefresh: (() -> Void)?
    /// A row's author was tapped.
    var onAuthorTapped: ((GalleryPost) -> Void)?
    /// What a row's "..." offers — the host's, so this screen offers exactly
    /// what For You's own list does.
    var authorMenuActions: ((ForYouGridPage.AuthorMenuContext) -> [PostCardMenuAction])? {
        didSet { page.authorMenuActions = authorMenuActions }
    }
    /// What is on screen and worth warming — see `ForYouGridPage.onWarmRequested`.
    var onWarmRequested: (([GalleryPost]) -> Void)? {
        didSet { page.onWarmRequested = onWarmRequested }
    }

    /// How many posts follow the tapped one into the feed — For You's number.
    private static let seedWindow = 40

    init(
        kind: Kind,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        staking: PostCardStaking?,
        header: PushedScreenHeader,
        openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?
    ) {
        self.kind = kind
        page = ForYouGridPage(imagePipeline: imagePipeline, style: .list, videoPlayback: videoPlayback)
        self.header = header
        self.openPost = openPost
        super.init(nibName: nil, bundle: nil)
        // The like chips stake from the same wallet For You's list does — one
        // surface, one undo window (`PostCardStaking`).
        page.staking = staking
        // UIKit takes the bar down with the push and brings it back with the
        // pop; a post opened from here finds no dock to give back
        // (`showsAppTabBar(for:)` reads this flag).
        hidesBottomBarWhenPushed = true
        header.install(on: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        page.pin(to: view)
        page.onItemTapped = { [weak self] index in self?.openRow(at: index) }
        page.onItemCommentsTapped = { [weak self] index in self?.openRow(at: index, showingComments: true) }
        page.onNearEnd = { [weak self] in self?.onNearEnd?() }
        page.onRefresh = { [weak self] in self?.onRefresh?() }
        page.onAuthorTapped = { [weak self] post in self?.onAuthorTapped?(post) }
    }

    // MARK: - Content, from the host

    /// The posts, one after another, in the order they come — no "New" and
    /// "Recent" halves (see the type's note).
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

    /// The next delivery is a re-derived corpus, not an extended one — see
    /// `ForYouViewModel.onCorpusReset`.
    func invalidateIncrementalUpdates() {
        page.invalidateIncrementalUpdates()
    }

    /// The posts on screen, in display order — what a test and a debug hook
    /// read.
    var posts: [GalleryPost] { page.posts }

    // MARK: - Appearance

    // NO DOCK REVEAL on the way back from a post: there is no bar on this
    // screen to give back (`hidesBottomBarWhenPushed`).

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Nothing floats over this list's foot but the home indicator's band.
        page.footChromeCover = view.safeAreaInsets.bottom
        // Nothing on this screen may be invisible once it is back, whoever
        // finished the close — the sweep `ForYouViewController.viewDidAppear`
        // makes, for the same reason.
        page.clearRevealConcealment()
        page.clearHeroConcealment()
        page.endPlaybackHandoff()
        page.setAutoplayActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Covered by a post, or popped: no claim on the shared pool. The
        // tapped row's player is exempt — it is in the handoff scope, flying.
        page.setAutoplayActive(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The tapped row, settled clear of the chrome now that a post covers
        // the list — before a close reads its rect.
        page.applyPendingReveal()
    }

    // MARK: - Opening a row

    /// What covers this list: the navigation bar above, the home indicator's
    /// band below. Its content insets are exactly that chrome, so the page's
    /// own default would do — stated for the window's landing, which asks.
    private var landingOcclusion: UIEdgeInsets {
        UIEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: view.safeAreaInsets.bottom, right: 0)
    }

    /// The departure, described for the shared flight — the place page's
    /// `openTile` for a page that is only ever a list.
    private func openRow(at index: Int, showingComments: Bool = false) {
        let posts = page.posts
        guard posts.indices.contains(index), let openPost,
              navigationController?.topViewController === self,
              navigationController?.transitionCoordinator == nil
        else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        let hero = page.hero(for: tapped.id, in: view)
        let appearance = page.heroAppearance(for: tapped.id)
        // The tapped row's player is the flight's from here.
        page.beginPlaybackHandoff(of: tapped.id)
        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            style: appearance?.style == .tile ? .tile : .listMedia,
            frame: { [weak page] space in page?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak page] in page?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak page] concealed in
                page?.setHeroHidden(concealed, for: tapped.id)
            },
            // The card takes off PLAYING, joining the row's own surface.
            donateLiveMedia: { [weak page] in page?.liveFlightSurface(for: tapped.id) },
            // A TEXT post's page IS its thread — see `opensComments`.
            opensComments: showingComments && tapped.kind != .text,
            depthView: { [weak page] in page },
            textReveal: textRowReveal(for: tapped)
        )
        openPost(self, origin, stream.map(\.id))
    }

    /// The window a TEXT row opens through — and ANY row closes through once
    /// the feed is on a text page — or nil for a row the list cannot find, the
    /// plain push then being the honest floor.
    ///
    /// ⚠️ OFFERED FOR MEDIA ROWS TOO. `hasHero` decides the opening; this
    /// decides whether a close that has nothing to fly has anywhere to go. A
    /// photograph opened by a flight and paged onto a text post leaves both
    /// zoom grabs refusing and the chevron's hero failing, unless the origin
    /// carries a window for `RowCardCloseLanding` to arm — the profile's rule
    /// ("Offered for EVERY post") and For You's rows' (`ForYouRowOrigins`).
    ///
    /// ⚠️ MARKER-SHAPED, and for the place page's reason
    /// (`PlaceProfileViewController.textRowReveal`): the feed is a PAGER, so
    /// the row and the page are only the same post until the first swipe. The
    /// window therefore does not align the page to the row's caption; it opens
    /// over a page that holds still, and closes onto the row it opened from.
    private func textRowReveal(for post: GalleryPost) -> TextRevealOrigin? {
        guard page.rowFrame(for: post.id, in: page) != nil else { return nil }
        let anchor = post.id
        return TextRevealOrigin(
            rowFrame: { [weak page] space in
                page?.textRowFrame(for: anchor, in: space) ?? page?.rowFrame(for: anchor, in: space)
            },
            captionEnd: nil,
            depthView: { [weak page] in page },
            makeDismissStandIn: { [weak page] _ in page?.makeDismissStandIn(for: anchor) },
            alignsPageToSource: false,
            // The media fills the window, always — see `RevealPageFit.covering`.
            pageFit: .covering,
            setConcealed: { [weak page] concealed in
                page?.setRevealConcealed(concealed, for: anchor)
            },
            // The row may have scrolled under the open post; bring it back, and
            // pin the inset before the landing is measured.
            willStageDismissal: { [weak self] _ in
                guard let self else { return }
                view.layoutIfNeeded()
                page.beginHeroFreeze()
                page.revealPost(anchor, clearing: landingOcclusion)
                view.layoutIfNeeded()
            },
            dismissalDidEnd: { [weak page] committed in
                page?.endHeroFreeze()
                if !committed { page?.clearRevealConcealment() }
            }
        )
    }

    #if DEBUG
    /// Taps row `index` through the page's own selection path.
    func debugOpenRow(at index: Int) -> Bool {
        page.debugSelectItem(at: index)
    }

    /// Whether row `index` is loaded and has what it would fly.
    func debugRowIsReady(at index: Int) -> Bool {
        guard page.posts.indices.contains(index) else { return false }
        let post = page.posts[index]
        return post.kind == .text || page.heroAppearance(for: post.id)?.cover != nil
    }
    #endif
}
