import DesignSystem
import UIKit

/// The first step of posting media: the viewer's own library, and what they
/// have picked out of it — in a sheet that starts as a single row.
///
/// ```
///  resting                          expanded
/// ┌──────────────────────┐         ┌──────────────────────┐
/// │ Cancel   Drafts Next │         │ Cancel   Drafts Next │
/// ├──────────────────────┤         ├──────────────────────┤
/// │ ▦ ▦ ▦ →  one row,    │         │ ▦ ▦ ▦                │
/// │          scrolled    │         │ ▦ ▦ ▦   the album,   │
/// │          sideways    │         │ ▦ ▦ ▦   three to a   │
/// │ ░ 1 2 3 ░░░░░░░░░░░░ │         │ ░ 1 2 3 ░░░░░░░░░░░░ │
/// ├──────────────────────┤         ├──────────────────────┤
/// │ Recents 99+  Videos 8│         │ Recents 99+  Videos 8│
/// └──────────────────────┘         └──────────────────────┘
/// ```
///
/// **The axis follows the detent.** At rest the sheet is exactly one row tall,
/// so the grid becomes a single horizontal strip — three columns of a vertical
/// grid in that space would show a third of a row and scroll into nothing.
/// Expanded, it is the album as a grid again. `sheetPresentationControllerDidChangeSelectedDetentIdentifier`
/// is what swaps them.
///
/// **The count rides in the pill's BADGE.** Every other selector in the app
/// states a number in that red bubble, and a library is not the place to invent
/// a second spelling — the first cut wrote "Recents (112)" into the title, which
/// read as a different control wearing the same shape.
///
/// What the badge costs is the exact figure: `BadgeView` stops at "99+", so an
/// album of 112 and an album of 12,400 say the same thing. That ceiling is the
/// shared component's and it stays there, because the two hosts it was written
/// for count unread things, where a precise total is noise. The album pills are
/// the first host where the number itself was worth reading — and consistency
/// with every other selector is the trade that was chosen.
///
/// ⚠️ **A BADGE DOES NOT SURVIVE `setTitles`.** Segments are rebuilt by a
/// retitle and a badge belongs to its segment. `PagedTabBar` documents this and
/// notes that no host had ever needed both; this screen is the first with a
/// changing title list AND counts, so `showAlbums` re-applies them every time.
final class MediaPickerViewController: UIViewController {
    private enum Metrics {
        /// ⚠️ ONE NUMBER FOR BOTH GAPS. The space around the grid and the space
        /// between two tiles are the same measurement, so a tile is never
        /// closer to its neighbour than it is to the edge — which is what makes
        /// a grid read as a grid rather than as a block that has been nudged.
        static let gutter = Spacing.sm
        static let corner: CGFloat = 10
        static let columns: CGFloat = 3
        /// What a bar is worth before one exists to measure.
        static let barFallback: CGFloat = 44
        static let toolbarFallback: CGFloat = 49
        /// The narrowest phone this app is built for, as a last resort.
        static let widthFallback: CGFloat = 375
        /// Taller than this is not a bar — see `sane(_:fallback:)`.
        static let barCeiling: CGFloat = 120
        /// How near its resting height the sheet must be before the album is
        /// allowed to turn sideways.
        static let settleTolerance: CGFloat = 2
        /// Air between the album's last row and the strip of chosen thumbnails.
        /// Without it the two read as one block with a seam down the middle.
        static let trayGap = Spacing.lg
    }

    /// The sheet's resting size: the bars, one row of the album, and the tray if
    /// anything has been chosen.
    static let restingDetentIdentifier = UISheetPresentationController.Detent.Identifier("mediaPickerResting")

    private let library: any MediaLibraryReading
    /// What "Next" hands the selection to. The step after this one does not
    /// exist yet, so the builder passes a screen that says so.
    private let onNext: ([MediaLibraryItem]) -> UIViewController

    private var albums: [MediaLibraryAlbum] = []
    private var items: [MediaLibraryItem] = []
    private var itemsByID: [String: MediaLibraryItem] = [:]
    private var selection = MediaPickerSelection()

    private var grid: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var gridAxis: UICollectionView.ScrollDirection = .vertical
    /// Softens the album's visible bottom edge — see `updateGridFade()`.
    private let gridFade = CAGradientLayer()
    /// Shown from the moment the screen opens until the library has answered —
    /// including while the system is asking the viewer for permission.
    private let spinner = UIActivityIndicatorView(style: .large)

