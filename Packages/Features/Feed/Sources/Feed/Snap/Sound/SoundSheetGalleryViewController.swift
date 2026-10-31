import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// What "Popular"'s title and chevron push INSIDE the sound sheet: its whole
/// ranking as the sheet's three-column grid, under a navigation bar with
/// UIKit's back button and the section's title — at whatever detent the sheet
/// stands: the push never moves it.
///
/// **UIKIT'S SOFT TOP EDGE UNDER THE TITLE**, the notifications drawer's
/// (`NotificationsViewController`), stated rather than left `.automatic`:
/// left automatic, the blur under the title read too heavy (asked for
/// lighter, 2026-09-29). The sheet's own screen hides its edge instead — its
/// sound sits UNDER the bar at rest.
///
/// The sheet's toolbar stays — [Use this sound][🔖][↑] is about the sound,
/// and the sound is still what this screen is about; the items are fresh ones
/// made by the sheet (`toolbarItems`), since a bar item cannot live in two
/// screens' bars at once.
///
/// It draws nothing of its own: tiles, order and what a tap does are the
/// sheet's (`SoundSheetViewController`), so a tile here and one on the sheet
/// are the same object. Its video tiles play as the sheet's do
/// (`SoundSheetAutoplay`, #884), on a coordinator of its own.
final class SoundSheetGalleryViewController: UIViewController {
    let kind: SoundSheetSection.Kind
    private(set) var ids: [PostID]
    /// A tile was tapped: the sheet opens its post.
    var onSelect: ((PostID) -> Void)?

    private let tile: (PostID) -> SoundSheetViewController.Tile?
    private let imagePipeline: ImagePipeline
    /// The video tiles playing on their own; nil without a pool.
    private(set) var autoplay: SoundSheetAutoplay?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, PostID>!

    /// The grid's lookahead (#970): the tiles' covers a screen ahead decoded,
    /// two and a half ahead on disk, under this screen's own owner.
    private lazy var lookahead: ScrollLookahead = {
        let lookahead = ScrollLookahead(
            pipeline: imagePipeline, name: "sound-sheet.gallery", kind: .grid
        ) { [weak self] path in
            guard let self, let id = dataSource?.itemIdentifier(for: path),
                  let url = tile(id)?.thumbnailURL else { return [] }
            // At the bucket the tile decodes it at (#1505).
            return [PostGridTileCell.coverRequest(url, at: path, in: collectionView)]
        }
        lookahead.attach(to: collectionView)
        return lookahead
    }()

    init(
        kind: SoundSheetSection.Kind,
        ids: [PostID],
        tile: @escaping (PostID) -> SoundSheetViewController.Tile?,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil
    ) {
        self.kind = kind
        self.ids = ids
        self.tile = tile
        self.imagePipeline = imagePipeline
        autoplay = videoPlayback.map { SoundSheetAutoplay(pool: $0, imagePipeline: imagePipeline) }
        super.init(nibName: nil, bundle: nil)
        title = kind.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear, like the sheet's own screen: the sheet is the surface.
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        // The sheet's rule (`SoundSheetViewController`, "the posts scroll
        // only at the fullest detent"): no bounce of its own — a content that
        // fits leaves the drag to the sheet, and UIKit's scroll-to-expand does
        // the rest below the fullest detent.
        collectionView.alwaysBounceVertical = false
        collectionView.delegate = self
        collectionView.contentInset.top = SoundSheetViewController.gutter
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        collectionView.topEdgeEffect.style = .soft
        // Named for both edges: the bar's soft blur and the toolbar's read
        // THIS scroll view.
        setContentScrollView(collectionView, for: [.top, .bottom])
        let pipeline = imagePipeline
        let registration = UICollectionView.CellRegistration<SoundSheetTileCell, PostID> { [weak self] cell, _, id in
            guard let tile = self?.tile(id) else { return }
            cell.configure(tile, pipeline: pipeline)
            cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
        }
        // A loaded media post is the standard tile, as in the sheet (#1280).
        let mediaRegistration = UICollectionView.CellRegistration<PostGridTileCell, PostID> { [weak self] cell, _, id in
            guard let tile = self?.tile(id), let post = tile.post else { return }
            SoundSheetViewController.configureStandardTile(cell, tile: tile, post: post, pipeline: pipeline)
            cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, path, id in
            if self?.tile(id)?.drawsStandardTile == true {
                view.dequeueConfiguredReusableCell(using: mediaRegistration, for: path, item: id)
            } else {
                view.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
            }
        }
        dataSource.apply(snapshot(), animatingDifferences: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lookahead.setOnScreen(true)
        // Pushed into the sheet (#1914): the tiles start once this screen
        // holds half of the sheet.
        _ = viewportShare.screenWillAppear(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewportShare.report(1)
        setAutoplayActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The sheet going: this screen holds all of it to the end. Popped:
        // until it holds less than half of the sheet (#1914). The tiles give
        // their players back once the screen is gone (`viewDidDisappear`).
        if navigationController?.isBeingDismissed == true { return }
        if viewportShare.screenWillDisappear(self) == .flight {
            setAutoplayActive(false)
        }
    }

    /// The share of this screen in its SHEET (#1914): measured against the
    /// sheet, not the display — at a medium detent the sheet is all the
    /// viewer reads.
    private lazy var viewportShare: ViewportShare = {
        let share = ViewportShare(host: view)
        share.reference = { [weak self] in self?.navigationController?.view }
        share.onPlaysChange = { [weak self] plays in self?.setAutoplayActive(plays) }
        return share
    }()

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        setAutoplayActive(false)
        // The stay is over: what only this grid wanted is cancelled.
        lookahead.setOnScreen(false)
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            SoundSheetViewController.gridSection(environment, bottom: Spacing.xl)
        }
    }

