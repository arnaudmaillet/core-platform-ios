import AVFoundation
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// The sound a post is set to, opened from the attribution at the foot of
/// the feed: what it is, a listen, the posts set to it, and — in the sheet's
/// native toolbar — "Use this sound", save and share.
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ ▔▔                                   │
///  │╭────╮  Veridis Quo                   │  the round artwork = play/pause
///  ││ ▶︎  │  Daft Punk                     │  (it turns while the sound plays)
///  │╰────╯  0:30 · 7 posts                │
///  │▢♪Original ▢Watching ▢                │  the first row
///  │         View all 7 posts ⌄           │
///  │(   Use this sound         )(🔖)(↑)   │  ← collapsed detent ends here:
///  ├──────────────────────────────────────┤    the toolbar, row 2 under it
///  │▢ ▢ ▢                                 │  large: the grid, whole
///  └──────────────────────────────────────┘
/// ```
///
/// **ONE GUTTER** (`gutter`) is the sheet's side margin, the gap between tiles
/// and the gap between rows, and the header stands on it too: sound, tiles and
/// "View all" share one left edge. The tiles' corners are CONCENTRIC with the
/// sheet's (`SoundSheetTileCell`).
///
/// **PRESENTED INSIDE A NAVIGATION CONTROLLER** (`wrappedInSheet()`), for its
/// toolbar alone — the bar is hidden. The actions are bar items, so they are
/// UIKit's glass, not buttons of ours pinned to the bottom, and the grid
/// scrolls on UNDER them behind the system's scroll-edge effect. Nothing here
/// writes an alpha on that chrome (see memory `native-chrome-uikit-only`).
///
/// **THE COLLAPSED DETENT IS COMPUTED, NEVER MEASURED OFF THE LIVE SHEET**
/// (`collapsedDetentHeight`): the sound's header, the first row and "View
/// all" are pure arithmetic on the sheet's WIDTH and the text size, plus the
/// toolbar's band — nothing that depends on how tall the sheet is right now.
/// So the answer is the same at every visit to collapsed, and it is asked
/// again (`invalidateDetents`) only when an INPUT changes: the post count
/// crossing a row, the text size, the width, the band once known.
///
/// ⚠️ **NEVER FROM A LAYOUT CALLBACK.** #296 re-measured the fold in
/// `viewDidLayoutSubviews` and invalidated the detents inside `animateChanges`
/// when it moved. A drag from the grabber lays the sheet out on every frame,
/// the fold read there moved with the sheet (the "View all" row coming back
/// mid-flight, a safe area caught between detents), and each re-resolve laid
/// the sheet out again: a stack overflow (`EXC_BAD_ACCESS` code 2 in
/// `invalidateDetents`), and between crashes a collapsed height that drifted
/// from one visit to the next.
///
/// **THE FEED STAYS ALIVE UNDER THE SHEET, AT EVERY DETENT.** Neither detent
/// pauses the clip behind: a detent is where the sheet sits, not a choice to
/// stop listening. (Large paused it for a while; the viewer asked for the post
/// to keep playing, 2026-09-28.)
///
/// **"VIEW ALL" LEAVES THE GRID AT LARGE.** At large every post is on screen,
/// so a control promising more would promise nothing — and one left between
/// the first row and the second would cut the grid in two. It goes (the
/// snapshot drops its section, animated) and comes back with the collapsed
/// detent. The way down is the platform's: the grabber, or a drag.
///
/// **FROM LARGE, A DRAG DOWN COMES BACK TO COLLAPSED**; a second one closes.
///
/// ⚠️ **THE PREVIEW PAUSES THE CLIP** (`onCoverChanged`), at any detent. Two
/// sounds at once is noise; listening to the sound is a choice the viewer just
/// made, so the clip gives way until the preview stops or the sheet goes. A
/// feed opened from a tile covers it the same way, for the trip.
final class SoundSheetViewController: UIViewController {
    struct Tile: Hashable, Sendable {
        let postID: PostID
        let thumbnailURL: URL?
        /// What a text post shows in its tile, having no picture.
        let caption: String?
        /// The post the sheet was opened from.
        let isCurrent: Bool
        /// The post the sound was first published with — first in the grid.
        let isOriginal: Bool
        /// Whether the post itself is known yet. The grid lists EVERY post set
        /// to the sound, most of them outside the feed behind: those arrive as
        /// placeholders — so the sheet rises at once, at its final size — and
        /// are filled in by `update(tiles:)` once the repository has them.
        let isLoaded: Bool

        init(
            postID: PostID, thumbnailURL: URL?, caption: String?, isCurrent: Bool,
            isOriginal: Bool = false, isLoaded: Bool = true
        ) {
            self.postID = postID
            self.thumbnailURL = thumbnailURL
            self.caption = caption
            self.isCurrent = isCurrent
            self.isOriginal = isOriginal
            self.isLoaded = isLoaded
        }
    }

