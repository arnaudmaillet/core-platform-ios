import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// What a post opened from the profile flies out of and lands back on: the
/// questions `ProfileViewController.openGalleryPost` asks while the feed is up.
///
/// Two surfaces answer them: the profile's pager (its active page) and the
/// media gallery Posts' "View all" pushes (#631). One description of a post's
/// place, whichever list it was tapped in.
@MainActor
protocol ProfileHeroSurface: UIView {
    func heroGeometry(for postID: PostID) -> (rect: CGRect, cover: UIImage?, isTile: Bool)?
    /// The space `heroGeometry`'s rect is in.
    var heroSpace: UICoordinateSpace? { get }
    func setHeroConcealed(_ concealed: Bool, for postID: PostID, carrying carry: PostGridListRowCell.HeroCarry)
    func textRowFrame(for postID: PostID, in space: UICoordinateSpace) -> CGRect?
    func rowFrame(for postID: PostID, in space: UICoordinateSpace) -> CGRect?
    func textRowCaptionEnd(for postID: PostID) -> CGFloat?
    func textRowCaptionTop(for postID: PostID) -> CGFloat
    func textRowAuthorBand(for postID: PostID) -> PostAuthorBandView.Model?
    func makeDismissStandIn(for postID: PostID) -> UIView?
}

extension ProfileGalleryPagerView: ProfileHeroSurface {
    var heroSpace: UICoordinateSpace? { heroCoordinateSpace }
}

extension ProfileGalleryGridView: ProfileHeroSurface {
    var heroSpace: UICoordinateSpace? { heroCoordinateSpace }
}

/// The profile's photos and videos as the media mosaic — what "View all"
/// under one of Posts' chunks pushes (#631), the page that used to be the
/// Gallery tab.
///
/// A plain pushed screen: the mosaic under the navigation bar, the profile's
/// handle under its title. It holds no data of its own: the profile renders
/// its media into it as pages land, and opens its posts through the same
/// flight the Posts list uses, measured against this mosaic.
final class ProfileMediaGalleryViewController: UIViewController {
    let grid: ProfileGalleryGridView
    /// A tile was tapped — or a card's comment chip, `showingComments`. The
    /// profile opens it, flying from this screen's mosaic.
    var onOpen: ((GalleryPost, _ stream: [GalleryPost], _ showingComments: Bool) -> Void)?
    /// The mosaic neared its end: the profile's next page.
    var onNearEnd: (() -> Void)?
    /// Popped: the profile's Posts is the list on screen again.
    var onClose: (() -> Void)?

    private let handle: String?

    init(imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController?, handle: String?) {
        self.handle = handle
        grid = ProfileGalleryGridView(
            imagePipeline: imagePipeline, style: .grid, tab: .format(.media), videoPlayback: videoPlayback
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        navigationItem.title = ProfileTab.format(.media).title
        navigationItem.subtitle = handle
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        grid.pin(to: view)
        grid.onItemTapped = { [weak self] post, stream in self?.onOpen?(post, stream, false) }
        grid.onItemCommentsTapped = { [weak self] post, stream in self?.onOpen?(post, stream, true) }
        grid.onNearEnd = { [weak self] in self?.onNearEnd?() }
    }

    func render(_ state: ProfileViewModel.GalleryPageState) {
        grid.render(state)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The mosaic runs under the bars, as every page of this screen does —
        // `contentInsetAdjustmentBehavior = .never` — so the insets are set
        // here: the navigation bar above, the home indicator (or tab bar)
        // below, and the bar as what content passes under.
        let safe = view.safeAreaInsets
        grid.setContentTopInset(safe.top)
        grid.setContentBottomInset(safe.bottom)
        grid.setStickyTopOcclusion(safe.top)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        grid.setAutoplayActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        grid.setAutoplayActive(false)
    }

    /// The post has covered this screen: the tapped tile is brought clear of
    /// the bar without anyone seeing it move — the profile's own rule.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        grid.applyPendingReveal()
        if isMovingFromParent { onClose?() }
    }
}