    private func snapshot() -> NSDiffableDataSourceSnapshot<Int, PostID> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, PostID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        return snapshot
    }

    /// The section's posts as the sheet now knows them: a placeholder filled
    /// in is the same tile reconfigured, a post that could not be loaded goes.
    func update(ids newIDs: [PostID], reconfiguring changed: [PostID]) {
        ids = newIDs
        guard dataSource != nil else { return }
        var snapshot = snapshot()
        // Reloaded rather than reconfigured: a placeholder that arrives as a
        // media post changes cell (#1280).
        snapshot.reloadItems(changed.filter { newIDs.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        reconcileAutoplay()
        lookahead.setNeedsPlan()
    }

    // MARK: - Autoplay

    /// The tiles are (or are no longer) the viewer's — on screen, not covered
    /// by a feed opened from one (the sheet says, `SoundSheetViewController
    /// .openFeed`). Inactive, every one gives its player back at once.
    func setAutoplayActive(_ active: Bool) {
        // Covered by a feed opened from a tile: minimum windows (#970).
        lookahead.setHidden(!active)
        guard let autoplay else { return }
        autoplay.setActive(active)
        guard active, isViewLoaded else { return }
        collectionView.layoutIfNeeded()
        reconcileAutoplay()
    }

    /// Every visible tile may play: nothing here is faint.
    func reconcileAutoplay(allowingStarts: Bool = true) {
        guard let autoplay, dataSource != nil else { return }
        let items = collectionView.indexPathsForVisibleItems.compactMap { path -> SoundSheetAutoplay.Item? in
            guard let id = dataSource.itemIdentifier(for: path), let tile = tile(id),
                  let cell = collectionView.cellForItem(at: path) as? any SoundSheetTileDrawing
            else { return nil }
            return .init(tile: tile, cell: cell)
        }
        autoplay.reconcile(items, in: collectionView, allowingStarts: allowingStarts)
    }

    // MARK: - Tiles, for the hero

    func tileCell(for id: PostID) -> (any SoundSheetTileDrawing)? {
        guard isViewLoaded, let path = dataSource.indexPath(for: id) else { return nil }
        return collectionView.cellForItem(at: path) as? any SoundSheetTileDrawing
    }

    /// The tile's rect in `space` while it is on screen — nil once scrolled
    /// out, under the bars included.
    func tileFrame(for id: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = tileCell(for: id) else { return nil }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard visible.intersects(cell.frame) else { return nil }
        return cell.convert(cell.bounds, to: space)
    }

    /// The grid — what a test reads.
    var grid: UICollectionView { collectionView }
}

extension SoundSheetGalleryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelect?(id)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reconcileAutoplay(allowingStarts: GridAutoplayRanking.allowsStarts(
            atVelocity: scrollView.panGestureRecognizer.velocity(in: scrollView).y
        ))
        lookahead.scrollViewDidScroll()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reconcileAutoplay()
        lookahead.scrollViewDidEndScrolling()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // A tile that left gives its player back now — the pool is shared.
        autoplay?.stop(cell)
    }
}

// MARK: - How it is left (#1144)

extension SoundSheetGalleryViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