    /// The grid in three sections, so the fold has a place of its own: the
    /// first row (under the sound, as its header), "View all" while there is
    /// more to view and the sheet is collapsed, then the rest.
    enum Section: Hashable, Sendable {
        case firstRow, more, rest
    }

    /// ⚠️ A tile is identified by its POST, not by its content: a placeholder
    /// filled in is the same item reconfigured, and an original that moves is
    /// the same item moved.
    enum Item: Hashable, Sendable {
        case tile(PostID)
        case more
    }

    /// Whether the clip behind should pause: the preview is playing, or a
    /// feed opened from a tile covers it. NEVER the detent alone.
    var onCoverChanged: ((Bool) -> Void)?
    /// A tile was chosen; the sheet is already on its way out.
    var onSelectPost: ((PostID) -> Void)?
    /// Opens a NEW feed of the posts with this sound, flying out of the tapped
    /// tile — the app's own zoom hero. The feed is pushed onto a stack
    /// presented over this sheet (`OverSheetFeedHost`), so the sheet stays
    /// where it is and a dismissal flies back into the tile. Nil falls back to
    /// `onSelectPost`.
    var openFeedHero: ((_ postIDs: [PostID], _ host: UIViewController, _ origin: SnapFeedHeroOrigin) -> Void)?
    /// The tiles' posts as the grid knows them — what the hero flies and the
    /// new feed is seeded with.
    var galleryPost: ((PostID) -> GalleryPost?)?
    /// "Use this sound"; the sheet is already on its way out. Nil leaves the
    /// toolbar with share alone.
    var onUseSound: ((PostSound) -> Void)? {
        didSet { if isViewLoaded { toolbarItems = makeToolbarItems() } }
    }
    /// The sheet is gone, however it went.
    var onDismissed: (() -> Void)?

    static let collapsedDetent = UISheetPresentationController.Detent.Identifier("sound.collapsed")
    static let columns = 3
    /// Under the grabber, before the sound starts.
    static let topInset: CGFloat = 24
    /// THE gutter: the sheet's side margin, between tiles, between rows — the
    /// Upload picker's rule (`Spacing.sm` both ways), so the grid reads as
    /// tiles on the sheet rather than a wall with a frame around it.
    static let gutter: CGFloat = Spacing.sm
    /// Between the fold — "View all", or the first row when there is nothing
    /// more — and the toolbar's band.
    static let foldGap: CGFloat = Spacing.sm
    /// Under the first row when there is no "View all": a little more than a
    /// gutter, so the row does not sit on the bar.
    static let singleRowFoldGap: CGFloat = Spacing.lg

    private let sound: PostSound
    private let authorHandle: String
    private let fallbackArtworkURL: URL?
    private(set) var tiles: [Tile]
    private var tileByID: [PostID: Tile]
    private let imagePipeline: ImagePipeline
    private let savedSounds: SavedSoundStore

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private weak var header: SoundSheetHeaderView?
    private weak var shareItem: UIBarButtonItem?
    private weak var useItem: UIBarButtonItem?
    private(set) weak var bookmarkItem: UIBarButtonItem?

    /// What the collapsed detent is made of, and its value (`collapsedHeight`)
    /// — set only by `refreshCollapsedMetrics`, never by a layout pass.
    private(set) var collapsedMetrics: CollapsedMetrics?
    private(set) var collapsedHeight: CGFloat?
    /// How often the collapsed detent was re-asked — what a test reads to
    /// prove that laying the sheet out never does it.
    private(set) var detentInvalidations = 0
    /// The sheet's width, the one input of the grid's geometry.
    private var sheetWidth: CGFloat?
    /// The toolbar's band above the home indicator, as the sheet's safe area
    /// last reported it (`viewIsAppearing`). Kept across sheets: it is the
    /// bar's, not this sound's, so the second sheet rises at the exact height.
    private static var measuredToolbarBand: CGFloat?
    private var headerHeightCache: (key: String, height: CGFloat)?
    private(set) var isExpanded = false
    private var isPreviewing = false
    private var isCovering = false
    private var preview: AVPlayer?
    private var previewEndObserver: NSObjectProtocol?
    private var previewTimeObserver: Any?
    private var raisedSessionForPreview = false