    /// Taken in `viewDidLayoutSubviews` and kept, because the detent resolver
    /// may not go looking for them itself — see `restingHeight()`.
    private var measuredWidth = Metrics.widthFallback
    private var measuredBarHeight = Metrics.barFallback
    private var measuredToolbarHeight = Metrics.toolbarFallback
    /// The height the sheet was last asked to resolve, so a layout pass that
    /// changes nothing does not ask again.
    private var lastResolvedRestingHeight: CGFloat = 0
    /// The height at the previous layout pass — how a sheet in flight is told
    /// apart from one that has come to rest.
    private var lastLaidOutHeight: CGFloat = 0
    /// Built once the albums are known: a strip with no segments has nothing to
    /// lay out, and the toolbar stays down until there is something to show.
    private var albumBar: PagedTabBar?
    private let emptyState = EmptyStateView()

    private lazy var tray = SelectedMediaTrayView { [weak self] id, size in
        guard let self else { return nil }
        return await library.thumbnail(for: id, size: size)
    }

    /// The tray rides on this: `0` has it sitting on the toolbar, its own height
    /// has it parked below the screen.
    private var trayBottom: NSLayoutConstraint!

    private lazy var nextItem = UIBarButtonItem(
        title: "Next",
        primaryAction: UIAction { [weak self] _ in self?.goNext() }
    )

