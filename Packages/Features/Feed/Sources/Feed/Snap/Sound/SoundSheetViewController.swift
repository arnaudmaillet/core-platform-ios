import AVFoundation
import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// The sound a post is set to, opened from the attribution at the foot of
/// the feed: what it is, a listen, the posts set to it, and — in the sheet's
/// native toolbar — "Use this sound" and share.
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ ▔▔                                   │
///  │  ╭────╮  Veridis Quo                 │  the round artwork = play/pause
///  │  │ ▶︎  │  Daft Punk                   │  (it turns while the sound plays)
///  │  ╰────╯  0:30 · 7 posts              │
///  │ ▢♪Original ▢Watching ▢               │  the first row
///  │         View all 7 posts ⌄           │
///  │ ░(Use this sound)░░░░░░░░░░░░░(↑)░░░ │  ← collapsed detent ends here:
///  ├──────────────────────────────────────┤    the toolbar, row 2 under it
///  │ ▢ ▢ ▢                                │  large: the grid, whole
///  └──────────────────────────────────────┘
/// ```
///
/// **PRESENTED INSIDE A NAVIGATION CONTROLLER** (`wrappedInSheet()`), for its
/// toolbar alone — the bar is hidden. The actions are bar items, so they are
/// UIKit's glass, not buttons of ours pinned to the bottom, and the grid
/// scrolls on UNDER them behind the system's scroll-edge effect. Nothing here
/// writes an alpha on that chrome (see memory `native-chrome-uikit-only`).
///
/// **THE COLLAPSED DETENT IS MEASURED, NOT CHOSEN** (`collapsedDetentHeight`):
/// the sound, the grid's first row and "View all", then the toolbar's band —
/// read off the laid-out grid and the view's bottom safe area, first before
/// the sheet has a window and again once it has one.
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

        init(postID: PostID, thumbnailURL: URL?, caption: String?, isCurrent: Bool, isOriginal: Bool = false) {
            self.postID = postID
            self.thumbnailURL = thumbnailURL
            self.caption = caption
            self.isCurrent = isCurrent
            self.isOriginal = isOriginal
        }
    }

    /// The grid in three sections, so the fold has a place of its own: the
    /// first row (under the sound, as its header), "View all" while there is
    /// more to view and the sheet is collapsed, then the rest.
    enum Section: Hashable, Sendable {
        case firstRow, more, rest
    }

    enum Item: Hashable, Sendable {
        case tile(Tile)
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
    private static let topInset: CGFloat = 24
    private static let tileSpacing: CGFloat = 2
    /// Between the fold — "View all", or the first row when there is nothing
    /// more — and the toolbar's band.
    static let foldGap: CGFloat = Spacing.sm

    private let sound: PostSound
    private let authorHandle: String
    private let fallbackArtworkURL: URL?
    private let tiles: [Tile]
    private let imagePipeline: ImagePipeline

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private weak var header: SoundSheetHeaderView?
    private weak var shareItem: UIBarButtonItem?

    /// The collapsed detent's value, once measured (`refreshCollapsedHeight`).
    private(set) var collapsedHeight: CGFloat?
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
        imagePipeline: ImagePipeline
    ) {
        self.sound = sound
        self.authorHandle = authorHandle
        self.fallbackArtworkURL = fallbackArtworkURL
        self.tiles = tiles
        self.imagePipeline = imagePipeline
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
        toolbarItems = makeToolbarItems()
        configureDataSource()
        measureBeforeWindow()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // In a window now: the toolbar's real band is known.
        refreshCollapsedHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A text size change moves the fold; so would a different toolbar.
        refreshCollapsedHeight()
    }

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

    /// "Use this sound" (prominent, leading) and share (trailing) — native bar
    /// items, drawn in UIKit's glass. Without a way to use the sound, share
    /// keeps its trailing place alone.
    private func makeToolbarItems() -> [UIBarButtonItem] {
        let share = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() }
        )
        share.accessibilityLabel = "Share sound"
        shareItem = share
        guard onUseSound != nil else { return [.flexibleSpace(), share] }
        let use = UIBarButtonItem(
            title: "Use this sound",
            primaryAction: UIAction { [weak self] _ in self?.useSound() }
        )
        use.style = .prominent
        use.tintColor = .systemRed
        return [use, .flexibleSpace(), share]
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            switch self?.dataSource?.sectionIdentifier(for: index) ?? .firstRow {
            case .firstRow:
                // Row two follows at the grid's own spacing once "View all"
                // has left (large).
                let section = Self.gridSection(environment, bottom: Self.tileSpacing)
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(140)),
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
                    top: Spacing.xs, leading: Spacing.lg, bottom: Self.foldGap, trailing: Spacing.lg
                )
                return section
            case .rest:
                return Self.gridSection(environment, bottom: Spacing.xl)
            }
        }
    }

    /// Three columns of 3:4 tiles inside the sheet's side margins.
    private static func gridSection(
        _ environment: NSCollectionLayoutEnvironment, bottom: CGFloat
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)
        ))
        let columnWidth = (environment.container.effectiveContentSize.width - 2 * Spacing.lg
            - CGFloat(columns - 1) * tileSpacing) / CGFloat(columns)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1),
                              heightDimension: .absolute((columnWidth * 4 / 3).rounded())),
            repeatingSubitem: item, count: columns
        )
        group.interItemSpacing = .fixed(tileSpacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = tileSpacing
        section.contentInsets = .init(top: 0, leading: Spacing.lg, bottom: bottom, trailing: Spacing.lg)
        return section
    }

    private func configureDataSource() {
        let pipeline = imagePipeline
        let tileRegistration = UICollectionView.CellRegistration<SoundSheetTileCell, Tile> { cell, _, tile in
            cell.configure(tile, pipeline: pipeline)
        }
        let total = tiles.count
        let moreRegistration = UICollectionView.CellRegistration<SoundSheetMoreCell, Item> { [weak self] cell, _, _ in
            cell.configure(title: Self.moreTitle(posts: total))
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
            case .tile(let tile):
                view.dequeueConfiguredReusableCell(using: tileRegistration, for: path, item: tile)
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
        snapshot.appendItems(tiles.prefix(Self.columns).map(Item.tile), toSection: .firstRow)
        let rest = tiles.dropFirst(Self.columns)
        guard !rest.isEmpty else { return snapshot }
        if !isExpanded {
            snapshot.appendSections([.more])
            snapshot.appendItems([.more], toSection: .more)
        }
        snapshot.appendSections([.rest])
        snapshot.appendItems(rest.map(Item.tile), toSection: .rest)
        return snapshot
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

    /// The collapsed detent's value: the sheet down to `foldBottom` (from its
    /// top edge — the sound, the first row, "View all" and the gap under it),
    /// then the toolbar's band, which is the view's bottom safe area less the
    /// window's.
    ///
    /// ⚠️ A custom detent's height EXCLUDES the bottom safe area — the sheet
    /// adds it back (memory `economy-ab-claim-sheet`). The toolbar stands on
    /// that safe area, so what the detent owes it is its band ABOVE it:
    /// counting the whole inset rested the fold 34pt too high.
    static func collapsedDetentHeight(
        foldBottom: CGFloat, bottomSafeArea: CGFloat, windowBottomSafeArea: CGFloat
    ) -> CGFloat {
        (foldBottom + max(0, bottomSafeArea - windowBottomSafeArea)).rounded(.up)
    }

    /// Where the fold ends, in this view's space with the grid at rest: under
    /// "View all" when it is there, under the first row otherwise. Nil at
    /// large, where "View all" has left the grid and the first row is not the
    /// fold — the collapsed height keeps the value measured before.
    private func foldBottom() -> CGFloat? {
        guard !isExpanded, let snapshot = dataSource?.snapshot() else { return nil }
        let fold: (IndexPath, CGFloat)?
        if snapshot.indexOfSection(.more) != nil, let path = dataSource.indexPath(for: .more) {
            fold = (path, Self.foldGap)
        } else if let last = snapshot.itemIdentifiers(inSection: .firstRow).last,
                  let path = dataSource.indexPath(for: last) {
            fold = (path, Spacing.lg)
        } else {
            fold = nil
        }
        guard let (path, gap) = fold,
              let frame = collectionView.collectionViewLayout.layoutAttributesForItem(at: path)?.frame
        else { return nil }
        return collectionView.adjustedContentInset.top + frame.maxY + gap
    }

    /// Before the sheet has a window — `viewDidLoad`, during `present` — so
    /// it rises at the right height: the grid laid out at the PRESENTER's
    /// window width, and the toolbar's band as the bar says it would be.
    private func measureBeforeWindow() {
        guard let window = presentingViewController?.view.window, window.bounds.width > 0 else { return }
        view.frame = CGRect(origin: .zero, size: window.bounds.size)
        view.layoutIfNeeded()
        guard let fold = foldBottom() else { return }
        let toolbar = navigationController?.toolbar
        let band = toolbar?.sizeThatFits(CGSize(width: window.bounds.width, height: 0)).height ?? 0
        collapsedHeight = Self.collapsedDetentHeight(
            foldBottom: fold, bottomSafeArea: band, windowBottomSafeArea: 0
        )
        trace("before window: fold \(fold) band \(band)")
    }

    /// From the real layout, in the window: re-measures, and moves the detent
    /// only when the value changed.
    ///
    /// ⚠️ NOT during a transition: a sheet on its way in or out is where its
    /// safe area is least settled, and a detent invalidated mid-dismissal
    /// would pull the sheet back.
    private func refreshCollapsedHeight() {
        guard let window = view.window, !isSheetBeingDismissed,
              navigationController?.transitionCoordinator?.isInteractive != true,
              let fold = foldBottom()
        else { return }
        let height = Self.collapsedDetentHeight(
            foldBottom: fold,
            bottomSafeArea: view.safeAreaInsets.bottom,
            windowBottomSafeArea: window.safeAreaInsets.bottom
        )
        if let collapsedHeight, abs(collapsedHeight - height) < 0.5 { return }
        trace("in window: fold \(fold) safe \(view.safeAreaInsets.bottom) window \(window.safeAreaInsets.bottom) → \(height) (was \(collapsedHeight.map { "\($0)" } ?? "nil"))")
        collapsedHeight = height
        // Only a sheet that is up has detents to move.
        guard let navigation = navigationController, navigation.presentingViewController != nil,
              let sheet = navigation.sheetPresentationController else { return }
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sound-sheet-trace") {
            print("[sound-sheet] \(message())")
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

    /// The grid's posts, in order, and which of them is the ORIGINAL:
    /// 1. the post the sound was first published with — only when it is a
    ///    MEDIA post this grid can show (a text post's words are no "original"
    ///    of a sound, and a tile that leads nowhere is not offered);
    /// 2. the post the sheet was opened from;
    /// 3. the others the sound is set to, as the provider ranks them, among
    ///    those this grid can show.
    /// Each post once.
    static func gridPostIDs(
        current: PostID,
        original: PostID?,
        using: [PostID],
        canShow: (PostID) -> Bool,
        isMedia: (PostID) -> Bool
    ) -> (ids: [PostID], original: PostID?) {
        let original = original.flatMap { canShow($0) && isMedia($0) ? $0 : nil }
        var ids: [PostID] = []
        var seen = Set<PostID>()
        for id in [original, current].compactMap({ $0 }) + using.filter(canShow) where seen.insert(id).inserted {
            ids.append(id)
        }
        return (ids, original)
    }

    // MARK: - Expansion

    /// "View all": up to the whole grid.
    private func expand() {
        guard let sheet = navigationController?.sheetPresentationController, !isExpanded else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        // A programmatic change is not reported to the delegate.
        detentChanged(to: .large)
    }

    #if DEBUG
    /// `-snap-sound-sheet large`: "View all", without the tap.
    func debugExpand() { expand() }
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
        guard let tile = tiles.first(where: { $0.postID == id }),
              let path = dataSource.indexPath(for: .tile(tile)) else { return nil }
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
        case .tile(let tile):
            if openFeed(from: tile) { return }
            let select = onSelectPost
            dismiss(animated: true) { select?(tile.postID) }
        case .more:
            expand()
        case nil:
            break
        }
    }
}
