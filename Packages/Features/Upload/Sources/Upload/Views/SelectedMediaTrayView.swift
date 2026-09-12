import DesignSystem
import UIKit

/// The strip of what has been chosen, in the order it will be posted in: a
/// thumbnail per item, a cross to drop one, and a long press to carry one
/// somewhere else in the row.
///
/// **It floats over the grid rather than pushing it up.** The library keeps
/// running underneath, softened by the strip's own material, so the tiles a
/// viewer is half way through choosing from never jump under their finger. The
/// grid pays for the space by insetting its content, which moves nothing that
/// is already on screen.
///
/// ⚠️ **THE STRIP HAS NO BACKDROP AT ALL, AND THAT IS THE POINT.** It began as
/// a `.systemThinMaterial` band inside this view, which read as a grey plate
/// with a hard edge; a screen-owned blur behind it read as a plate too. What
/// the album actually wants is to be SEEN through this band and to run out of
/// opacity as it passes under — which is the grid's own bottom fade, not
/// anything this view draws. See `MediaPickerViewController.updateGridFade()`.
final class SelectedMediaTrayView: UIView {
    private enum Metrics {
        static let thumbnail: CGFloat = 56
        static let remove: CGFloat = 20
        /// The cell is the thumbnail plus the room the cross needs above and to
        /// the side of it, so the cross never has to hang outside the cell —
        /// a control drawn outside its cell's bounds takes no taps.
        static var cell: CGFloat { thumbnail + remove / 2 }
        static let corner: CGFloat = 10
    }

    /// What a host reserves at the bottom of its content while the tray is up.
    static var height: CGFloat { Metrics.cell + Spacing.sm * 2 }

    /// A chosen item was dropped from the strip.
    var onRemove: ((String) -> Void)?
    /// A drag finished and left the strip in this order.
    var onReorder: (([String]) -> Void)?

    private let grab = UILongPressGestureRecognizer()
    /// Whether the current press actually picked a thumbnail up.
    private var isCarrying = false
    /// The row's own height, held for the life of a carry — see `handleGrab`.
    private var carryY: CGFloat = 0
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    /// ⚠️ `@MainActor`, STATED RATHER THAN INFERRED. A stored closure is
    /// non-isolated whatever it was written next to, and the one this takes
    /// reaches a library the main actor owns — so without the annotation the
    /// caller's `library` is a non-`Sendable` value leaving its actor, which
    /// Swift 6 refuses outright.
    private let thumbnailProvider: @MainActor (String, CGSize) async -> UIImage?