    init(
        library: any MediaLibraryReading,
        onNext: @escaping ([MediaLibraryItem]) -> UIViewController
    ) {
        self.library = library
        self.onNext = onNext
        super.init(nibName: nil, bundle: nil)
        // ⚠️ THE BARS BELONG TO THE SCREEN, NOT TO ITS VIEW. Built in
        // `viewDidLoad` they exist only once something has asked for the view,
        // and a navigation controller reads `navigationItem` on the way in —
        // so a screen that has been made but not yet shown would hand back a
        // bar with nothing in it.
        configureBars()
        updateNextItem()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureGrid()
        configureTray()
        emptyState.isHidden = true
        emptyState.pin(to: view)

        // ⚠️ **THE WAIT IS NOT ALWAYS SHORT, AND IT IS NOT ALWAYS OURS.**
        // Reading the library takes a moment on a full device, and when the
        // system's own permission sheet is up this screen sits behind it —
        // blank, with nothing to say it is about to do anything. Centred in the
        // SAFE area, not the view: the album is full-bleed behind its bars, so
        // the view's middle is not the middle of what the viewer can see.
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.centerYAnchor)
        }

        Task { await load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The album strip lives in the navigation controller's toolbar, and a
        // toolbar's VISIBILITY belongs to the stack rather than to the screen's
        // `toolbarItems` — so the screen raises it itself, exactly as the
        // relationship lists do. It stays down until there is a strip to carry.
        navigationController?.setToolbarHidden(albumBar == nil, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard let sheet = navigationController?.sheetPresentationController else { return }
        sheet.delegate = self
        applyGridAxis(settledAxis())
        #if DEBUG
        logSheet("appearing")
        #endif
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateGridInsets()
    }

    /// Where the resting height's ingredients are taken.
    ///
    /// ⚠️ GUARDED ON A CHANGE, because re-resolving the detents lays the sheet
    /// out again — an ungated `invalidateDetents()` in here is a loop.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0 else { return }
        measuredWidth = view.bounds.width
        // ⚠️ THE GRID'S OWN INSET, NOT THE NAVIGATION BAR'S FRAME. What the
        // album loses at the top is `adjustedContentInset.top`, and inside a
        // sheet that is not the bar's height — the bar sits below a grabber,
        // and the difference is exactly the strip of tile that was being cut
        // off the bottom of the row.
        measuredBarHeight = Self.sane(grid.adjustedContentInset.top, fallback: Metrics.barFallback)
        measuredToolbarHeight = Self.sane(toolbarBand, fallback: Metrics.toolbarFallback)
        applyGridAxis(settledAxis())
        updateGridFade()

        // ⚠️ **GUARDED ON THE ANSWER, NOT ON THE INGREDIENTS.** Re-resolving the
        // detents lays the sheet out again, so an ungated call here is a loop —
        // but gating on the measurements themselves LATCHES whatever they
        // happened to read during the presentation, and one odd frame then
        // fixes the sheet at the wrong height for the rest of its life. That is
        // what left it resting 170pt too tall with a band of empty white under
        // the row. Comparing the computed height converges instead.
        // ⚠️ **NOT WHILE THE SHEET IS TRAVELLING, AND THAT IS THE STUTTER.**
        // `refreshRestingHeight()` wraps `invalidateDetents()` in
        // `animateChanges`, and this method runs on EVERY FRAME of a drag — so
        // re-resolving here starts an animation inside an interactive gesture,
        // frame after frame. The log showed the cost plainly: the resting
        // height walked 235 → 258 → 261 while the sheet was still in flight.
        // The measurements above stay current regardless; only the re-resolve
        // waits for the height to stop moving.
        let isStill = abs(view.bounds.height - lastLaidOutHeight) < 0.5
        lastLaidOutHeight = view.bounds.height
        let height = restingHeight()
        guard isStill, abs(height - lastResolvedRestingHeight) > 0.5 else { return }
        refreshRestingHeight()
        #if DEBUG
        logSheet("layout")
        #endif
    }

    // MARK: - The sheet

    /// The resting detent: the bars, one row, and the tray once there is one.
    ///
    /// ⚠️ IT IS RE-RESOLVED, NOT RECOMPUTED BY HAND. Choosing the first photo
    /// raises the tray, which makes the resting size taller — so the selection
    /// asks the sheet to resolve its detents again rather than trying to move
    /// the sheet itself.
    func makeRestingDetent() -> UISheetPresentationController.Detent {
        .custom(identifier: Self.restingDetentIdentifier) { [weak self] context in
            // `self.` stated: the unwrap happens in the outer closure and the
            // call in the nested `assumeIsolated` one, and implicit self does
            // not carry across that boundary.
            MainActor.assumeIsolated {
                guard let self else { return nil }
                return min(self.restingHeight(), context.maximumDetentValue)
            }
        }
    }

    /// ⚠️ **THE RESOLVER READS NOTHING THAT COULD LOAD A VIEW.** A sheet
    /// resolves its detents WHILE it is presenting the screen, so reaching for
    /// `view.bounds` in here loads the view from inside that resolution. The
    /// first cut did exactly that, and the detent was ignored outright: the
    /// sheet reported `mediaPickerResting` as its selected identifier — the
    /// album even switched to its resting axis — while opening at `.large`
    /// every single time. Everything this needs is measured in
    /// `viewDidLayoutSubviews` and kept in a stored property.
    private func restingHeight() -> CGFloat {
        let row = Self.tileSide(forWidth: measuredWidth) + Metrics.gutter * 2
        let tray = selection.isEmpty ? 0 : SelectedMediaTrayView.height + Metrics.trayGap
        return (measuredBarHeight + row + tray + measuredToolbarHeight).rounded(.up)
    }

    /// The band the toolbar actually occupies at the foot of this view.
    ///
    /// ⚠️ **THE SAFE AREA IS THE HONEST SOURCE, AND TWO OTHERS ARE NOT.**
    /// `toolbar.frame.height` lies while the sheet is presenting — 223pt on an
    /// iPhone SE, the height of the whole container — which walked the resting
    /// height up to 489 and left a band of empty white above the tray. Falling
    /// back to the 49pt constant then undershot the real band by some 45pt, so
    /// the sheet rested too short and the tray climbed over the row it is meant
    /// to sit below. This is the same measurement the tray's own bottom
    /// constraint is pinned to, so the two cannot disagree. The window's own
    /// inset — the home indicator — is taken back out, because a detent's value
    /// already excludes it.
    private var toolbarBand: CGFloat {
        let homeIndicator = view.window?.safeAreaInsets.bottom ?? 0
        return max(0, view.safeAreaInsets.bottom - homeIndicator)
    }

    /// ⚠️ **A BAR'S FRAME LIES WHILE THE SHEET THAT HOLDS IT IS PRESENTING.**
    /// Measured on an iPhone SE: the navigation controller's toolbar reported
    /// **223pt** — the height of the whole container rather than its own band —
    /// and a resting height built on that walked up 223 → 407 → 489 and left
    /// the sheet 170pt too tall, with a band of empty white above the tray.
    /// Anything taller than the ceiling is not a bar, and the fallback is a
    /// better answer than a measurement that cannot be true.
    private static func sane(_ reported: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let reported, reported > 0, reported <= Metrics.barCeiling else { return fallback }
        return reported
    }

    private func refreshRestingHeight() {
        guard let sheet = navigationController?.sheetPresentationController else { return }
        lastResolvedRestingHeight = restingHeight()
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    /// ⚠️ **THE AXIS FOLLOWS THE HEIGHT THE SHEET HAS REACHED, NOT THE DETENT
    /// IT HAS ANNOUNCED.** A sheet reports its new detent as the drag ENDS,
    /// while the animation towards that height is still running — so turning
    /// the album sideways there rebuilds the layout in mid-flight, and the grid
    /// is seen reflowing as the sheet travels. The album stays vertical for the
    /// whole of every animation and turns only on arrival.
    /// ⚠️ **BOTH SIDES OF THE COMPARISON MUST EXCLUDE THE HOME INDICATOR.** A
    /// detent's value does not count it and `view.bounds.height` does, so on a
    /// phone that has one the sheet measures ~34pt taller than the height it is
    /// resting at — it is never judged to have arrived, and the album stays a
    /// vertical grid inside a one-row sheet, drawn under its own bars. On an
    /// iPhone SE, where that inset is zero, the identical code looked perfect.
    /// That is the whole reason this was reported from a device and not caught
    /// here.
    private func settledAxis() -> UICollectionView.ScrollDirection {
        let homeIndicator = view.window?.safeAreaInsets.bottom ?? 0
        return Self.axis(
            forDetent: navigationController?.sheetPresentationController?.selectedDetentIdentifier,
            height: view.bounds.height - homeIndicator,
            restingHeight: restingHeight()
        )
    }

    /// The rule on its own, so it can be asked without a sheet to drag.
    static func axis(
        forDetent identifier: UISheetPresentationController.Detent.Identifier?,
        height: CGFloat,
        restingHeight: CGFloat
    ) -> UICollectionView.ScrollDirection {
        guard identifier == restingDetentIdentifier else { return .vertical }
        return height <= restingHeight + Metrics.settleTolerance ? .horizontal : .vertical
    }

    private func applyGridAxis(_ axis: UICollectionView.ScrollDirection) {
        guard axis != gridAxis else { return }
        gridAxis = axis
        // ⚠️ NOT INSIDE THE LAYOUT PASS THAT ASKED FOR IT. Swapping a collection
        // view's layout from within `viewDidLayoutSubviews` lays it out again
        // underneath itself. The next turn of the run loop is soon enough, and
        // the axis is already recorded, so nothing asks for the swap twice.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // ⚠️ NOT ANIMATED. A compositional layout swap animates every item
            // to its new place, and this one runs as the sheet arrives — two
            // animations over the same pixels, which reads as a stumble. The
            // album simply IS the other shape by the time the sheet lands.
            grid.setCollectionViewLayout(Self.gridLayout(axis: axis), animated: false)
            // ⚠️ AND THE OFFSET GOES BACK TO THE TOP. A swapped layout keeps
            // the offset it had, which in the new axis is measured against a
            // different content size — the album then opens part-scrolled,
            // with its first row sitting under the navigation bar.
            grid.setContentOffset(
                CGPoint(x: -grid.adjustedContentInset.left, y: -grid.adjustedContentInset.top),
                animated: false
            )
            // ⚠️ AND THE OTHER AXIS STOPS SCROLLING. Sideways, a vertical drag
            // has nowhere to go: left bouncing, it only makes the row look
            // loose and drags the sheet's own gesture into the argument.
            grid.alwaysBounceVertical = axis == .vertical
            grid.alwaysBounceHorizontal = axis == .horizontal
            grid.showsVerticalScrollIndicator = axis == .vertical
        }
    }

    // MARK: - Bars

    private func configureBars() {
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(
                title: "Cancel",
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        ]
        // Right-to-left: the first item is the RIGHTMOST, so "Next" sits at the
        // edge and "Drafts" beside it, which is the order the layout asks for.
        navigationItem.rightBarButtonItems = [
            nextItem,
            UIBarButtonItem(
                title: "Drafts",
                primaryAction: UIAction { [weak self] _ in self?.openDrafts() }
            )
        ]
        nextItem.style = .done
    }

    /// "Next" alone says nothing about what is going; "Next (3)" says what the
    /// step after this one will be handed.
    private func updateNextItem() {
        nextItem.title = selection.isEmpty ? "Next" : "Next (\(selection.count))"
        nextItem.isEnabled = !selection.isEmpty
    }

    private func openDrafts() {
        navigationController?.pushViewController(MediaDraftsViewController(), animated: true)
    }

    private func goNext() {
        let chosen = selection.ids.compactMap { itemsByID[$0] }
        guard !chosen.isEmpty else { return }
        navigationController?.pushViewController(onNext(chosen), animated: true)
    }

    /// The album strip, at the foot of the screen.
    ///
    /// No `SelectorTouchProbe` here, and that is not an oversight: the probe
    /// suspends a stack's back-swipe while a finger is on the strip, and this
    /// screen is the only one in its stack.
    private func showAlbums(_ albums: [MediaLibraryAlbum]) {
        self.albums = albums
        guard !albums.isEmpty else { return }
        let bar = albumBar ?? PagedTabBar(titles: albums.map(\.title), style: .navigationTitle)
        if albumBar == nil {
            // ⚠️ **THE TOOLBAR ALREADY SUPPLIES A CAPSULE.** iOS composites every
            // bar item through its own neutral glass, so a strip that also
            // carries its backdrop renders as a bubble inside a bubble — which
            // is exactly what shipped in the first cut of this screen. The
            // search results screen sets this for the same reason.
            bar.suppressesBackdrop = true
            bar.addAction(
                UIAction { [weak self] _ in self?.albumChanged() }, for: .valueChanged
            )
            albumBar = bar
            toolbarItems = [UIBarButtonItem(customView: bar), .flexibleSpace()]
            navigationController?.setToolbarHidden(false, animated: true)
        } else {
            bar.setTitles(albums.map(\.title))
        }
        // ⚠️ AFTER THE TITLES, ALWAYS, AND ON BOTH PATHS. A badge belongs to the
        // segment that carries it and `setTitles` rebuilds the segments, so a
        // count stamped before a retitle leaves with the segment that held it.
        for (index, album) in albums.enumerated() {
            bar.setBadge(album.count, at: index)
        }
    }

    private func albumChanged() {
        guard let index = albumBar?.selectedIndex, albums.indices.contains(index) else { return }
        Task { await showItems(in: albums[index]) }
    }
}

