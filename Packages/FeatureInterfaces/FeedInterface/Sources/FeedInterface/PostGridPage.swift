import CoreModels
import PostGrid
import UIKit

/// The shape a post grid page takes.
public enum PostGridPageStyle: Sendable {
    /// Bricks, edge to edge — a media gallery.
    case grid
    /// The timeline's cards.
    case list
    /// For You's mixed list: cards, paired cards and mosaic chunks.
    case discover
}

/// What a page shows in place of its posts: a host's own words (a private
/// profile, a tab with nothing in it) or a failure.
public struct PostGridPageStatus: Equatable, Sendable {
    public let symbolName: String?
    public let title: String
    public let subtitle: String?
    /// A button under the words; pressing it calls the page's `onRefresh`.
    public let actionTitle: String?

    public init(symbolName: String?, title: String, subtitle: String? = nil, actionTitle: String? = nil) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
    }
}

/// What a page is asked to draw.
public enum PostGridPageState: Equatable, Sendable {
    /// Skeletons on a page with nothing yet; the posts it has otherwise.
    case loading
    case content([GalleryPost])
    case status(PostGridPageStatus)
}

/// Everything a host needs to build one row's "..." menu.
public struct PostGridAuthorMenuContext {
    public let post: GalleryPost
    public let authorID: ProfileID
    /// The control that was pressed, for a popover-shaped follow-up sheet.
    public let anchor: UIView

    public init(post: GalleryPost, authorID: ProfileID, anchor: UIView) {
        self.post = post
        self.authorID = authorID
        self.anchor = anchor
    }
}

/// ⚠️ ONE GRID FOR EVERY MEDIA TILE (epic #1269, #1273): For You's own page,
/// vended to a feature that cannot import Feed — the profile — so its tiles
/// are For You's, with For You's behaviour: autoplay, a take-off playing, the
/// playhead continued on a close, the tile's own clip after paging on, the
/// words faded in on a close, post info by size.
///
/// A page hosted under a floating header (`setHostedInsets`) scrolls under
/// it, reports its offset (`onVerticalScroll`) and leaves pull-to-refresh to
/// the host (`handPullToHost`, `onPullReleased`).
@MainActor
public protocol PostGridPage: UIView {
    // MARK: Content

    func show(_ state: PostGridPageState)
    /// No further page is coming, or one is — read by the next `show`.
    func setCorpusComplete(_ complete: Bool)
    /// Whether tiles large enough wear their words (`PostTileInfo`).
    var showsTileInfo: Bool { get set }
    /// What a card's heart stakes, and how it is drawn once the viewer has.
    var staking: PostCardStaking? { get set }

    // MARK: Events

    /// A post was tapped, with the stream that opens after it; `comments` is
    /// a press on its comment chip.
    var onPostTapped: ((_ post: GalleryPost, _ stream: [GalleryPost], _ comments: Bool) -> Void)? { get set }
    var onNearEnd: (() -> Void)? { get set }
    var onViewAllTapped: (() -> Void)? { get set }
    var onAuthorTapped: ((GalleryPost) -> Void)? { get set }
    /// What a row's "..." offers — nothing hides the control.
    var postMenuActions: ((PostGridAuthorMenuContext) -> [PostCardMenuAction])? { get set }
    /// Pull-to-refresh, and a status's action.
    var onRefresh: (() -> Void)? { get set }
    /// Re-asks every visible row for its "..." menu — a relation changed.
    func refreshAuthorMenus()

    // MARK: Hosted under a floating header

    var onVerticalScroll: ((CGFloat) -> Void)? { get set }
    var onPullReleased: ((CGFloat) -> Void)? { get set }
    var verticalOffset: CGFloat { get }
    var scrollView: UIScrollView { get }
    func setVerticalOffset(_ offset: CGFloat, animated: Bool)
    func setHostedInsets(top: CGFloat, bottom: CGFloat)
    func setMinimumScrollTravel(_ travel: CGFloat)
    /// The chrome actually drawn over the page, for autoplay's visible band.
    func setChromeOcclusion(_ occlusion: UIEdgeInsets?)
    var snapDetents: [CGFloat] { get set }
    var catchDetents: [CGFloat] { get set }
    func handPullToHost()

    // MARK: Playback, opening and closing

    func setAutoplayActive(_ active: Bool)
    /// Brings the post last opened clear of the chrome, once the page is out
    /// of sight.
    func applyPendingReveal()
    /// A tile's opening, described for the shared flight — every hook For
    /// You's tiles fly with. Opens the playback handoff. `pinsBeforeClose`:
    /// the page pins its inset before a close is measured — false for a host
    /// whose insets never move under a covered page (one under a floating
    /// header).
    func heroOrigin(
        opening tapped: GalleryPost, stream: [GalleryPost], in host: UIView,
        textReveal: TextRevealOrigin?, opensComments: Bool,
        willStageDismissal: @escaping () -> Void, pinsBeforeClose: Bool,
        continuation: SnapFeedContinuation?
    ) -> SnapFeedHeroOrigin
    /// The window a post closes through when there is no picture to fly.
    func closeWindow(
        for post: GalleryPost, alignsPageToSource: Bool,
        willStageDismissal: @escaping () -> Void, dismissalDidEnd: @escaping (Bool) -> Void
    ) -> TextRevealOrigin?
    /// Pins the page for the push about to cover it, then opens.
    func openHoldingStill(from host: UIViewController, _ open: () -> Void)
    /// The open was refused: the playback handoff `heroOrigin` began ends.
    func endPlaybackHandoff()
}

#if DEBUG
/// What a host's QA hooks and tests read of a vended page.
@MainActor
public protocol PostGridPageDebugging: PostGridPage {
    var debugShowsSkeleton: Bool { get }
    var debugReloadCount: Int { get }
    var debugRecountedItems: Int { get }
    var debugReconfiguredItems: Int { get }
    /// Taps item `index` through the page's own selection path.
    func debugSelectItem(at index: Int) -> Bool
    /// The tile `applyPendingReveal` last brought clear, in window space.
    func debugRevealedTileInWindow() -> CGRect?
}
#endif
