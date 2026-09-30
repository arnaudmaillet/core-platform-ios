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
/// A list of posts: the profile's Activity tab without the profile — the same
/// timeline cards (`PostGridListRowCell`) on the same list layout, through a
/// `ForYouGridPage` in its `.list` style, no mosaic chunks. Driven by
/// `ForYouViewController`, which forwards each snapshot, the paging spinner
/// and the refresh while this screen is on the stack — one view model, so the
/// row, its badge and this list never disagree about what is loaded. Friends
/// is the same screen over the friends' posts.
///
/// # Its sections
///
/// "New" over what the viewer has not seen, "Recent" over the rest — the
/// Messages inbox's split, with its headers: a large title in the flow that
/// pins under the bar as a Liquid Glass capsule (`SectionHeaderPillButton`,
/// tap to scroll to the section). "New" carries its count in the red badge
/// (`NotificationCountBadge`) the For You header this list was pushed from
/// wears, and it is the same number by construction: both are the size of the
/// set the view model hands over (`Snapshot.followingNew` for Following,
/// `.friendsUnseen` for Friends). #313 had made this list one plain run; the
/// sections came back on 2026-09-29 by product call, on BOTH lists because
/// they are one screen whose header badges answer the same question.
///
/// A section with nothing in it is not drawn, and — unlike the inbox — a lone
/// section keeps its title (2026-09-30): nothing new is "Recent" alone, titled;
/// nothing but new is "New" alone, counted. Friends is usually the first case,
/// and #316's untitled run made it read as a different screen from Following
/// (`ForYouGridPage.titlesEverySection`).
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
/// (`PushedScreenHeader`; #323's large titles were taken back on 2026-09-30).
/// The section capsules pin right under that bar, because they pin to the
/// collection view's adjusted inset, which is that bar.
///
/// # Holding still under a post
///
/// ⚠️ The list's inset is PINNED from the tap until the list is back on
/// screen (`ForYouGridPage.beginHeroFreeze` / `viewDidAppear`). This list
/// adds the safe area to its inset, and that safe area is not the list's
/// while a post covers it — the view leaves the window, and the pop settles
/// the chrome only after a close has ended. Every change of it drags
/// `contentOffset` with it, so a list left to track it came back from a post
/// shifted, a jump the viewer saw the moment the card landed (filmed on
/// Following, Friends and the mosaic, 2026-09-30 — under #323's large titles,
/// which made it a bar's height, but the covered safe area moves without
/// them too). For You never showed it: its own flight pins the same inset
/// (`ForYouGridZoomSource`).
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
        // Both lists title every section, a lone "Recent" included — see the
        // type's note.
        page.titlesEverySection = true
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

    /// `newPosts` are the rows headed "New" — the SAME set the For You
    /// header's badge counts, handed over rather than re-derived, so the "New"
    /// count and the number on the header the viewer came from are one answer.
    func render(_ state: ForYouViewModel.PageState, newPosts: Set<PostID>) {
        loadViewIfNeeded()
        page.setNewPosts(newPosts)
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

    #if DEBUG
    /// How many rows sit under the "New" header — zero for an untitled list.
    var debugNewSectionCount: Int { page.debugArrivalsRunLength }
    /// The headers on screen, top to bottom — see
    /// `ForYouGridPage.debugSectionHeaders`.
    func debugSectionHeaders() -> [(title: String?, count: Int)] { page.debugSectionHeaders() }
    #endif

    // MARK: - Appearance

    // NO DOCK REVEAL on the way back from a post: there is no bar on this
    // screen to give back (`hidesBottomBarWhenPushed`).

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if DEBUG
        PushedListJumpTrace.begin("\(kind.rawValue) will-appear", page: page, host: view)
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back: the inset tracks the safe area again, offset carried across,
        // so nothing moves — see the type's note.
        page.endHeroFreeze()
        #if DEBUG
        PushedListJumpTrace.mark("\(kind.rawValue) did-appear", page: page, host: view)
        #endif
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
        #if DEBUG
        PushedListJumpTrace.mark("\(kind.rawValue) open", page: page, host: view)
        #endif
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
            textReveal: textRowReveal(for: tapped),
            // Already pinned since the tap; pinned again in case a cancelled
            // window close handed it back meanwhile.
            willStageDismissal: { [weak page] in page?.pinForPushedClose() }
        )
        page.openHoldingStill(from: self) { openPost(self, origin, stream.map(\.id)) }
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
            // ⚠️ NO THAW HERE — `viewDidAppear` hands the inset back. The
            // window's close ends BEFORE the pop has settled the chrome: the
            // safe area read then was mid-flight (t146 / b68 against a resting
            // t168 / b34), the list re-adjusted to it, and UIKit dragged the
            // offset by the 22pt it still had to travel — the list sat 22pt
            // low at `viewDidAppear` and slid back a moment later. Measured
            // with `-list-jump-trace` on a Following text row, 2026-09-30. A
            // cancelled close leaves the list covered, and pinned, as well.
            dismissalDidEnd: { [weak page] committed in
                if !committed { page?.clearRevealConcealment() }
            }
        )
    }

    #if DEBUG
    /// Taps row `index` through the page's own selection path.
    func debugOpenRow(at index: Int) -> Bool {
        page.debugSelectItem(at: index)
    }

    /// Scrolls `offset` points into the content — `-foryou-pushed-scroll`.
    func debugScroll(to offset: CGFloat) {
        page.setVerticalOffset(offset)
    }

    /// Whether row `index` is loaded and has what it would fly.
    func debugRowIsReady(at index: Int) -> Bool {
        guard page.posts.indices.contains(index) else { return false }
        let post = page.posts[index]
        return post.kind == .text || page.heroAppearance(for: post.id)?.cover != nil
    }
    #endif
}