// MARK: - The library

private extension MediaPickerViewController {
    func load() async {
        var access = library.access
        if access == .undetermined {
            access = await library.requestAccess()
        }
        guard access == .granted || access == .limited else {
            showEmptyState(
                symbolName: "lock.fill",
                title: "No access to your photos",
                subtitle: "Allow photo access in Settings to pick something to post.",
                actionTitle: "Open Settings"
            ) {
                guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settings)
            }
            return
        }

        let albums = await library.albums()
        guard let first = albums.first else {
            showEmptyState(
                symbolName: "photo.on.rectangle.angled",
                title: "Nothing to post yet",
                subtitle: "Photos and videos you take will show up here."
            )
            return
        }
        showAlbums(albums)
        await showItems(in: first)
        refreshRestingHeight()
        #if DEBUG
        runDebugHooks()
        #endif
    }

    func showItems(in album: MediaLibraryAlbum) async {
        let loaded = await library.items(in: album.id)
        items = loaded
        // ⚠️ AND THE GRID COMES BACK. `showEmptyState` hides it, and an earlier
        // refusal followed by a grant would otherwise leave the album loaded,
        // correct, and invisible.
        grid.isHidden = false
        spinner.stopAnimating()
        // Merged, never replaced: a selection made in one album keeps its
        // thumbnails in the tray after the viewer moves to another, and the
        // screen after this one is handed items it may no longer be showing.
        for item in loaded { itemsByID[item.id] = item }
        emptyState.isHidden = !loaded.isEmpty
        if loaded.isEmpty {
            emptyState.configure(
                symbolName: "photo.on.rectangle.angled",
                title: "This album is empty"
            )
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(loaded.map(\.id))
        await dataSource.apply(snapshot, animatingDifferences: false)
        // ⚠️ THE OFFSET IS READ AFTER A LAYOUT PASS, NOT BEFORE ONE.
        // `adjustedContentInset` is only final once the grid has been laid out
        // inside the bars above and below it. Read on the way in it is short by
        // the navigation bar, and the album opens a few points too high — a
        // sliver of the first row showing above the top of the grid.
        grid.layoutIfNeeded()
        let top = -grid.adjustedContentInset.top
        let leading = -grid.adjustedContentInset.left
        grid.setContentOffset(
            gridAxis == .vertical ? CGPoint(x: 0, y: top) : CGPoint(x: leading, y: 0),
            animated: false
        )
    }

    func showEmptyState(
        symbolName: String,
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        emptyState.configure(
            symbolName: symbolName,
            title: title,
            subtitle: subtitle,
            actionTitle: actionTitle,
            actionHandler: action
        )
        emptyState.isHidden = false
        grid.isHidden = true
        spinner.stopAnimating()
    }
}