    init(
        sound: PostSound,
        authorHandle: String,
        fallbackArtworkURL: URL?,
        tiles: [Tile],
        imagePipeline: ImagePipeline,
        savedSounds: SavedSoundStore = SavedSoundStore()
    ) {
        self.sound = sound
        self.authorHandle = authorHandle
        self.fallbackArtworkURL = fallbackArtworkURL
        self.tiles = tiles
        self.tileByID = Dictionary(tiles.map { ($0.postID, $0) }, uniquingKeysWith: { first, _ in first })
        self.imagePipeline = imagePipeline
        self.savedSounds = savedSounds
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet as it is presented: this screen as the root of a navigation
    /// controller that shows its TOOLBAR (the actions) and hides its bar, set
    /// up as a page sheet with the collapsed and large detents.
    ///
    /// ⚠️ The sheet's configuration lives on the NAVIGATION controller's
    /// presentation — the one presented — and this screen is its delegate.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.setToolbarHidden(false, animated: false)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [
                // ⚠️ READS A STORED ANSWER, NOTHING ELSE: a resolver that lays
                // out or loads a view runs inside the sheet's own resolution
                // (memory `upload-media-picker`).
                .custom(identifier: Self.collapsedDetent) { [weak self] context in
                    min(self?.collapsedHeight ?? 420, context.maximumDetentValue)
                },
                .large(),
            ]
            sheet.selectedDetentIdentifier = Self.collapsedDetent
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.delegate = self
        }
        return navigation
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ CLEAR, so the sheet's own glass is the surface at the collapsed
        // detent — a painted background makes it opaque at every height.
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.contentInset.top = Self.topInset
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        // To the bottom edge, UNDER the toolbar: the grid goes on behind the
        // bar's glass, and the safe area (the bar's band) is its inset.
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The toolbar's scroll-edge effect reads THIS scroll view.
        setContentScrollView(collectionView, for: .bottom)
        // Before the first layout and before the sheet asks its detent: the
        // presenter's window gives the width the sheet will have.
        sheetWidth = presentingViewController?.view.window?.bounds.width ?? view.bounds.width
        refreshCollapsedMetrics(reason: "load")
        toolbarItems = makeToolbarItems()
        configureDataSource()
        // A text size change moves the header and so the fold: an input.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: SoundSheetViewController, _: UITraitCollection) in
            controller.refreshCollapsedMetrics(reason: "text size")
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // In a window now: the real width, and the toolbar's real band — the
        // bottom safe area less the window's. Both are the BAR's and the
        // screen's, the same at any detent, so reading them here converges:
        // at most one correction, the first time a sheet is ever shown (the
        // band is kept for the next ones).
        if let window = view.window {
            if view.bounds.width > 0 { sheetWidth = view.bounds.width }
            let band = Self.toolbarBand(
                bottomSafeArea: view.safeAreaInsets.bottom, windowBottomSafeArea: window.safeAreaInsets.bottom
            )
            // No band is a safe area caught without its bar, not a bar of none.
            if band > 0 { Self.measuredToolbarBand = band }
        }
        refreshCollapsedMetrics(reason: "appearing")
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // A new width is a new grid — an input, not a layout pass.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, view.bounds.width > 0 else { return }
            sheetWidth = view.bounds.width
            refreshCollapsedMetrics(reason: "size")
        }
    }

    // ⚠️ NO `viewDidLayoutSubviews` HERE, DELIBERATELY — see the type's note.
    // The collapsed height is never re-read from a layout.

    // ⚠️ NO `preferredCornerRadius`: UIKit's own. Setting the device's radius
    // once the sheet had appeared made the corners pop from one value to the
    // other as it rose.

    /// ⚠️ The NAVIGATION controller is what is dismissed; this screen, its
    /// root, is not "being dismissed" itself.
    private var isSheetBeingDismissed: Bool {
        isBeingDismissed || navigationController?.isBeingDismissed == true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isSheetBeingDismissed else { return }
        stopPreview()
        tearDownPreview()
    }

    /// The preview's player and its observers go with the sheet.
    private func tearDownPreview() {
        if let previewEndObserver { NotificationCenter.default.removeObserver(previewEndObserver) }
        if let previewTimeObserver { preview?.removeTimeObserver(previewTimeObserver) }
        previewEndObserver = nil
        previewTimeObserver = nil
        preview = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isSheetBeingDismissed else { return }
        setCovering(false)
        onDismissed?()
    }

    // MARK: - Toolbar

    /// `[Use this sound ——————][🔖][↑]`: "Use this sound" takes every point
    /// the two trailing bubbles leave; save and share are a bubble EACH — the
    /// zero-width fixed spaces are what keep UIKit from joining them in one
    /// shared glass platter. Without a way to use the sound, save and share
    /// keep the trailing edge.
    ///
    /// **"USE THIS SOUND" FILLS THE BAR BY AUTO LAYOUT, NOT BY ARITHMETIC.**
    /// There is no flexible-width bar item, and a `.prominent` title item's
    /// `width` is IGNORED on iOS 27 (set to 266, drawn at its title's ~144).
    /// A custom view that hugs nothing and asks, at the lowest priority, for
    /// more room than any bar has is stretched by the bar to exactly what the
    /// other items leave — measured on iOS 27 — whatever the width, the text
    /// size or the OS's bar margins. Its own `.prominentGlass()` capsule is
    /// its background, so the item hides the shared one (no bubble in a
    /// bubble).
    private func makeToolbarItems() -> [UIBarButtonItem] {
        let share = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() }
        )
        share.accessibilityLabel = "Share sound"
        shareItem = share
        // ⚠️ AN ACTION WITHOUT AN IMAGE, the glyph on the ITEM: an action's
        // image is re-applied to its item when it fires, and put the
        // "bookmark" outline back over the fill just set (measured: the fill
        // flashed during the press and was gone at rest).
        let bookmark = UIBarButtonItem(primaryAction: UIAction { [weak self] _ in self?.toggleSaved() })
        bookmarkItem = bookmark
        refreshBookmark()
        let trailing: [UIBarButtonItem] = [bookmark, .fixedSpace(), share]
        guard onUseSound != nil else { return [.flexibleSpace()] + trailing }
        let use = UIBarButtonItem(customView: makeUseButton())
        use.hidesSharedBackground = true
        useItem = use
        return [use, .fixedSpace()] + trailing
    }

    /// The prominent red capsule, as tall as the bar's bubbles.
    private func makeUseButton() -> UIButton {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.title = "Use this sound"
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .body).withWeight(.semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.useSound()
        })
        button.accessibilityIdentifier = "sound.use"
        // Hugs nothing, and wants everything — at the lowest priorities, so
        // the bar's own layout (the bubbles, their gaps, its margins) wins
        // and this takes the rest.
        button.setContentHuggingPriority(.init(1), for: .horizontal)
        let fill = button.widthAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .init(2)
        // 999, never required: the bar's first pass pins its item wrapper to
        // the raw intrinsic size (`SnapNavControls.makeCircularBarButton`).
        let height = button.heightAnchor.constraint(equalToConstant: Self.barBubbleHeight)
        height.priority = .init(999)
        NSLayoutConstraint.activate([fill, height])
        return button
    }

    /// The bar's glass bubbles' height (bookmark, share): 48, measured on
    /// iOS 27 (iPhone 18 Pro) — at 44 the capsule stood visibly shorter.
    static let barBubbleHeight: CGFloat = 48

    /// The "Use this sound" control — what a test reads.
    var useButton: UIButton? { useItem?.customView as? UIButton }

    // MARK: - Saved

    /// Saves the sound, or unsaves it; the glyph and its label follow.
    private func toggleSaved() {
        let saved = savedSounds.toggle(sound.id)
        refreshBookmark()
        trace("saved \(sound.id): \(saved)")
    }

    /// The bookmark's glyph for the sound's state — what a test reads.
    var bookmarkSymbol: String { savedSounds.isSaved(sound.id) ? "bookmark.fill" : "bookmark" }

    private func refreshBookmark() {
        let saved = savedSounds.isSaved(sound.id)
        bookmarkItem?.image = UIImage(systemName: bookmarkSymbol)
        // The label follows the state, like the feed's: "Save" and "Saved"
        // are different offers to a reader who cannot see the fill.
        bookmarkItem?.accessibilityLabel = saved ? "Sound saved" : "Save sound"
    }

    #if DEBUG
    /// Presses the save item, as a tap would.
    func debugToggleSaved() { toggleSaved() }
    #endif

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            switch self?.dataSource?.sectionIdentifier(for: index) ?? .firstRow {
            case .firstRow:
                // Row two follows one gutter down once "View all" has left
                // (large). ⚠️ The header is ABSOLUTE, at the height the
                // collapsed detent was computed with — a self-sizing header
                // settles after an estimate, and the fold would move with it.
                let section = Self.gridSection(environment, bottom: Self.gutter)
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(self?.collapsedMetrics?.headerHeight ?? 112)
                    ),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
                )
                section.boundarySupplementaryItems = [header]
                return section
            case .more:
                let size = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .absolute(SoundSheetMoreCell.height)
                )
                let section = NSCollectionLayoutSection(
                    group: .horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                )
                section.contentInsets = .init(
                    top: 0, leading: Self.gutter, bottom: Self.foldGap, trailing: Self.gutter
                )
                return section
            case .rest:
                return Self.gridSection(environment, bottom: Spacing.xl)
            }
        }
    }

    /// Three columns of 3:4 tiles, one gutter from the sheet's sides and from
    /// each other.
    private static func gridSection(
        _ environment: NSCollectionLayoutEnvironment, bottom: CGFloat
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1),
                              heightDimension: .absolute(tileHeight(width: environment.container.effectiveContentSize.width))),
            repeatingSubitem: item, count: columns
        )
        group.interItemSpacing = .fixed(gutter)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = gutter
        section.contentInsets = .init(top: 0, leading: gutter, bottom: bottom, trailing: gutter)
        return section
    }

    /// A tile's height on a sheet `width` wide: three columns and four
    /// gutters across, each tile 3:4. What the grid lays out AND what the
    /// collapsed detent counts — one function, so they cannot disagree.
    static func tileHeight(width: CGFloat) -> CGFloat {
        let column = (width - CGFloat(columns + 1) * gutter) / CGFloat(columns)
        return (max(0, column) * 4 / 3).rounded()
    }

    private func configureDataSource() {
        let pipeline = imagePipeline
        let tileRegistration = UICollectionView.CellRegistration<SoundSheetTileCell, PostID> {
            [weak self] cell, _, id in
            guard let tile = self?.tileByID[id] else { return }
            cell.configure(tile, pipeline: pipeline)
        }
        let moreRegistration = UICollectionView.CellRegistration<SoundSheetMoreCell, Item> { [weak self] cell, _, _ in
            cell.configure(title: Self.moreTitle(posts: self?.tiles.count ?? 0))
            cell.onTap = { [weak self] in self?.expand() }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SoundSheetHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, _ in
            guard let self else { return }
            self.configure(header)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, item in
            switch item {
            case .tile(let id):
                view.dequeueConfiguredReusableCell(using: tileRegistration, for: path, item: id)
            case .more:
                view.dequeueConfiguredReusableCell(using: moreRegistration, for: path, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: path)
        }
        dataSource.apply(makeSnapshot(), animatingDifferences: false)
    }

    /// The first row; "View all" while collapsed with more to show; the rest.
    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Section, Item> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.firstRow])
        snapshot.appendItems(tiles.prefix(Self.columns).map { .tile($0.postID) }, toSection: .firstRow)
        let rest = tiles.dropFirst(Self.columns)
        guard !rest.isEmpty else { return snapshot }
        if !isExpanded {
            snapshot.appendSections([.more])
            snapshot.appendItems([.more], toSection: .more)
        }
        snapshot.appendSections([.rest])
        snapshot.appendItems(rest.map { .tile($0.postID) }, toSection: .rest)
        return snapshot
    }

    /// The grid's posts as now known: placeholders filled in, a post that could
    /// not be loaded gone, the original moved if it turned out not to be one.
    /// Tiles whose content changed are reconfigured in place; the count on the
    /// header and on "View all" follows.
    func update(tiles newTiles: [Tile]) {
        let changed = newTiles.filter { tileByID[$0.postID] != nil && tileByID[$0.postID] != $0 }
        tiles = newTiles
        tileByID = Dictionary(newTiles.map { ($0.postID, $0) }, uniquingKeysWith: { first, _ in first })
        guard dataSource != nil else { return }
        var snapshot = makeSnapshot()
        snapshot.reconfigureItems(changed.map { .tile($0.postID) })
        if snapshot.indexOfSection(.more) != nil { snapshot.reconfigureItems([.more]) }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        if !isPreviewing { header?.setMeta(Self.meta(duration: sound.duration, posts: tiles.count)) }
        // A count crossing the first row adds or removes "View all": the one
        // content change that moves the fold.
        refreshCollapsedMetrics(reason: "tiles")
    }

    private func configure(_ header: SoundSheetHeaderView) {
        self.header = header
        header.configure(
            title: sound.title ?? "Original sound",
            subtitle: sound.artist ?? "@\(authorHandle)",
            meta: Self.meta(duration: sound.duration, posts: tiles.count),
            canPreview: sound.previewURL != nil
        )
        header.setPlaying(isPreviewing)
        header.onTogglePreview = { [weak self] in self?.togglePreview() }
        if let url = sound.artworkURL ?? fallbackArtworkURL {
            Task { [weak header, pipeline = imagePipeline] in
                header?.setArtwork(await Self.image(at: url, pipeline: pipeline))
            }
        }
    }

    // MARK: - Collapsed detent

    /// Everything the collapsed height is made of. Each is an INPUT — the
    /// sheet's width, the header at the text size, whether "View all" is
    /// there, the toolbar's band — and none depends on how tall the sheet is.
    struct CollapsedMetrics: Equatable {
        var width: CGFloat
        var headerHeight: CGFloat
        var hasMore: Bool
        var toolbarBand: CGFloat
    }

    /// The collapsed detent's value: the fold (`foldBottom`), then the
    /// toolbar's band.
    ///
    /// ⚠️ A custom detent's height EXCLUDES the bottom safe area — the sheet
    /// adds it back (memory `economy-ab-claim-sheet`). The toolbar stands on
    /// that safe area, so what the detent owes it is its band ABOVE it:
    /// counting the whole inset rested the fold 34pt too high.
    static func collapsedDetentHeight(_ metrics: CollapsedMetrics) -> CGFloat {
        (foldBottom(width: metrics.width, headerHeight: metrics.headerHeight, hasMore: metrics.hasMore)
            + metrics.toolbarBand).rounded(.up)
    }

    /// Where the fold ends, from the sheet's top edge, with the grid at rest:
    /// the inset under the grabber, the sound, the first row, then "View all"
    /// and its gap — or, with nothing more to view, the first row's own gap.
    /// The grid's layout is built from the same numbers (`tileHeight`, the
    /// absolute header, the `.more` section's insets).
    static func foldBottom(width: CGFloat, headerHeight: CGFloat, hasMore: Bool) -> CGFloat {
        let rowBottom = topInset + headerHeight + tileHeight(width: width)
        guard hasMore else { return rowBottom + singleRowFoldGap }
        return rowBottom + gutter + SoundSheetMoreCell.height + foldGap
    }

    /// The toolbar's band above the home indicator: the view's bottom safe
    /// area less the window's.
    static func toolbarBand(bottomSafeArea: CGFloat, windowBottomSafeArea: CGFloat) -> CGFloat {
        max(0, bottomSafeArea - windowBottomSafeArea)
    }

    /// Recomputes the collapsed height from its inputs and re-asks the sheet
    /// ONLY when the answer moved. Called when an input changes — loading,
    /// appearing (the real width and band), the text size, the width, the
    /// tiles — and from nowhere else. ⚠️ Never from a layout callback: see the
    /// type's note.
    private func refreshCollapsedMetrics(reason: String) {
        guard let width = sheetWidth, width > 0 else { return }
        let traits = view.window != nil
            ? traitCollection
            : (presentingViewController?.traitCollection ?? traitCollection)
        let metrics = CollapsedMetrics(
            width: width,
            headerHeight: headerHeight(width: width, traits: traits),
            hasMore: tiles.count > Self.columns,
            toolbarBand: Self.measuredToolbarBand ?? estimatedToolbarBand(width: width)
        )
        guard metrics != collapsedMetrics else { return }
        let headerMoved = metrics.headerHeight != collapsedMetrics?.headerHeight
        let previous = collapsedHeight
        collapsedMetrics = metrics
        let height = Self.collapsedDetentHeight(metrics)
        collapsedHeight = height
        trace("""
            \(reason): width \(metrics.width) header \(metrics.headerHeight) more \(metrics.hasMore) \
            band \(metrics.toolbarBand) → \(height) (was \(previous.map { "\($0)" } ?? "nil"))
            """)
        if headerMoved, isViewLoaded { collectionView.collectionViewLayout.invalidateLayout() }
        guard let previous, abs(previous - height) >= 0.5 else { return }
        invalidateCollapsedDetent()
    }

    /// The one place the detents are re-asked.
    private func invalidateCollapsedDetent() {
        detentInvalidations += 1
        // Only a sheet that is up has detents to move.
        guard let navigation = navigationController, navigation.presentingViewController != nil,
              let sheet = navigation.sheetPresentationController else { return }
        // While it rises (the first `viewIsAppearing`) the presentation
        // animates the change itself.
        if navigation.transitionCoordinator != nil {
            sheet.invalidateDetents()
        } else {
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    /// Before any sheet has been shown, the bar's band as the bar says it
    /// would be. ⚠️ An ESTIMATE: it answered 48 where the sheet's safe area
    /// later gave 52 (iPhone 18 Pro, iOS 27) — `viewIsAppearing` corrects it
    /// once, and the measure is kept for every sheet after. `toolbar.frame` is
    /// no help: it spans the whole view on iOS 27, its glass items floating.
    private func estimatedToolbarBand(width: CGFloat) -> CGFloat {
        navigationController?.toolbar.sizeThatFits(CGSize(width: width, height: 0)).height ?? 0
    }

    /// The header's height at `width` and the text size: a sizing header with
    /// the sound's own lines, fitted off screen — the sheet's height plays no
    /// part. Cached per width and text size.
    private func headerHeight(width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let headerWidth = width - 2 * Self.gutter
        let key = "\(headerWidth)|\(traits.preferredContentSizeCategory.rawValue)"
        if let headerHeightCache, headerHeightCache.key == key { return headerHeightCache.height }
        var height: CGFloat = 0
        traits.performAsCurrent {
            height = SoundSheetHeaderView.fittingHeight(
                width: headerWidth,
                title: sound.title ?? "Original sound",
                subtitle: sound.artist ?? "@\(authorHandle)",
                // The meta line is one line whatever it says.
                meta: Self.meta(duration: sound.duration, posts: tiles.count),
                canPreview: sound.previewURL != nil
            )
        }
        headerHeightCache = (key, height)
        return height
    }

    /// `-sound-sheet-trace`: the height the sheet SETTLED at after a detent
    /// change, read once the spring is over — collapsed must read the same
    /// value at every visit. Read-only: it moves nothing.
    private func traceSettledHeight(expanded: Bool) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-sound-sheet-trace") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let window = view.window else { return }
            let settled = view.bounds.height - window.safeAreaInsets.bottom
            let detent = collapsedHeight.map { "\($0)" } ?? "nil"
            trace("settled \(expanded ? "large" : "collapsed"): \(settled) (detent \(detent), invalidations \(detentInvalidations))")
            // Geometry, in the WINDOW: a collapsed sheet floats inset and is
            // drawn SCALED (measured 402 wide in its own space, 386 on
            // screen), so the view's bounds stay the width the grid and the
            // detent are computed for.
            let inWindow: CGRect = view.convert(view.bounds, to: nil)
            let use: CGRect = useButton.map { $0.convert($0.bounds, to: nil) } ?? .zero
            trace("geometry: view \(view.bounds) on screen \(inWindow) use \(use)")
        }
        #endif
    }

    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sound-sheet-trace") {
            // NSLog, not print: it reaches the unified log, which `simctl`
            // can read back without a pty (memory `upload-media-picker`).
            NSLog("[sound-sheet] %@", message())
        }
        #endif
    }

    // MARK: - Text

    /// A local file is read as it is; anything else goes through the app's
    /// pipeline. ⚠️ Not everything through the pipeline: the mock one paints
    /// a colour for any URL it does not recognise, a file among them.
    private static func image(at url: URL, pipeline: ImagePipeline) async -> UIImage? {
        if url.isFileURL {
            return await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)?.preparingForDisplay()
            }.value
        }
        return try? await pipeline.image(for: url)
    }

    /// "0:30 · 3 posts" — POSTS, not videos: a photograph or a text post can
    /// be set to a sound too.
    static func meta(duration: TimeInterval?, posts: Int) -> String {
        let count = posts == 1 ? "1 post" : "\(posts) posts"
        guard let duration, duration > 0 else { return count }
        return "\(Self.clock(duration)) · \(count)"
    }

    /// "View all 7 posts": the whole grid is what it opens, and the count
    /// says how much of it the first row is not.
    static func moreTitle(posts: Int) -> String {
        "View all \(posts) posts"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Order

    /// The grid's posts, in order, and which of them is MARKED "Original":
    /// 1. the post the sound was first published with, unless it is known to
    ///    be a text post (a text post's words are no "original" of a sound: it
    ///    then keeps its place among the others);
    /// 2. the post the sheet was opened from;
    /// 3. every other post set to the sound, as the provider ranks them —
    ///    across the whole corpus, not only the feed behind the sheet.
    /// Each post once.
    ///
    /// `isMedia` is nil for a post not loaded yet. An unknown original still
    /// leads — it is a clip's post far more often than not, and holding its
    /// place keeps the grid from reshuffling when it loads — but it is marked
    /// only once it is KNOWN to be a media post.
    static func gridPostIDs(
        current: PostID,
        original: PostID?,
        using: [PostID],
        isMedia: (PostID) -> Bool?
    ) -> (ids: [PostID], original: PostID?) {
        let leading = original.flatMap { isMedia($0) == false ? nil : $0 }
        var ids: [PostID] = []
        var seen = Set<PostID>()
        for id in [leading, current].compactMap({ $0 }) + using where seen.insert(id).inserted {
            ids.append(id)
        }
        return (ids, leading.flatMap { isMedia($0) == true ? $0 : nil })
    }

    // MARK: - Expansion

    /// "View all": up to the whole grid.
    private func expand() {
        guard let sheet = navigationController?.sheetPresentationController, !isExpanded else { return }
        // A programmatic change is not reported to the delegate.
        detentChanged(to: .large)
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
    }

    #if DEBUG
    /// `-snap-sound-sheet large`: "View all", without the tap.
    func debugExpand() { expand() }

    /// `-snap-sound-sheet roundtrip`: back down to collapsed, as the grabber
    /// would take it.
    func debugCollapse() {
        guard let sheet = navigationController?.sheetPresentationController else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = Self.collapsedDetent }
        detentChanged(to: Self.collapsedDetent)
    }
    #endif

    // MARK: - Cover

    private func setCovering(_ covering: Bool) {
        guard covering != isCovering else { return }
        isCovering = covering
        onCoverChanged?(covering)
    }

    /// ⚠️ NOT `isExpanded`: the large detent leaves the clip behind playing,
    /// like the collapsed one — only a second sound or a second feed covers it.
    private func refreshCover() {
        setCovering(isPreviewing || isShowingFeed)
    }

    /// A feed opened from a tile covers everything, the page behind the sheet
    /// included: that page pauses for the trip and plays again on the return.
    private var isShowingFeed = false

    /// The tapped tile's posts, from it on, as a new vertical feed with the
    /// hero. Falls back to scrolling the feed behind (`onSelectPost`) when the
    /// host did not hand over a way to open one.
    private func openFeed(from tile: Tile) -> Bool {
        guard let openFeedHero, let galleryPost,
              (navigationController ?? self).presentedViewController == nil,
              let post = galleryPost(tile.postID)
        else { return false }
        let ordered = tiles.compactMap { galleryPost($0.postID) }
        guard let start = ordered.firstIndex(where: { $0.id == post.id }) else { return false }
        let stream = Array(ordered[start...])
        let id = tile.postID
        let cover = tileCell(for: id)?.cover
        let origin = SnapFeedHeroOrigin(
            post: post,
            stream: stream,
            // A text post has no picture to fly: it opens with the plain push.
            hasHero: post.kind != .text && cover != nil,
            cover: cover,
            style: .tile,
            frame: { [weak self] space in self?.tileFrame(for: id, in: space) },
            isOnScreen: { [weak self] in
                guard let self else { return false }
                return tileFrame(for: id, in: view) != nil
            },
            setConcealed: { [weak self] concealed in self?.tileCell(for: id)?.setConcealed(concealed) }
        )
        trace("open \(id.rawValue) (\(post.kind)) stream \(stream.prefix(3).map(\.id.rawValue))")
        stopPreview()
        isShowingFeed = true
        refreshCover()
        OverSheetFeedHost.present(over: self, onFinished: { [weak self] in
            self?.isShowingFeed = false
            self?.refreshCover()
        }) { host in
            openFeedHero(stream.map(\.id), host, origin)
        }
        return true
    }

    private func tileCell(for id: PostID) -> SoundSheetTileCell? {
        guard let path = dataSource.indexPath(for: .tile(id)) else { return nil }
        return collectionView.cellForItem(at: path) as? SoundSheetTileCell
    }

    /// The tile's rect in `space` while it is on screen — nil once it has
    /// scrolled out (under the toolbar included), so the hero falls back
    /// instead of flying to nowhere.
    private func tileFrame(for id: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = tileCell(for: id) else { return nil }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard visible.intersects(cell.frame) else { return nil }
        return cell.convert(cell.bounds, to: space)
    }

    // MARK: - Preview

    private func togglePreview() {
        isPreviewing ? stopPreview() : startPreview()
    }

    private func startPreview() {
        guard let url = sound.previewURL else { return }
        if preview == nil {
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            previewEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopPreview(rewinding: true) }
            }
            previewTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 4), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.previewTicked(time.seconds) }
            }
            preview = player
        }
        // ⚠️ `.playback` while it plays: the viewer asked for this sound, and
        // an `.ambient` session would keep it silent on a phone set to silent
        // with nothing on screen to say why. Given back when it stops.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default)
            raisedSessionForPreview = true
        }
        isPreviewing = true
        refreshCover()
        header?.setPlaying(true)
        preview?.play()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func stopPreview(rewinding: Bool = false) {
        guard isPreviewing else { return }
        preview?.pause()
        if rewinding { preview?.seek(to: .zero) }
        if raisedSessionForPreview {
            raisedSessionForPreview = false
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback)
        }
        isPreviewing = false
        header?.setPlaying(false)
        header?.setMeta(Self.meta(duration: sound.duration, posts: tiles.count))
        refreshCover()
    }

    private func previewTicked(_ seconds: Double) {
        guard isPreviewing, seconds.isFinite else { return }
        let total = sound.duration.map { " / \(Self.clock($0))" } ?? ""
        header?.setMeta("\(Self.clock(seconds))\(total)")
    }

    // MARK: - Actions

    private func useSound() {
        guard let onUseSound else { return }
        let sound = sound
        dismiss(animated: true) { onUseSound(sound) }
    }

    private func share() {
        let text = [sound.title ?? "Original sound", sound.artist ?? "@\(authorHandle)"].joined(separator: " — ")
        let activity = UIActivityViewController(activityItems: ["♫ \(text)"], applicationActivities: nil)
        if let shareItem {
            activity.popoverPresentationController?.sourceItem = shareItem
        } else {
            activity.popoverPresentationController?.sourceView = view
        }
        present(activity, animated: true)
    }
}

