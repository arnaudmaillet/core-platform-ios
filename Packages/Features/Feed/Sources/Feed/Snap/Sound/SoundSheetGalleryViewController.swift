import CoreModels
import DesignSystem
import MediaCore
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
/// are the same object.
final class SoundSheetGalleryViewController: UIViewController {
    let kind: SoundSheetSection.Kind
    private(set) var ids: [PostID]
    /// A tile was tapped: the sheet opens its post.
    var onSelect: ((PostID) -> Void)?

    private let tile: (PostID) -> SoundSheetViewController.Tile?
    private let imagePipeline: ImagePipeline
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, PostID>!

    init(
        kind: SoundSheetSection.Kind,
        ids: [PostID],
        tile: @escaping (PostID) -> SoundSheetViewController.Tile?,
        imagePipeline: ImagePipeline
    ) {
        self.kind = kind
        self.ids = ids
        self.tile = tile
        self.imagePipeline = imagePipeline
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
        collectionView.alwaysBounceVertical = true
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
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
        }
        dataSource.apply(snapshot(), animatingDifferences: false)
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
        snapshot.reconfigureItems(changed.filter { newIDs.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    // MARK: - Tiles, for the hero

    func tileCell(for id: PostID) -> SoundSheetTileCell? {
        guard isViewLoaded, let path = dataSource.indexPath(for: id) else { return nil }
        return collectionView.cellForItem(at: path) as? SoundSheetTileCell
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
}