// MARK: - The grid

private extension MediaPickerViewController {
    var tileSide: CGFloat { Self.tileSide(forWidth: view.bounds.width) }

    /// Three tiles and FOUR gaps: one at each edge and one between each pair.
    static func tileSide(forWidth width: CGFloat) -> CGFloat {
        let gaps = Metrics.gutter * (Metrics.columns + 1)
        return max(((width - gaps) / Metrics.columns).rounded(.down), 60)
    }

    func configureGrid() {
        grid = UICollectionView(frame: .zero, collectionViewLayout: Self.gridLayout(axis: .vertical))
        grid.backgroundColor = .systemBackground
        grid.alwaysBounceVertical = true
        // A diagonal drag should not smear the row up and down while it travels.
        grid.isDirectionalLockEnabled = true
        grid.delegate = self
        grid.prefetchDataSource = self
        // ⚠️ **THE LAST ROW FADES RATHER THAN BEING CUT.** When the sheet
        // changes detent the album changes axis, and the rows below the first
        // stop existing between one frame and the next — which reads as a blink
        // along the bottom edge. A gradient mask placed at the VISIBLE bottom
        // (above the tray and the toolbar, not at the grid's own edge) turns
        // that into a dissolve, and it costs nothing when the sheet is open
        // because what it fades there is already behind the chrome.
        gridFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        gridFade.startPoint = CGPoint(x: 0.5, y: 0)
        gridFade.endPoint = CGPoint(x: 0.5, y: 1)
        grid.layer.mask = gridFade
        grid.pin(to: view)

        let cell = UICollectionView.CellRegistration<MediaPickerGridCell, String> { [weak self] cell, _, id in
            guard let self, let item = itemsByID[id] else { return }
            cell.configure(item: item, order: selection.order(of: id), isSelectable: canChoose(id))
            let size = CGSize(width: tileSide, height: tileSide)
            Task { [weak cell] in
                let image = await self.library.thumbnail(for: id, size: size)
                cell?.showThumbnail(image, for: id)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: grid) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
    }

    /// ⚠️ THE TILE IS MEASURED FROM THE LAYOUT ENVIRONMENT, not from
    /// `view.bounds`. A sheet is laid out at one width and re-laid at another
    /// as it is dragged, and a layout built against a stale width leaves a
    /// column hanging over the edge.
    static func gridLayout(axis: UICollectionView.ScrollDirection) -> UICollectionViewCompositionalLayout {
        var configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = axis
        return UICollectionViewCompositionalLayout(
            sectionProvider: { _, environment in
                let side = tileSide(forWidth: environment.container.effectiveContentSize.width)
                let size = NSCollectionLayoutSize(
                    widthDimension: .absolute(side), heightDimension: .absolute(side)
                )
                let item = NSCollectionLayoutItem(layoutSize: size)
                let group: NSCollectionLayoutGroup
                if axis == .vertical {
                    group = NSCollectionLayoutGroup.horizontal(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)
                        ),
                        repeatingSubitem: item,
                        count: Int(Metrics.columns)
                    )
                    group.interItemSpacing = .fixed(Metrics.gutter)
                } else {
                    group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
                }
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = Metrics.gutter
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: Metrics.gutter,
                    leading: Metrics.gutter,
                    bottom: Metrics.gutter,
                    trailing: Metrics.gutter
                )
                return section
            },
            configuration: configuration
        )
    }

    /// Places the bottom fade at the album's VISIBLE foot.
    ///
    /// ⚠️ A MASK ON A SCROLL VIEW'S LAYER SCROLLS WITH IT. The layer's bounds
    /// travel with `contentOffset`, so a mask pinned to `bounds` would slide
    /// away up the content. Its frame is therefore the visible rectangle
    /// expressed in content coordinates, refreshed on every scroll as well as
    /// on every layout.
    func updateGridFade() {
        let height = grid.bounds.height
        guard height > 0 else { return }

        // ⚠️ **NOT WHILE THE ALBUM IS A SINGLE ROW.** The fade is for rows
        // travelling under the strip; at rest the one row on screen IS the
        // content and passes under nothing. Widening the band to a whole tile
        // made it tall enough to wash out that row from the middle down — the
        // resting album came back visibly greyed. Sideways, the mask is flat.
        guard gridAxis == .vertical else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gridFade.frame = CGRect(origin: grid.contentOffset, size: grid.bounds.size)
            gridFade.locations = [0, 1, 1]
            CATransaction.commit()
            return
        }
        let visibleBottom = height - grid.adjustedContentInset.bottom
        // ⚠️ A WHOLE TILE, so a row is fully transparent by the time it is fully
        // under the strip and fully opaque while it is still clear of it. Half
        // a tile made the change abrupt enough to read as the blink it replaced.
        let band = Self.tileSide(forWidth: measuredWidth)
        let start = max(0, min(1, (visibleBottom - band) / height))
        let end = max(start, min(1, visibleBottom / height))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridFade.frame = CGRect(origin: grid.contentOffset, size: grid.bounds.size)
        gridFade.locations = [0, NSNumber(value: Float(start)), NSNumber(value: Float(end))]
        CATransaction.commit()
    }

    /// The room the tray takes, given back to the grid as inset rather than as
    /// height: the tiles under the tray stay where they are, and the last row
    /// can still be scrolled clear of it.
    func updateGridInsets() {
        let reserved = selection.isEmpty ? 0 : SelectedMediaTrayView.height + Metrics.trayGap
        grid.contentInset.bottom = reserved
        grid.verticalScrollIndicatorInsets.bottom = reserved
    }

    /// An unchosen tile stops offering itself once the cap is reached; a chosen
    /// one can always be given back.
    func canChoose(_ id: String) -> Bool {
        selection.order(of: id) != nil || !selection.isFull
    }
}