// MARK: - Detents

extension SoundSheetViewController: UISheetPresentationControllerDelegate {
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
        _ sheet: UISheetPresentationController
    ) {
        detentChanged(to: sheet.selectedDetentIdentifier)
    }

    /// The one place a detent change is acted on — a drag reports it through
    /// the delegate, "View all" does not report it at all. It takes "View all"
    /// out of the grid at large and puts it back (with the grid at its top)
    /// at collapsed, and nothing else: the clip behind plays on at either.
    fileprivate func detentChanged(to identifier: UISheetPresentationController.Detent.Identifier?) {
        let expanded = identifier == .large
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        traceSettledHeight(expanded: expanded)
        guard dataSource != nil else { return }
        dataSource.apply(makeSnapshot(), animatingDifferences: true)
        if !expanded {
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: -collectionView.adjustedContentInset.top),
                animated: true
            )
        }
    }
}

// MARK: - Grid

extension SoundSheetViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .tile(let id):
            // A placeholder leads nowhere yet: its post is still on its way.
            guard let tile = tileByID[id], tile.isLoaded else { return }
            if openFeed(from: tile) { return }
            // Scrolling the feed behind reaches only ITS posts; any other
            // stays put rather than closing the sheet on nothing.
            guard openFeedHero == nil else { return }
            let select = onSelectPost
            dismiss(animated: true) { select?(id) }
        case .more:
            expand()
        case nil:
            break
        }
    }
}