    init(thumbnailProvider: @escaping @MainActor (String, CGSize) async -> UIImage?) {
        self.thumbnailProvider = thumbnailProvider
        super.init(frame: .zero)
        configureList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureList() {
        var configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(Metrics.cell), heightDimension: .absolute(Metrics.cell)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Spacing.sm
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        )
        let layout = UICollectionViewCompositionalLayout(section: section, configuration: configuration)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        // ⚠️ **THE STRIP IS ONE ROW AND NOTHING MAY LEAVE IT.** A carried
        // thumbnail was seen climbing out of the band and standing above its
        // neighbours: locking the target position keeps the ITEM in its lane,
        // but it does not stop the strip itself from scrolling a few points
        // vertically, nor stop a lifted snapshot from being drawn outside these
        // bounds. Clipping and `scrollViewDidScroll` close both.
        collectionView.clipsToBounds = true
        collectionView.alwaysBounceVertical = false
        collectionView.isDirectionalLockEnabled = true
        collectionView.delegate = self
        collectionView.pin(to: self)

        let provider = thumbnailProvider
        let cell = UICollectionView.CellRegistration<TrayCell, String> { cell, _, id in
            cell.configure(id: id) { [weak self] in self?.onRemove?(id) }
            Task { [weak cell] in
                let size = CGSize(width: Metrics.thumbnail, height: Metrics.thumbnail)
                let image = await provider(id, size)
                cell?.showThumbnail(image, for: id)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        // ⚠️ **THE GRAB IS OURS, AND IT HAS TO BE — THERE IS NO STANDARD ONE
        // HERE.** A diffable data source with `canReorderItem` set reads like
        // all a reorder needs, and it shipped that way: a long press on a
        // thumbnail did nothing whatsoever. The gesture that would have driven
        // it is installed by `UICollectionViewController` —
        // `installsStandardGestureForInteractiveMovement` is THAT class's
        // property, and does not exist on `UICollectionView` at all — so a
        // plain collection view living inside a view, as this tray does, never
        // had one. Stating the recogniser is also how the rest of this app
        // drives a drag (`PagedTabBar`'s pill grab).
        grab.addTarget(self, action: #selector(handleGrab))
        collectionView.addGestureRecognizer(grab)

        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            MainActor.assumeIsolated {
                self?.onReorder?(transaction.finalSnapshot.itemIdentifiers)
            }
        }
    }

    /// Carries a thumbnail under the finger and lets the collection view close
    /// the gap behind it. The data source's `didReorder` reports where it
    /// landed, so the model is told once, at the end, rather than per frame.
    /// ⚠️ **EVERY STATE AFTER `.began` IS GUARDED ON A MOVE ACTUALLY HAVING
    /// BEGUN.** A press that lands between two thumbnails — or on none at all —
    /// finds no index path, so nothing is carried; but the recogniser goes on
    /// reporting `.changed` and `.ended`, and asking UIKit to update or end a
    /// movement that never started is not a no-op.
    /// `beginInteractiveMovementForItem` returns whether it took, so that
    /// answer is what the rest of the gesture reads.
    ///
    /// (This is a hazard in its own right, not the cause of the crash the first
    /// drag produced — that one was the picker answering `didReorder` with a
    /// second snapshot apply, and it is recorded where it happens.)
    @objc private func handleGrab(_ grab: UILongPressGestureRecognizer) {
        let point = grab.location(in: collectionView)
        switch grab.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
            // ⚠️ **THE BORDER AND THE LIFT BOTH LAND BEFORE THE MOVE BEGINS.**
            // `beginInteractiveMovementForItem` takes a SNAPSHOT of the cell
            // and carries that under the finger; the real cell is hidden for
            // the duration. Anything applied afterwards — a border, a scale, an
            // animation — decorates a view nobody can see, and the thumbnail
            // travels bare. The move starts in the lift's completion, so the
            // viewer sees the spring AND the snapshot is taken of a thumbnail
            // already lifted, which then stays lifted for the whole carry.
            //
            // `carryY` is set there too, from the CELL's centre rather than the
            // finger's: `updateInteractiveMovementTargetPosition` places the
            // centre of the snapshot at the point it is given, so a press near
            // a thumbnail's top edge would otherwise carry it above its
            // neighbours — which is exactly what was filmed.
            let cell = collectionView.cellForItem(at: indexPath) as? TrayCell
            cell?.setCarried(true)
            cell?.liftForCarry { [weak self] in
                self?.beginCarry(of: indexPath, grab: grab)
            }
        case .changed:
            guard isCarrying else { return }
            // ⚠️ **SIDEWAYS ONLY.** The strip exists to re-order, and it is one
            // row tall: a thumbnail allowed to follow the finger upwards leaves
            // the row it belongs to and reads as a drag to nowhere. The height
            // is the one the press began at, so the carry stays in its lane.
            collectionView.updateInteractiveMovementTargetPosition(
                CGPoint(x: point.x, y: carryY)
            )
        case .ended:
            // ⚠️ CLEARED WHETHER OR NOT A MOVE BEGAN. A press released during
            // the lift never starts one, and a thumbnail left standing proud
            // with a ring around it would be the only sign of it.
            if isCarrying {
                isCarrying = false
                collectionView.endInteractiveMovement()
            }
            clearCarried()
        default:
            if isCarrying {
                isCarrying = false
                collectionView.cancelInteractiveMovement()
            }
            clearCarried()
        }
    }

    /// Starts the move once the lift has settled — see `TrayCell.liftForCarry`.
    ///
    /// ⚠️ THE GESTURE IS RE-CHECKED, because 180ms is long enough for a finger
    /// to have come up: beginning a movement for a press that is already over
    /// leaves the collection view carrying something nobody is holding.
    private func beginCarry(of indexPath: IndexPath, grab: UILongPressGestureRecognizer) {
        guard grab.state == .began || grab.state == .changed else { return }
        let took = collectionView.beginInteractiveMovementForItem(at: indexPath)
        #if DEBUG
        // Behind `-upload-log-sheet`, like the sheet's own diagnostics: a press
        // that produces nothing is indistinguishable from one that was never
        // delivered, and guessing between the two is what cost five builds on
        // the resting detent.
        if ProcessInfo.processInfo.arguments.contains("-upload-log-sheet") {
            NSLog("[tray] began item=%d took=%@", indexPath.item, took ? "yes" : "no")
        }
        #endif
        guard took else { return }
        isCarrying = true
        carryY = collectionView.cellForItem(at: indexPath)?.center.y ?? carryY
    }

    /// ⚠️ EVERY VISIBLE CELL, NOT THE ONE THAT WAS PICKED UP. The carried
    /// thumbnail has moved to another index path by the time it is put down,
    /// and the cell that now sits where it started is a different one.
    private func clearCarried() {
        for case let cell as TrayCell in collectionView.visibleCells {
            cell.setCarried(false)
        }
    }

    func setItems(_ ids: [String], animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    /// Brings the newest thumbnail into view, so a choice made from the far end
    /// of a long strip is visibly acknowledged.
    func scrollToEnd() {
        let count = dataSource.snapshot().numberOfItems
        guard count > 0 else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: count - 1, section: 0), at: .right, animated: true
        )
    }
}