// MARK: - The selection

private extension MediaPickerViewController {
    func configureTray() {
        tray.onRemove = { [weak self] id in self?.drop(id) }
        tray.onReorder = { [weak self] order in self?.reorder(order) }

        // ⚠️ **NO BACKDROP BEHIND THE STRIP.** A blurred plate was tried here
        // and the user's answer was the right one: the album should be SEEN
        // through the strip's band and simply run out of opacity as it passes
        // under it. That is the grid's own bottom fade — see `updateGridFade()`
        // — and a plate would only hide the thing the fade exists to show.
        tray.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tray)
        trayBottom = tray.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: SelectedMediaTrayView.height
        )
        NSLayoutConstraint.activate([
            tray.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tray.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tray.heightAnchor.constraint(equalToConstant: SelectedMediaTrayView.height),
            trayBottom
        ])
    }

    func toggle(_ id: String) {
        let wasFull = selection.isFull
        switch selection.toggle(id) {
        case .refused:
            refuse()
        case .added, .removed:
            settle(changed: id, capChanged: wasFull != selection.isFull, animated: true)
        }
    }

    func drop(_ id: String) {
        let wasFull = selection.isFull
        selection.remove(id)
        settle(changed: id, capChanged: wasFull != selection.isFull, animated: true)
    }

    /// ⚠️ **NOTHING IS APPLIED FROM INSIDE THIS CALL, AND THE APP DIED LEARNING
    /// IT.** This arrives from the tray data source's own `didReorder`, which
    /// runs UNDERNEATH the snapshot apply that performed the move. Answering it
    /// by re-applying a snapshot — which `settle` did, through
    /// `tray.setItems` — is `NSInternalInconsistencyException`: "attempted to
    /// apply a snapshot to diffable data source while it was already applying a
    /// snapshot". The work is handed to the next turn of the run loop instead.
    ///
    /// On the accepted path the tray is deliberately NOT told: it already shows
    /// this order, being the thing that moved. Only the grid's numbers, which
    /// belong to a different data source, have to catch up.
    func reorder(_ order: [String]) {
        let accepted = selection.setOrder(order)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if accepted {
                refreshTiles(changed: nil, capChanged: false, animated: false)
            } else {
                // A report that is not a permutation of what is held is
                // refused, and the tray is put back to what the model says.
                tray.setItems(selection.ids, animated: false)
            }
        }
    }

    /// Everything a change to the selection touches, in one place: the strip,
    /// the numbers on the tiles, the room the grid gives up, how tall the sheet
    /// rests, and the word on the button that carries it all forward.
    func settle(changed: String?, capChanged: Bool, animated: Bool) {
        let hadTray = trayBottom.constant == 0
        tray.setItems(selection.ids, animated: animated)
        updateNextItem()
        updateGridInsets()
        refreshTiles(changed: changed, capChanged: capChanged, animated: animated)

        let wantsTray = !selection.isEmpty
        guard wantsTray != hadTray else {
            if wantsTray, animated { tray.scrollToEnd() }
            return
        }
        trayBottom.constant = wantsTray ? 0 : SelectedMediaTrayView.height
        let settleLayout = { self.view.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
                settleLayout()
            }
        } else {
            settleLayout()
        }
        // The tray is part of what the sheet rests around, so its arrival and
        // departure change the resting height.
        refreshRestingHeight()
    }

    /// ⚠️ THE TILE THAT WAS TAPPED IS UPDATED IN PLACE, AND THE REST THROUGH THE
    /// SNAPSHOT. A reconfigure re-runs the cell's registration, which cannot
    /// animate the one tile the finger is on — so that tile is configured
    /// directly, and the others (renumbered, or newly beyond the cap) follow
    /// without animation. A tile that is not on screen needs neither.
    func refreshTiles(changed: String?, capChanged: Bool, animated: Bool) {
        if let changed,
           let indexPath = dataSource.indexPath(for: changed),
           let cell = grid.cellForItem(at: indexPath) as? MediaPickerGridCell,
           let item = itemsByID[changed] {
            cell.configure(
                item: item,
                order: selection.order(of: changed),
                isSelectable: canChoose(changed),
                animated: animated
            )
        }

        var snapshot = dataSource.snapshot()
        let present = Set(snapshot.itemIdentifiers)
        // The cap crossing is the one case where every unchosen tile changes,
        // because they all stop — or start — offering themselves.
        var stale = capChanged ? present : Set(selection.ids).intersection(present)
        if let changed { stale.remove(changed) }
        guard !stale.isEmpty else { return }
        snapshot.reconfigureItems(Array(stale))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The cap, said once and briefly. A selection that cannot grow is not an
    /// error the viewer made.
    func refuse() {
        let alert = UIAlertController(
            title: "That's the limit",
            message: "You can post up to \(MediaPickerSelection.limit) photos and videos at a time.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Delegates

extension MediaPickerViewController: UICollectionViewDelegate {
    /// ⚠️ **SIDEWAYS, THE VERTICAL AXIS IS HELD SHUT.**
    /// `alwaysBounceVertical = false` is not enough on its own: the album is
    /// full-bleed behind its bars, so once the top inset and the tray's bottom
    /// inset are added its scrollable height overruns the band by a few points,
    /// and those few points are draggable. A viewer at rest could shift the row
    /// up and down a little, which is exactly what should not be possible.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // ⚠️ BEFORE THE AXIS GUARD, NOT AFTER IT. The mask has to be re-placed
        // on every scroll in BOTH axes — a fade refreshed only while the album
        // reads sideways would slide away the moment it is read downwards,
        // which is the one case this was built for.
        updateGridFade()
        guard gridAxis == .horizontal else { return }
        let top = -scrollView.adjustedContentInset.top
        guard abs(scrollView.contentOffset.y - top) > 0.5 else { return }
        scrollView.contentOffset.y = top
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        toggle(id)
    }
}

extension MediaPickerViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let side = tileSide
        library.startCaching(ids(at: indexPaths), size: CGSize(width: side, height: side))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let side = tileSide
        library.stopCaching(ids(at: indexPaths), size: CGSize(width: side, height: side))
    }

    private func ids(at indexPaths: [IndexPath]) -> [String] {
        indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
    }
}

