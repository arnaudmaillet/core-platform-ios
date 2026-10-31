import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The profile's photos and videos as the media mosaic — what "View all"
/// under one of Posts' chunks pushes (#631), the page that used to be the
/// Gallery tab.
///
/// A plain pushed screen: the mosaic under the navigation bar, the profile's
/// handle under its title. It holds no data of its own: the profile renders
/// its media into it as pages land, and opens its posts through the same
/// flight the Posts list uses, measured against this mosaic.
final class ProfileMediaGalleryViewController: UIViewController {
    let grid: any PostGridPage
    /// A tile was tapped — or a card's comment chip, `showingComments`. The
    /// profile opens it, flying from this screen's mosaic.
    var onOpen: ((GalleryPost, _ stream: [GalleryPost], _ showingComments: Bool) -> Void)?
    /// The mosaic neared its end: the profile's next page.
    var onNearEnd: (() -> Void)?
    /// Popped: the profile's Posts is the list on screen again.
    var onClose: (() -> Void)?

    private let handle: String?
    private let galleryTitle: String

    /// - Parameter makePage: For You's own grid page (#1273) — the mosaic's
    ///   tiles are For You's tiles.
    init(
        handle: String?, title: String = ProfileTab.format(.media).title,
        makePage: (PostGridPageStyle) -> any PostGridPage
    ) {
        self.handle = handle
        self.galleryTitle = title
        grid = makePage(.grid)
        // Post info by size (`PostTileInfo`'s three levels), as every tile.
        grid.showsTileInfo = true
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        navigationItem.title = galleryTitle
        navigationItem.subtitle = handle
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        grid.pin(to: view)
        grid.onPostTapped = { [weak self] post, stream, comments in self?.onOpen?(post, stream, comments) }
        grid.onNearEnd = { [weak self] in self?.onNearEnd?() }
    }

    func render(_ state: ProfileViewModel.GalleryPageState) {
        grid.show(ProfileGalleryPagerView.pageState(state, for: .format(.media)))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The mosaic runs under the bars, as every page of this screen does —
        // `contentInsetAdjustmentBehavior = .never` — so the insets are set
        // here: the navigation bar above, the home indicator (or tab bar)
        // below, and the bar as what content passes under.
        let safe = view.safeAreaInsets
        grid.setHostedInsets(top: safe.top, bottom: safe.bottom)
        grid.setChromeOcclusion(UIEdgeInsets(top: safe.top, left: 0, bottom: safe.bottom, right: 0))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Pushed in, or a plain screen popping off it (#1914): the clips start
        // once half of the screen is on display.
        _ = viewportShare.screenWillAppear(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewportShare.report(1)
        grid.setPageActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A post opened from a tile: at once. Popped, or under a plain screen:
        // once half of it is gone (#1914).
        if viewportShare.screenWillDisappear(self) == .flight {
            grid.setPageActive(false)
        }
    }

    /// The share of this screen on screen (#1914): its clips play at half and
    /// above — from half way through the push that brings it in, until half
    /// way through the pop that takes it off or a plain screen pushed over it.
    private lazy var viewportShare: ViewportShare = {
        let share = ViewportShare(host: view)
        share.onPlaysChange = { [weak self] plays in self?.grid.setPageActive(plays) }
        return share
    }()

    /// The post has covered this screen: the tapped tile is brought clear of
    /// the bar without anyone seeing it move — the profile's own rule.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        grid.applyPendingReveal()
        if isMovingFromParent { onClose?() }
    }
}

// MARK: - How it is left (#1144)

extension ProfileMediaGalleryViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