extension SelectedMediaTrayView: UICollectionViewDelegate {
    /// ⚠️ THE STRIP NEVER MOVES VERTICALLY, and this is the belt to
    /// `alwaysBounceVertical`'s brace. During an interactive move UIKit will
    /// auto-scroll the collection it is reordering; in a band exactly one
    /// thumbnail tall, a few points of that is enough to knock the carried
    /// thumbnail out of line with the ones it is being dropped between.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let top = -scrollView.adjustedContentInset.top
        guard abs(scrollView.contentOffset.y - top) > 0.5 else { return }
        scrollView.contentOffset.y = top
    }
}

/// One thumbnail in the strip, with the cross that drops it.
private final class TrayCell: UICollectionViewCell {
    private let thumbnail = UIImageView()
    private let remove = UIButton(type: .system)
    private var representedID: String?
    private var removeHandler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.backgroundColor = .secondarySystemBackground
        thumbnail.layer.cornerRadius = 10
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.constrain(in: contentView) { parent in
            thumbnail.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            thumbnail.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            thumbnail.widthAnchor.constraint(equalToConstant: 56)
            thumbnail.heightAnchor.constraint(equalToConstant: 56)
        }

        // White glyph on a dark disc, stated rather than semantic: this sits on
        // top of a photograph, which has no appearance for a colour to adapt to.
        remove.setImage(
            UIImage(
                systemName: "xmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    paletteColors: [.white, UIColor.black.withAlphaComponent(0.55)]
                )
            ),
            for: .normal
        )
        remove.accessibilityLabel = "Remove"
        remove.addAction(UIAction { [weak self] _ in self?.removeHandler?() }, for: .primaryActionTriggered)
        remove.constrain(in: contentView) { parent in
            remove.topAnchor.constraint(equalTo: parent.topAnchor)
            remove.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            remove.widthAnchor.constraint(equalToConstant: 20)
            remove.heightAnchor.constraint(equalToConstant: 20)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        thumbnail.image = nil
        thumbnail.layer.borderWidth = 0
        thumbnail.transform = .identity
        removeHandler = nil
    }

    func configure(id: String, onRemove: @escaping () -> Void) {
        representedID = id
        removeHandler = onRemove
    }

    func showThumbnail(_ image: UIImage?, for id: String) {
        guard representedID == id else { return }
        thumbnail.image = image
    }

    /// The ring a thumbnail wears while a finger is carrying it.
    ///
    /// The tint, the same ring a chosen tile wears in the grid: a thumbnail in
    /// this strip IS a chosen tile, and two different colours for one state
    /// would read as two states.
    func setCarried(_ isCarried: Bool) {
        thumbnail.layer.borderWidth = isCarried ? Self.carriedBorder : 0
        thumbnail.layer.borderColor = tintColor.cgColor
        guard !isCarried else { return }
        // Put down: back to its own size, springing rather than snapping.
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0.3,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.thumbnail.transform = .identity
        }
    }

    /// Picks the thumbnail up — a small spring out — and calls back once it has
    /// settled at its carried size.
    ///
    /// ⚠️ **THE CALLER STARTS THE MOVE IN THAT CALLBACK, NOT BEFORE IT.**
    /// `beginInteractiveMovementForItem` SNAPSHOTS the cell and carries the
    /// copy while the real one is hidden, so an animation started after it runs
    /// on a view nobody can see. Lifting first means the viewer sees the spring
    /// AND the snapshot is taken of an already-lifted thumbnail, which then
    /// stays lifted for the whole carry.
    func liftForCarry(then settled: @escaping () -> Void) {
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            usingSpringWithDamping: 0.55,
            initialSpringVelocity: 0.7,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.thumbnail.transform = CGAffineTransform(
                scaleX: Self.carriedScale, y: Self.carriedScale
            )
        } completion: { _ in
            settled()
        }
    }

    private static let carriedBorder: CGFloat = 3
    /// ⚠️ 1.12 AND NO MORE. The thumbnail is 56pt inside a 64pt cell, and a
    /// transform grows it about its centre — past this it reaches the cell's
    /// edges and the strip clips what it is trying to show off.
    private static let carriedScale: CGFloat = 1.12
}