extension MediaPickerViewController: UISheetPresentationControllerDelegate {
    /// The announcement only asks for a layout pass; that pass decides, once it
    /// can see the height the sheet actually reached.
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
        _ sheetPresentationController: UISheetPresentationController
    ) {
        view.setNeedsLayout()
    }
}

// MARK: - Debug

#if DEBUG
extension MediaPickerViewController {
    /// Internal for tests: what the screen currently holds, in order.
    var debugSelection: [String] { selection.ids }
    /// Internal for tests: the pills as the strip spells them.
    var debugAlbumTitles: [String] { albumBar?.currentTitles ?? [] }
    /// Internal for tests: whether the tray is up.
    var debugTrayIsShowing: Bool { trayBottom?.constant == 0 }
    /// Internal for tests: the items the grid is showing.
    var debugItems: [MediaLibraryItem] { items }
    /// Internal for tests: whether the screen is still saying it is working.
    var debugIsLoading: Bool { spinner.isAnimating }
    /// Internal for tests: which way the album scrolls right now.
    var debugGridAxis: UICollectionView.ScrollDirection { gridAxis }
    /// Internal for tests: how tall the sheet asks to rest.
    var debugRestingHeight: CGFloat { restingHeight() }

    /// What the sheet is actually resting on, behind `-upload-log-sheet`.
    ///
    /// ⚠️ `NSLog`, NOT `print`. `print` writes to stdout, which `simctl launch`
    /// throws away unless it is handed a pty — and a pty that is killed takes
    /// the app with it. This reaches the unified log, where
    /// `simctl spawn <udid> log show` can read it after the fact.
    func logSheet(_ moment: String) {
        guard ProcessInfo.processInfo.arguments.contains("-upload-log-sheet") else { return }
        let sheet = navigationController?.sheetPresentationController
        NSLog(
            "[picker] %@ resting=%@ bounds=%@ home=%@ axis=%@ bar=%@ toolbar=%@ tray=%@ selected=%@",
            moment,
            "\(restingHeight())",
            "\(view.bounds.height)",
            "\(view.window?.safeAreaInsets.bottom ?? 0)",
            gridAxis == .horizontal ? "H" : "V",
            "\(measuredBarHeight)",
            "\(measuredToolbarHeight)",
            "\(selection.isEmpty ? 0 : SelectedMediaTrayView.height)",
            sheet?.selectedDetentIdentifier?.rawValue ?? "nil"
        )
    }
    /// Internal for tests: the one gap that is both margin and gutter.
    static var debugGutter: CGFloat { Metrics.gutter }
    /// Internal for tests: the air between the album and the strip.
    static var debugTrayGap: CGFloat { Metrics.trayGap }

    /// Internal for tests: the tile the grid would cut at this width.
    static func debugTileSide(forWidth width: CGFloat) -> CGFloat {
        tileSide(forWidth: width)
    }

    /// Internal for tests: the path a tap takes, without a window to hit-test in.
    func debugTapItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        toggle(items[index].id)
    }

    /// Internal for tests: what a finished drag reports.
    func debugReorder(_ order: [String]) {
        reorder(order)
    }

    /// `-upload-album <index>` opens on that album, `-upload-pick 0,2,5` chooses
    /// those tiles, and `-upload-expand` opens on the large detent — the
    /// simulator cannot tap a grid or drag a sheet, and a screenshot of an empty
    /// selection shows neither the numbering nor the tray.
    func runDebugHooks() {
        let arguments = ProcessInfo.processInfo.arguments
        if let raw = Self.debugArgument("-upload-album", in: arguments),
           let index = Int(raw), albums.indices.contains(index) {
            albumBar?.select(index)
            Task { await showItems(in: albums[index]) }
        }
        if arguments.contains("-upload-expand"), let sheet = navigationController?.sheetPresentationController {
            // The axis is NOT set here. Changing the detent lays the sheet out,
            // and that pass decides — a debug hook that carried its own copy of
            // the rule would be the one place it could drift.
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
        guard let picks = Self.debugArgument("-upload-pick", in: arguments) else { return }
        for index in picks.split(separator: ",").compactMap({ Int($0) }) {
            debugTapItem(at: index)
        }
    }

    private static func debugArgument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }
}
#endif
