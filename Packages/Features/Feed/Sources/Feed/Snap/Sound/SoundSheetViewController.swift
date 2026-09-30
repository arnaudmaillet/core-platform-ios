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
/// the feed: what it is, a listen, the posts set to it in one or two
/// sections, a close button in the sheet's navigation bar and — in its native
/// toolbar — "Use this sound", save and share.
///
/// ```
///  ┌──────────────────────────────────────┐
///  │  ╭────╮          ▔▔                  │  `headerInset` from the top, as
///  │  │ ▶︎  │  Veridis Quo Veridis…   (✕)  │  from the side; the round
///  │  │    │  Daft Punk                   │  artwork = play/pause; ✕ = the
///  │  ╰────╯  0:30 · 23 posts             │  bar's close item
///  │                                      │  the section gap under it
///  │Popular ›                             │  ONLY when the backend gives one:
///  │▢♪Original ▢Watching ▢ ▢┆→            │  a row; its title + chevron push
///  │                                      │  the section gap
///  │Recent                                │  ← faint at collapsed, with the
///  │▢ ▢ ▢                                 │  ← top of its first row, above…
///  │(   Use this sound         )(🔖)(↑)   │  ← …the toolbar: collapsed ends
///  ├──────────────────────────────────────┤
///  │▢ ▢ ▢                                 │  every post the row does not
///  │▢ ▢ ▢                                 │  show, newest first: a grid
///  └──────────────────────────────────────┘  fading in as the sheet grows
/// ```
/// Without Popular, "Recent" stands right under the sound and collapsed shows
/// its title and its WHOLE first row, just above the toolbar; the rows after
/// it are faint behind the toolbar and fade in as the sheet grows
/// (`foldBottom`, `revealLine`).
///
/// **ONE OR TWO SECTIONS** (`SoundSheetSections`): the POPULAR posts (the
/// original first, then the post watched) in a row — only when the backend
/// gives the sound a Popular section, which it does from a number of posts —
/// then every other post, most RECENT first, in a grid. A post shows once.
/// Popular's title and chevron PUSH its whole ranking as a grid INSIDE the
/// sheet (`SoundSheetGalleryViewController`), at whatever detent the sheet
/// stands — the push never moves the sheet.
///
/// **THE APP'S ONE SECTION GAP** (`Spacing.section`, asked for 2026-09-30:
/// "the interface must breathe", the same everywhere): from the sound to the
/// first title, and from the Popular row to "Recent", each title's LINE
/// stands `Spacing.section` under what is above it and `Spacing.sectionTitle`
/// over its posts — as For You's rows and its pushed lists do. The title bars
/// centre their line (`SectionTitleView.barHeight`), so the gap the
/// layout adds above a bar is the section gap less the bar's own air
/// (`DetentMetrics.sectionGap`). The SOUND also has room of its own
/// (`headerInset`): above it and on its leading side.
///
/// **THE POSTS SCROLL ONLY AT THE FULLEST DETENT** (asked for, 2026-09-30:
/// a sound of one post scrolled inside its collapsed sheet, the sound sliding
/// up under the ✕). Below it, a drag on the posts GROWS the sheet — UIKit's
/// own `prefersScrollingExpandsWhenScrolledToEdge`, from posts resting at
/// their top (`restAtTop`, on appearing) — and a content that fits its sheet
/// does not bounce at all (`alwaysBounceVertical` off): the drag is the
/// sheet's. The bounce was the bug: a sound of a few posts at its fitted
/// detent — the fullest, so UIKit let the list have the drag — slid up under
/// the ✕. Nothing holds the offset by hand: measured on iOS 27 with real
/// drags (1, 7 and 24 posts), UIKit's own hand-over never scrolled the posts
/// below the fullest detent (`-sound-sheet-trace` logs any `scrolled:`).
///
/// **THE CONTENT STARTS BEHIND THE NAVIGATION BAR**, not under it: the bar
/// holds only the close item at its trailing end, and the sound's header sits
/// where it always did, under the grabber, the close button floating over its
/// trailing corner — the header's lines stop short of it and truncate
/// (`SoundSheetHeaderView.closeClearance`). The collection view takes no
/// inset from the bar (`contentInsetAdjustmentBehavior = .never`, the
/// toolbar's band given back by hand) and hides its top edge effect, as every
/// list under a header does (`prefersClearTopEdge`): no blur over the sound.
///
/// **ONE GUTTER** (`gutter`) is the sheet's side margin, the gap between tiles
/// and the gap between rows: titles and tiles share one left edge. The sound
/// stands further in (`headerInset`, twice the gutter), the one block with
/// room around it. Every tile wears the same FIXED corner,
/// never one concentric with the sheet's: the posts scroll past the screen's
/// corners at large (`SoundSheetTileCell.cornerRadius`).
///
/// **PRESENTED INSIDE A NAVIGATION CONTROLLER** (`wrappedInSheet()`), for its
/// bars and for Popular's push. The bar shows on both screens: the close item
/// here, UIKit's back button and the title on the pushed one. The actions
/// are bar items, so they are UIKit's glass, not buttons of ours pinned to the
/// bottom, and the posts scroll on UNDER them behind the system's scroll-edge
/// effect. Nothing here writes an alpha on that chrome (see memory
/// `native-chrome-uikit-only`).
///
/// **BOTH DETENTS ARE COMPUTED, NEVER MEASURED OFF THE LIVE SHEET.**
/// - COLLAPSED (`collapsedDetentHeight`): the sound's header, the "Popular"
///   title and its row when there is one, then the "Recent" title and the
///   top of its first row — or, without Popular, the "Recent" title and its
///   whole first row — pure arithmetic on the sheet's WIDTH, the text size
///   and whether Popular is there, plus the toolbar's band; nothing that
///   depends on how tall the sheet is right now, nor on how many posts there
///   are.
/// - EXPANDED (`fittedDetentHeight`): the whole content — the same terms, the
///   "Recent" grid's rows counted from its posts — when that is shorter than
///   the screen, so a sound with a few posts rises only as far as its posts
///   go (asked for, 2026-09-30); UIKit's large detent otherwise
///   (`expandedDetentIdentifier`).
/// So each answer is the same at every visit, and the detents are asked
/// again (`invalidateDetents`) only when an INPUT changes: the text size, the
/// width, the band once known, Popular coming or going (posts that could not
/// be loaded) — and, for the expanded one, the post count.
///
/// ⚠️ **NEVER FROM A LAYOUT CALLBACK.** #296 re-measured the fold in
/// `viewDidLayoutSubviews` and invalidated the detents inside `animateChanges`
/// when it moved. A drag from the grabber lays the sheet out on every frame,
/// the fold read there moved with the sheet, and each re-resolve laid the
/// sheet out again: a stack overflow (`EXC_BAD_ACCESS` code 2 in
/// `invalidateDetents`), and between crashes a collapsed height that drifted
/// from one visit to the next. The one thing a layout pass does here is WAKE
/// the reveal (below), which writes an opacity and nothing else.
///
/// **THE REST FADES IN AS THE SHEET GROWS** (`SoundSheetReveal`): at the
/// collapsed detent what it is for shows whole, and what lies under it is
/// FAINT — there, and saying there is more below, but not yet read — and
/// follows the sheet's DRAWN height — the finger, then the spring — to whole
/// at 60% of the way to the expanded detent. What is faint cannot be tapped.
/// - With Popular: the sound and the row show whole; the "Recent" title and
///   its grid are faint — the title fades WITH its grid (asked for,
///   2026-09-30): it is part of what the sheet grows into.
/// - Without it: the sound, the "Recent" title and the grid's FIRST ROW show
///   whole, just above the toolbar; the rows after it — behind the toolbar's
///   glass at collapsed — are faint (asked for, 2026-09-30: the same
///   mechanism as "Recent" under Popular).
///
/// **THE FEED STAYS ALIVE UNDER THE SHEET, AT EVERY DETENT.** Neither detent
/// pauses the clip behind: a detent is where the sheet sits, not a choice to
/// stop listening. (Large paused it for a while; the viewer asked for the post
/// to keep playing, 2026-09-28.)
///
/// **FROM EXPANDED, A DRAG DOWN COMES BACK TO COLLAPSED**; a second one
/// closes.
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
        /// The post the sound was first published with — first in "Popular".
        let isOriginal: Bool
        /// Whether the post itself is known yet. The sheet lists EVERY post set
        /// to the sound, most of them outside the feed behind: those arrive as
        /// placeholders — so the sheet rises at once, at its final size — and
        /// are filled in by `update(sections:tiles:)` once the repository has
        /// them.
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

    /// The sound's head, then the posts' sections in order.
    enum Section: Hashable, Sendable {
        case sound
        case posts(SoundSheetSection.Kind)
    }

    /// ⚠️ A tile is identified by its POST IN ITS SECTION, not by its
    /// content: a placeholder filled in is the same item reconfigured. A post
    /// shows in one section (`SoundSheetSections`), but the section it is in
    /// is what a tap and the hero look it up by; and a post the row lets go
    /// (one that could not be loaded dealt the sections again) comes back in
    /// "Recent" as a new item, not a moved one.
    enum Item: Hashable, Sendable {
        case sound
        case tile(PostID, SoundSheetSection.Kind)
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
    /// The tiles' posts as the sheet knows them — what the hero flies and the
    /// new feed is seeded with.
    var galleryPost: ((PostID) -> GalleryPost?)?
    /// "Use this sound"; the sheet is already on its way out. Nil leaves the
    /// toolbar with share alone.
    var onUseSound: ((PostSound) -> Void)? {
        didSet { if isViewLoaded { toolbarItems = makeToolbarItems(primary: true) } }
    }
    /// The sheet is gone, however it went.
    var onDismissed: (() -> Void)?

    static let collapsedDetent = UISheetPresentationController.Detent.Identifier("sound.collapsed")
    /// The expanded detent when the content is shorter than the screen: as
    /// tall as the content (`fittedDetentHeight`). Taller content expands to
    /// UIKit's `.large` instead.
    static let fittedDetent = UISheetPresentationController.Detent.Identifier("sound.fitted")
    static let columns = 3
    /// THE gutter: the sheet's side margin, between tiles, between rows — the
    /// Upload picker's rule (`Spacing.sm` both ways), so the posts read as
    /// tiles on the sheet rather than a wall with a frame around it.
    static let gutter: CGFloat = Spacing.sm
    /// The room around the sound's header — above it, on its leading side
    /// (and trailing, where the ✕ stands anyway) and under it: twice the
    /// gutter (asked for, 2026-09-30: "more space at the top, left and bottom
    /// of the audio info"). Top equals left, as it did at one gutter.
    static let headerInset: CGFloat = 2 * gutter
    /// Above the sound: its header's inset, so it stands as far from the
    /// sheet's top edge as from its leading one. The grabber is centred,
    /// clear of the round artwork.
    static let topInset: CGFloat = headerInset
    /// Under the "Recent" grid's last row — the gutter, as everywhere around
    /// a tile — before the toolbar's band.
    static let contentBottom: CGFloat = gutter
    /// How much of the "Recent" grid's first row the collapsed detent shows
    /// above the toolbar, as a fraction of a tile's height, UNDER A POPULAR
    /// ROW: enough to read as tiles, faint, under their faint title (asked
    /// for, 2026-09-30: "a bit more of the sheet at collapsed").
    static let recentPeek: CGFloat = 0.25
    /// Tiles across a row's width: three whole and the fourth peeking — the
    /// peek is what says the row scrolls.
    static let rowTilesAcross: CGFloat = 3.4

    private let sound: PostSound
    private let authorHandle: String
    private let fallbackArtworkURL: URL?
    private(set) var sections: [SoundSheetSection]
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
    /// Every bookmark item made — this screen's and a pushed section's — so a
    /// save made on one shows on the other.
    private let bookmarkItems = NSHashTable<UIBarButtonItem>.weakObjects()
    /// The navigation bar's one item: closes the sheet.
    private(set) weak var closeItem: UIBarButtonItem?
    /// The section a title's chevron pushed, while it is up.
    private(set) weak var pushedGallery: SoundSheetGalleryViewController?

    /// What the detents are made of, and their values (`collapsedHeight`,
    /// `fittedHeight`) — set only by `refreshDetentMetrics` and
    /// `refreshFittedHeight`, never by a layout pass.
    private(set) var detentMetrics: DetentMetrics?
    private(set) var collapsedHeight: CGFloat?
    /// The whole content's height, the toolbar's band included: the expanded
    /// detent when it is shorter than large.
    private(set) var fittedHeight: CGFloat?
    /// Whether the expanded detent is the fitted one — the content is shorter
    /// than the screen — rather than UIKit's large.
    private(set) var expandsToFit = false
    /// The large detent's value, as the sheet's own resolution states it
    /// (`maximumDetentValue`).
    private var largeHeight: CGFloat?
    /// How often the detents were re-asked — what a test reads to prove that
    /// laying the sheet out never does it.
    private(set) var detentInvalidations = 0
    /// The sheet's width, the one input of the grid's geometry.
    private var sheetWidth: CGFloat?
    /// The toolbar's band above the home indicator, as the sheet's safe area
    /// last reported it (`viewIsAppearing`). Kept across sheets: it is the
    /// bar's, not this sound's, so the second sheet rises at the exact height.
    private static var measuredToolbarBand: CGFloat?
    private var headerHeightCache: (key: String, height: CGFloat)?
    /// At the expanded detent — the fitted one or large.
    private(set) var isExpanded = false
    /// What lies under the Popular row, fading with the sheet's height.
    let reveal = SoundSheetReveal()
    private var lastTracedReveal: Int?
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
        sections: [SoundSheetSection],
        tiles: [Tile],
        imagePipeline: ImagePipeline,
        savedSounds: SavedSoundStore = SavedSoundStore()
    ) {
        self.sound = sound
        self.authorHandle = authorHandle
        self.fallbackArtworkURL = fallbackArtworkURL
        self.sections = sections
        self.tiles = tiles
        self.tileByID = Dictionary(tiles.map { ($0.postID, $0) }, uniquingKeysWith: { first, _ in first })
        self.imagePipeline = imagePipeline
        self.savedSounds = savedSounds
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet as it is presented: this screen as the root of a navigation
    /// controller that shows its bar (the close item) and its TOOLBAR (the
    /// actions), set up as a page sheet with the collapsed and expanded
    /// detents.
    ///
    /// ⚠️ The sheet's configuration lives on the NAVIGATION controller's
    /// presentation — the one presented — and this screen is its delegate.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.setToolbarHidden(false, animated: false)
        navigation.modalPresentationStyle = .pageSheet
        // A pushed section's back button is the bare chevron: this screen has
        // no title to lend it.
        navigationItem.backButtonDisplayMode = .minimal
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = makeDetents()
            sheet.selectedDetentIdentifier = Self.collapsedDetent
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.delegate = self
        }
        return navigation
    }

    /// Collapsed, then expanded: fitted to the content when it is shorter
    /// than the screen (`expandsToFit`), UIKit's large otherwise — large
    /// itself rather than a custom detent at the maximum, so a sheet of many
    /// posts expands exactly as it always did.
    ///
    /// ⚠️ EACH RESOLVER READS A STORED ANSWER, NOTHING ELSE: a resolver that
    /// lays out or loads a view runs inside the sheet's own resolution
    /// (memory `upload-media-picker`). Keeping the large value it is handed
    /// is a plain store — it moves nothing.
    private func makeDetents() -> [UISheetPresentationController.Detent] {
        let collapsed = UISheetPresentationController.Detent.custom(identifier: Self.collapsedDetent) {
            [weak self] context in
            self?.largeHeight = context.maximumDetentValue
            return min(self?.collapsedHeight ?? 420, context.maximumDetentValue)
        }
        guard expandsToFit else { return [collapsed, .large()] }
        let fitted = UISheetPresentationController.Detent.custom(identifier: Self.fittedDetent) {
            [weak self] context in
            self?.largeHeight = context.maximumDetentValue
            return min(self?.fittedHeight ?? context.maximumDetentValue, context.maximumDetentValue)
        }
        return [collapsed, fitted]
    }

    /// The expanded detent as the detents stand now.
    var expandedDetentIdentifier: UISheetPresentationController.Detent.Identifier {
        expandsToFit ? Self.fittedDetent : .large
    }

    static func isExpanded(_ identifier: UISheetPresentationController.Detent.Identifier?) -> Bool {
        identifier == .large || identifier == fittedDetent
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ CLEAR, so the sheet's own glass is the surface at the collapsed
        // detent — a painted background makes it opaque at every height.
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        // ⚠️ NO BOUNCE OF ITS OWN: a content that fits its sheet (a sound of
        // a few posts at its fitted detent) has nowhere to scroll, and a drag
        // on it is the sheet's — up, nothing; down, back to collapsed. With
        // the bounce on, the list slid up under the ✕ instead (see the type's
        // note on scrolling).
        collectionView.alwaysBounceVertical = false
        collectionView.delegate = self
        // ⚠️ NO INSET FROM THE BARS: the sound starts BEHIND the navigation
        // bar, `topInset` under the grabber as it did when the bar was
        // hidden — an automatic inset would push it under the close item's
        // band. The toolbar's band is given back by hand
        // (`viewSafeAreaInsetsDidChange`).
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = Self.topInset
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        // To both edges, UNDER the bars: the posts go on behind their glass.
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Both bars' scroll-edge effects read THIS scroll view — the top one
        // hidden: the sound rests under the bar, and a blur there would veil
        // it (memory `bare-headers-no-top-blur`).
        setContentScrollView(collectionView, for: [.top, .bottom])
        collectionView.prefersClearTopEdge()
        navigationItem.rightBarButtonItem = makeCloseItem()
        // Before the first layout and before the sheet asks its detent: the
        // presenter's window gives the width the sheet will have.
        sheetWidth = presentingViewController?.view.window?.bounds.width ?? view.bounds.width
        refreshDetentMetrics(reason: "load")
        toolbarItems = makeToolbarItems(primary: true)
        configureDataSource()
        reveal.attach(to: view)
        reveal.measure = { [weak self] in self?.measuredReveal() }
        reveal.onChange = { [weak self] progress in self?.traceReveal(progress) }
        // A text size change moves the header and so the fold: an input.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: SoundSheetViewController, _: UITraitCollection) in
            controller.refreshDetentMetrics(reason: "text size")
        }
    }

    /// The toolbar's band (and the home indicator's), which the collection
    /// view no longer takes by itself: the last posts scroll clear of the
    /// bar, and its indicator stays between the bars. An inset and nothing
    /// else — no detent is read or asked here (see the type's note).
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let safeArea = view.safeAreaInsets
        guard collectionView.contentInset.bottom != safeArea.bottom
            || collectionView.verticalScrollIndicatorInsets.top != safeArea.top else { return }
        collectionView.contentInset.bottom = safeArea.bottom
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: safeArea.top, left: 0, bottom: safeArea.bottom, right: 0
        )
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
            if Self.isPlausibleToolbarBand(band, viewHeight: view.bounds.height) {
                Self.measuredToolbarBand = band
            }
        }
        refreshDetentMetrics(reason: "appearing")
        // Below the fullest detent the posts rest at their TOP — the edge
        // UIKit's scroll-to-expand starts from. Stated, not assumed: an
        // offset left a few points in (the top inset set after the offset)
        // would be a list already scrolled, which a drag scrolls on.
        if !isAtFullestDetent { Self.restAtTop(collectionView) }
        // A pushed section left the sheet where the viewer took it.
        reveal.set(isExpanded ? 1 : 0)
        updateRevealLine()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reveal.wake()
        #if DEBUG
        debugOpenTileIfRequested()
        #endif
    }

    /// ⚠️ ONLY WAKES THE REVEAL AND PLACES ITS LINE — never a detent, never a
    /// measure the detents read (see the type's note). A drag lays the sheet
    /// out on every frame, and the release sets its final frame: either is
    /// the sheet moving, and the reveal watches the drawn height until it is
    /// still. Neither call lays anything out.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateRevealLine()
        reveal.wake()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // A new width is a new grid — an input, not a layout pass.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, view.bounds.width > 0 else { return }
            sheetWidth = view.bounds.width
            refreshDetentMetrics(reason: "size")
        }
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
        // Off screen (a section pushed over it, or gone): nothing to watch.
        reveal.sleep()
        guard isSheetBeingDismissed else { return }
        setCovering(false)
        onDismissed?()
    }

    // MARK: - Close

    /// The bar's close item: UIKit's own `.close` glyph in its glass circle,
    /// at the bar's trailing end, over the header's trailing corner.
    private func makeCloseItem() -> UIBarButtonItem {
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })
        close.accessibilityIdentifier = "sound.close"
        closeItem = close
        return close
    }

    /// Down and gone, however high the sheet stands — the same dismissal as a
    /// swipe down: the preview stops and the feed behind is uncovered on the
    /// way out (`viewWillDisappear`, `viewDidDisappear`).
    func close() {
        (navigationController ?? self).dismiss(animated: true)
    }

    // MARK: - Toolbar

    /// `[Use this sound ——————][🔖][↑]`: "Use this sound" takes every point
    /// the two trailing bubbles leave; save and share are a bubble EACH — the
    /// zero-width fixed spaces are what keep UIKit from joining them in one
    /// shared glass platter. Without a way to use the sound, save and share
    /// keep the trailing edge.
    ///
    /// Made afresh for each screen that shows the toolbar — this one
    /// (`primary`, the items a test reads) and a pushed section: a bar item
    /// lives in one bar.
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
    private func makeToolbarItems(primary: Bool) -> [UIBarButtonItem] {
        let share = UIBarButtonItem(systemItem: .action)
        share.primaryAction = UIAction { [weak self, weak share] _ in self?.share(from: share) }
        share.accessibilityLabel = "Share sound"
        // ⚠️ AN ACTION WITHOUT AN IMAGE, the glyph on the ITEM: an action's
        // image is re-applied to its item when it fires, and put the
        // "bookmark" outline back over the fill just set (measured: the fill
        // flashed during the press and was gone at rest).
        let bookmark = UIBarButtonItem(primaryAction: UIAction { [weak self] _ in self?.toggleSaved() })
        bookmarkItems.add(bookmark)
        if primary {
            shareItem = share
            bookmarkItem = bookmark
        }
        refreshBookmark()
        let trailing: [UIBarButtonItem] = [bookmark, .fixedSpace(), share]
        guard onUseSound != nil else { return [.flexibleSpace()] + trailing }
        let use = UIBarButtonItem(customView: makeUseButton())
        use.hidesSharedBackground = true
        if primary { useItem = use }
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
        for item in bookmarkItems.allObjects {
            item.image = UIImage(systemName: bookmarkSymbol)
            // The label follows the state, like the feed's: "Save" and "Saved"
            // are different offers to a reader who cannot see the fill.
            item.accessibilityLabel = saved ? "Sound saved" : "Save sound"
        }
    }

    #if DEBUG
    /// Presses the save item, as a tap would.
    func debugToggleSaved() { toggleSaved() }
    #endif

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            // ⚠️ Every height and gap is ABSOLUTE, at the value the detents
            // were computed with — a self-sizing header settles after an
            // estimate, and the fold would move with it. The gap above a
            // title is the bottom inset of the section before it.
            let metrics = self?.detentMetrics
            let gap = metrics?.sectionGap ?? 18
            switch self?.dataSource?.sectionIdentifier(for: index) ?? .sound {
            case .sound:
                return Self.soundSection(height: metrics?.headerHeight ?? 112, bottom: gap)
            case .posts(let kind):
                let section = kind.isRow
                    ? Self.rowSection(environment, bottom: gap)
                    : Self.gridSection(environment, bottom: Self.contentBottom)
                section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(metrics?.sectionHeaderHeight ?? 44)
                    ),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
                )]
                return section
            }
        }
    }

    /// The sound's head, `headerInset` in from the sides, and `bottom` — the
    /// section gap — under it.
    private static func soundSection(height: CGFloat, bottom: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
        let section = NSCollectionLayoutSection(
            group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        )
        // Its top inset is the collection view's (`topInset`).
        section.contentInsets = .init(top: 0, leading: headerInset, bottom: bottom, trailing: headerInset)
        return section
    }

    /// A horizontal row of 3:4 tiles, one gutter apart, three and a peek
    /// across; it snaps to a tile's leading edge. `bottom` — the section gap —
    /// before the "Recent" title.
    private static func rowSection(
        _ environment: NSCollectionLayoutEnvironment, bottom: CGFloat
    ) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(rowTileWidth(width: width)),
            heightDimension: .absolute(rowTileHeight(width: width))
        )
        let section = NSCollectionLayoutSection(
            group: .horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        )
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = gutter
        section.contentInsets = .init(top: 0, leading: gutter, bottom: bottom, trailing: gutter)
        return section
    }

    /// Three columns of 3:4 tiles, one gutter from the sheet's sides and from
    /// each other — the "Recent" grid, and Popular's pushed gallery.
    static func gridSection(
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

    /// A grid tile's height on a sheet `width` wide: three columns and four
    /// gutters across, each tile 3:4.
    static func tileHeight(width: CGFloat) -> CGFloat {
        let column = (width - CGFloat(columns + 1) * gutter) / CGFloat(columns)
        return (max(0, column) * 4 / 3).rounded()
    }

    /// A row tile's width on a sheet `width` wide: a gutter at the leading
    /// edge and between tiles, `rowTilesAcross` tiles across what is left.
    static func rowTileWidth(width: CGFloat) -> CGFloat {
        (max(0, width - 4 * gutter) / rowTilesAcross).rounded(.down)
    }

    /// A row tile's height: 3:4. What the rows lay out AND what the collapsed
    /// detent counts — one function, so they cannot disagree.
    static func rowTileHeight(width: CGFloat) -> CGFloat {
        (rowTileWidth(width: width) * 4 / 3).rounded()
    }

    private func configureDataSource() {
        let pipeline = imagePipeline
        let tileRegistration = UICollectionView.CellRegistration<SoundSheetTileCell, PostID> {
            [weak self] cell, _, id in
            guard let tile = self?.tileByID[id] else { return }
            cell.configure(tile, pipeline: pipeline)
        }
        let soundRegistration = UICollectionView.CellRegistration<SoundSheetHeaderCell, Item> {
            [weak self] cell, _, _ in
            self?.configure(cell.header)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionTitleSupplementaryView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, path in
            guard let self, case .posts(let kind) = dataSource.sectionIdentifier(for: path.section),
                  let section = sections.first(where: { $0.kind == kind })
            else { return }
            Self.configure(header, for: section)
            header.onTap = { [weak self] in self?.showSection(kind) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, item in
            switch item {
            case .sound:
                view.dequeueConfiguredReusableCell(using: soundRegistration, for: path, item: item)
            case .tile(let id, _):
                view.dequeueConfiguredReusableCell(using: tileRegistration, for: path, item: id)
            }
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: path)
        }
        dataSource.apply(makeSnapshot(), animatingDifferences: false)
    }

    /// The sound, then each section with posts to show — a post in both
    /// sections is two items.
    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Section, Item> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.sound])
        snapshot.appendItems([.sound], toSection: .sound)
        for section in sections {
            let ids = section.ids.filter { tileByID[$0] != nil }
            guard !ids.isEmpty else { continue }
            snapshot.appendSections([.posts(section.kind)])
            snapshot.appendItems(ids.map { .tile($0, section.kind) }, toSection: .posts(section.kind))
        }
        return snapshot
    }

    /// The posts as now known: placeholders filled in, a post that could not
    /// be loaded gone, the sections re-dealt around it. Tiles whose content
    /// changed are reconfigured in place — on the sheet and in a pushed
    /// section — and the header's count follows. The collapsed detent does
    /// not move — it counts no posts — unless the Popular row came or went
    /// (`SoundSheetSections`: a row left showing every post goes). The
    /// expanded one follows the "Recent" grid's rows when it fits the content
    /// (`refreshFittedHeight`) — an input changing, never a layout pass.
    func update(sections newSections: [SoundSheetSection], tiles newTiles: [Tile]) {
        let changed = Set(newTiles.filter { tileByID[$0.postID] != nil && tileByID[$0.postID] != $0 }.map(\.postID))
        sections = newSections
        tiles = newTiles
        tileByID = Dictionary(newTiles.map { ($0.postID, $0) }, uniquingKeysWith: { first, _ in first })
        guard dataSource != nil else { return }
        var snapshot = makeSnapshot()
        // Every item of a changed post: in the row, in the grid, or both.
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            if case .tile(let id, _) = $0 { changed.contains(id) } else { false }
        })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        refreshDetentMetrics(reason: "posts")
        // A section's chevron follows what it now holds — its head
        // reconfigured where it stands, not its section reloaded (which
        // would re-dequeue every tile under it, pictures blinking).
        for path in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            guard let head = collectionView.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: path
            ) as? SectionTitleSupplementaryView,
                case .posts(let kind) = dataSource.sectionIdentifier(for: path.section),
                let section = newSections.first(where: { $0.kind == kind })
            else { continue }
            Self.configure(head, for: section)
        }
        if !isPreviewing { header?.setMeta(Self.meta(duration: sound.duration, posts: tiles.count)) }
        if let gallery = pushedGallery {
            let ids = newSections.first { $0.kind == gallery.kind }?.all.filter { tileByID[$0] != nil } ?? []
            gallery.update(ids: ids, reconfiguring: Array(changed))
        }
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

    // MARK: - Detents

    /// Everything the detents are made of. Each is an INPUT — the sheet's
    /// width, the header, a section title and the gap above one at the text
    /// size, the toolbar's band, whether the backend gave a Popular row — and
    /// none depends on how tall the sheet is. The collapsed detent counts no
    /// posts; the fitted one adds the "Recent" grid's post count.
    struct DetentMetrics: Equatable {
        var width: CGFloat
        var headerHeight: CGFloat
        var sectionHeaderHeight: CGFloat
        /// The space above a section's title bar — under the sound, under the
        /// Popular row: `Spacing.section` to the title's line, less the bar's
        /// own air (`SectionTitleView.gapAbove`).
        var sectionGap: CGFloat
        var toolbarBand: CGFloat
        /// Whether the Popular row stands between the sound and "Recent".
        var hasPopular: Bool
    }

    /// The collapsed detent's value: the fold (`foldBottom`), then the
    /// toolbar's band.
    ///
    /// ⚠️ A custom detent's height EXCLUDES the bottom safe area — the sheet
    /// adds it back (memory `economy-ab-claim-sheet`). The toolbar stands on
    /// that safe area, so what the detent owes it is its band ABOVE it:
    /// counting the whole inset rested the fold 34pt too high.
    static func collapsedDetentHeight(_ metrics: DetentMetrics) -> CGFloat {
        (foldBottom(metrics) + metrics.toolbarBand).rounded(.up)
    }

    /// Where the fold ends, from the sheet's top edge, with the posts at
    /// rest — the inset under the grabber, then, in content coordinates:
    /// - with Popular: the sound, the "Popular" title and its row, then the
    ///   "Recent" title WHOLE and the top of its first row
    ///   (`recentPeekHeight`), both faint (`SoundSheetReveal`) — a glimpse of
    ///   what lies below, which is what says the sheet grows;
    /// - without: the sound, the "Recent" title and its WHOLE first row and
    ///   the gutter under it — the fold is where the second row starts, so
    ///   that row and the next go on faint behind the toolbar's glass (asked
    ///   for, 2026-09-30).
    /// The layout is built from the same numbers (`rowTileHeight`,
    /// `tileHeight`, the absolute heights and gaps).
    ///
    /// The fold counts no posts, so the collapsed height is the same for
    /// every sound of one shape at a width and text size — "Recent" always
    /// has a first row (`SoundSheetSections`: it is never empty).
    static func foldBottom(_ metrics: DetentMetrics) -> CGFloat {
        guard metrics.hasPopular else { return topInset + revealLine(metrics) + gutter }
        return topInset + recentTitleTop(metrics) + metrics.sectionHeaderHeight
            + recentPeekHeight(width: metrics.width)
    }

    /// The part of the "Recent" grid's first row the collapsed detent shows
    /// under a Popular row: a glimpse.
    static func recentPeekHeight(width: CGFloat) -> CGFloat {
        (tileHeight(width: width) * recentPeek).rounded()
    }

    /// The sound's foot in CONTENT coordinates (the sound starts at 0): its
    /// header, then the section gap under it — where the first section's
    /// title bar starts.
    static func soundBottom(_ metrics: DetentMetrics) -> CGFloat {
        metrics.headerHeight + metrics.sectionGap
    }

    /// The Popular row's foot in CONTENT coordinates — the sound's when there
    /// is no row.
    static func popularRowBottom(_ metrics: DetentMetrics) -> CGFloat {
        guard metrics.hasPopular else { return soundBottom(metrics) }
        return soundBottom(metrics) + metrics.sectionHeaderHeight + rowTileHeight(width: metrics.width)
    }

    /// The "Recent" title's top in CONTENT coordinates: the section gap
    /// under the row's foot, or on the sound's gap when there is no row.
    static func recentTitleTop(_ metrics: DetentMetrics) -> CGFloat {
        guard metrics.hasPopular else { return soundBottom(metrics) }
        return popularRowBottom(metrics) + metrics.sectionGap
    }

    /// Where the reveal's always-shown part ends, in CONTENT coordinates:
    /// - with Popular, the "Recent" title's TOP — the title fades with its
    ///   grid, as one;
    /// - without, the FOOT of the grid's first row — the title and that row
    ///   are what the collapsed sheet is for; the rows after it fade.
    static func revealLine(_ metrics: DetentMetrics) -> CGFloat {
        guard metrics.hasPopular else {
            return recentTitleTop(metrics) + metrics.sectionHeaderHeight + tileHeight(width: metrics.width)
        }
        return recentTitleTop(metrics)
    }

    /// The "Recent" grid's height for `count` posts: its rows, a gutter
    /// between each two.
    static func gridHeight(width: CGFloat, count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * tileHeight(width: width) + CGFloat(rows - 1) * gutter
    }

    /// The whole content's height in CONTENT coordinates, `recentCount` posts
    /// in the "Recent" grid: the sound and its room, the Popular title and
    /// row when there is one, the Recent title and grid, the gutter under its
    /// last row.
    static func contentHeight(_ metrics: DetentMetrics, recentCount: Int) -> CGFloat {
        guard recentCount > 0 else { return popularRowBottom(metrics) + contentBottom }
        return recentTitleTop(metrics) + metrics.sectionHeaderHeight
            + gridHeight(width: metrics.width, count: recentCount) + contentBottom
    }

    /// The fitted detent's value: the inset under the grabber, the whole
    /// content, then the toolbar's band — as the collapsed one counts it.
    /// Never under the collapsed detent: the sheet always grows.
    static func fittedDetentHeight(_ metrics: DetentMetrics, recentCount: Int) -> CGFloat {
        let fitted = (topInset + contentHeight(metrics, recentCount: recentCount) + metrics.toolbarBand).rounded(.up)
        return max(fitted, collapsedDetentHeight(metrics) + 1)
    }

    /// The toolbar's band above the home indicator: the view's bottom safe
    /// area less the window's.
    static func toolbarBand(bottomSafeArea: CGFloat, windowBottomSafeArea: CGFloat) -> CGFloat {
        max(0, bottomSafeArea - windowBottomSafeArea)
    }

    /// Whether a band read off the safe area can be the toolbar's, to be KEPT
    /// (it is kept for every sheet after). No band is a safe area caught
    /// without its bar, not a bar of none; and a band as tall as a quarter of
    /// the view is a safe area caught mid-setup: on CI (iOS 26.2, iPhone 16e
    /// test host) the detent came out ~780pt above its fold — a band of
    /// nearly the whole view, which, kept, would rest every later sheet at
    /// full height. A bar is ~50pt; anything implausible leaves the estimate
    /// in place.
    static func isPlausibleToolbarBand(_ band: CGFloat, viewHeight: CGFloat) -> Bool {
        band > 0 && band < min(120, viewHeight / 4)
    }

    /// Recomputes the detents' inputs and re-asks the sheet ONLY when an
    /// answer moved. Called when an input changes — loading, appearing (the
    /// real width and band), the text size, the width, the posts re-dealt —
    /// and from nowhere else. ⚠️ Never from a layout callback: see the type's
    /// note.
    private func refreshDetentMetrics(reason: String) {
        guard let width = sheetWidth, width > 0 else { return }
        let traits = view.window != nil
            ? traitCollection
            : (presentingViewController?.traitCollection ?? traitCollection)
        let metrics = DetentMetrics(
            width: width,
            headerHeight: headerHeight(width: width, traits: traits),
            sectionHeaderHeight: SectionTitleView.barHeight(traits: traits),
            sectionGap: SectionTitleView.gapAbove(traits: traits),
            toolbarBand: Self.measuredToolbarBand ?? estimatedToolbarBand(width: width),
            hasPopular: hasPopular
        )
        if metrics != detentMetrics {
            let heightsMoved = metrics.headerHeight != detentMetrics?.headerHeight
                || metrics.sectionHeaderHeight != detentMetrics?.sectionHeaderHeight
                || metrics.sectionGap != detentMetrics?.sectionGap
            let previous = collapsedHeight
            detentMetrics = metrics
            let height = Self.collapsedDetentHeight(metrics)
            collapsedHeight = height
            trace("""
                \(reason): width \(metrics.width) header \(metrics.headerHeight) title \(metrics.sectionHeaderHeight) \
                band \(metrics.toolbarBand) popular \(metrics.hasPopular) → \(height) \
                (was \(previous.map { "\($0)" } ?? "nil"))
                """)
            if heightsMoved, isViewLoaded { collectionView.collectionViewLayout.invalidateLayout() }
            if let previous, abs(previous - height) >= 0.5 { invalidateDetents() }
            if isViewLoaded { updateRevealLine() }
        }
        refreshFittedHeight(reason: reason)
    }

    /// The posts the "Recent" grid lays out.
    private var recentCount: Int {
        sections.first { $0.kind == .recent }?.ids.filter { tileByID[$0] != nil }.count ?? 0
    }

    /// Whether the Popular row is laid out — the snapshot's rule
    /// (`makeSnapshot`): a section with a post to show.
    private var hasPopular: Bool {
        sections.first { $0.kind == .popular }?.ids.contains { tileByID[$0] != nil } ?? false
    }

    /// Recomputes the fitted height and whether it is the expanded detent —
    /// the content shorter than large — and re-asks the sheet only when
    /// either moved: the detents swapped when the choice flips, re-resolved
    /// when the fitted value moved while it is the one in use. An input
    /// changing (the metrics, the post count), never a layout pass.
    ///
    /// Large is ESTIMATED from the window (`estimatedLargeHeight`), a stable
    /// input, not read back from the sheet's resolution: a choice that
    /// flipped once the sheet had stated its real maximum would swap the
    /// detents mid-rise. A content between the estimate and the real maximum
    /// is fitted at the maximum — the same height.
    private func refreshFittedHeight(reason: String) {
        guard let metrics = detentMetrics else { return }
        let height = Self.fittedDetentHeight(metrics, recentCount: recentCount)
        let fits = estimatedLargeHeight().map { height < $0 } ?? false
        let previous = fittedHeight
        guard height != previous || fits != expandsToFit else { return }
        fittedHeight = height
        let flipped = fits != expandsToFit
        expandsToFit = fits
        trace("""
            \(reason): fitted \(height) for \(recentCount) recent posts \
            (was \(previous.map { "\($0)" } ?? "nil")) → \(fits ? "fitted" : "large")
            """)
        if flipped {
            swapExpandedDetent()
        } else if fits, let previous, abs(previous - height) >= 0.5 {
            invalidateDetents()
        }
    }

    /// Where large stands: the window's height less its safe areas. Nil
    /// before the sheet has a window to be presented in.
    private func estimatedLargeHeight() -> CGFloat? {
        guard let window = view.window ?? presentingViewController?.view.window else { return nil }
        return window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom
    }

    /// Re-asks the detents' values.
    private func invalidateDetents() {
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

    /// Swaps the expanded detent between fitted and large, keeping a sheet
    /// that stands expanded expanded. Set outright before the sheet is up
    /// (the first answer lands in `viewDidLoad`, as it is presented).
    private func swapExpandedDetent() {
        detentInvalidations += 1
        guard let navigation = navigationController, let sheet = navigation.sheetPresentationController else { return }
        let expanded = Self.isExpanded(sheet.selectedDetentIdentifier)
        let swap = { [self] in
            sheet.detents = makeDetents()
            if expanded { sheet.selectedDetentIdentifier = expandedDetentIdentifier }
        }
        if view.window == nil || navigation.transitionCoordinator != nil {
            swap()
        } else {
            sheet.animateChanges(swap)
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
        let headerWidth = width - 2 * Self.headerInset
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

    // MARK: - Reveal

    /// The reveal's progress for the height the sheet is DRAWN at now: the
    /// presentation layer's (the spring's in-between frames), less the home
    /// indicator a detent's value does not count. Nil off screen.
    private func measuredReveal() -> CGFloat? {
        guard let window = view.window, let collapsed = collapsedHeight else { return nil }
        // ⚠️ RISING, IT IS COLLAPSED: the presentation draws the sheet taller
        // than its detent on the way up (measured 451 against 392, iOS 27) —
        // read as a height, the lower sections flashed in at 11% and out.
        if navigationController?.isBeingPresented == true { return 0 }
        let drawn = (view.layer.presentation() ?? view.layer).bounds.height - window.safeAreaInsets.bottom
        // Before the sheet has stated its large value: the window's height
        // less its safe areas is where large stands.
        let large = largeHeight ?? (window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom)
        // The far end is the EXPANDED detent: a fitted sheet is whole where
        // its content ends, not on the way to a large it never reaches.
        let expanded = expandsToFit ? min(fittedHeight ?? large, large) : large
        return SoundSheetReveal.progress(height: drawn, collapsed: collapsed, expanded: expanded)
    }

    /// Places the reveal's line (`revealLine`: the "Recent" title's top under
    /// a Popular row, its first row's foot without one) where the content is
    /// scrolled to now. A layer's frame: it lays nothing out.
    private func updateRevealLine() {
        guard let metrics = detentMetrics, isViewLoaded else { return }
        reveal.setLine(Self.revealLine(metrics) - collectionView.contentOffset.y, width: view.bounds.width)
    }

    /// Whether the tile at `item` of a section can be touched — what is faint
    /// cannot: the Popular row always; "Recent" once the fade is more than
    /// half through — but its FIRST ROW at once when it is the only section,
    /// the row standing above the reveal's line. Internal for the suite.
    func isRevealed(_ kind: SoundSheetSection.Kind, item: Int) -> Bool {
        if kind == .popular || reveal.progress >= 0.5 { return true }
        return !hasPopular && item < Self.columns
    }

    private func traceReveal(_ progress: CGFloat) {
        #if DEBUG
        let step = Int((progress * 10).rounded(.down))
        guard step != lastTracedReveal else { return }
        lastTracedReveal = step
        let drawn = view.layer.presentation().map { "\($0.bounds.height)" } ?? "?"
        trace("reveal \(String(format: "%.2f", progress)) at drawn height \(drawn)")
        #endif
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
            trace("""
                settled \(expanded ? "expanded" : "collapsed"): \(settled) (detent \(detent), \
                invalidations \(detentInvalidations), reveal \(reveal.progress))
                """)
            // Geometry, in the WINDOW: a collapsed sheet floats inset and is
            // drawn SCALED (measured 402 wide in its own space, 386 on
            // screen), so the view's bounds stay the width the grid and the
            // detent are computed for.
            let inWindow: CGRect = view.convert(view.bounds, to: nil)
            let use: CGRect = useButton.map { $0.convert($0.bounds, to: nil) } ?? .zero
            trace("geometry: view \(view.bounds) on screen \(inWindow) use \(use)")
            // The list at rest: at its top (−topInset) below the fullest
            // detent, and whether it has anywhere to scroll.
            let list = collectionView
            let room = list.contentSize.height + list.adjustedContentInset.top + list.adjustedContentInset.bottom
                - list.bounds.height
            trace("""
                list: offset \(list.contentOffset.y) top \(-list.adjustedContentInset.top) \
                content \(list.contentSize.height) scrollable \(room) fullest \(isAtFullestDetent) \
                sections \(sections.map { "\($0.kind.rawValue) \($0.ids.count)" })
                """)
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

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Order

    /// The head of the "Popular" ranking, and which post is MARKED "Original":
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
    /// place keeps the row from reshuffling when it loads — but it is marked
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

    // MARK: - Sections

    /// A section's head: the app's one section title (`SectionTitleView`) —
    /// with a chevron right after it when the section holds more than the
    /// sheet shows (`SoundSheetSection.hasMore`), the whole bar then one
    /// control that pushes the ranking; a plain title when it shows
    /// everything. No "View all" label (dropped 2026-09-30).
    ///
    /// ⚠️ Its height is `SectionTitleView.barHeight`, given ABSOLUTELY by the
    /// layout: it is part of the collapsed detent, which is never measured
    /// off a live layout.
    static func configure(_ header: SectionTitleSupplementaryView, for section: SoundSheetSection) {
        header.configure(.init(title: section.title, isLink: section.hasMore))
        header.titleView.accessibilityHint = section.hasMore ? "Shows every post in \(section.title)" : nil
    }

    /// A section's title and chevron — Popular's, the one section that has
    /// one: its whole ranking as a grid, pushed inside the sheet AT THE
    /// DETENT THE SHEET STANDS AT. A collapsed sheet stays collapsed (asked for,
    /// 2026-09-29, reversing #310's raise to large): the push is a new page,
    /// not a new height; the viewer grows the sheet if they want more of it.
    func showSection(_ kind: SoundSheetSection.Kind) {
        guard isRevealed(kind, item: 0), let navigation = navigationController, navigation.topViewController === self,
              let section = sections.first(where: { $0.kind == kind }), section.hasMore
        else { return }
        let gallery = SoundSheetGalleryViewController(
            kind: kind,
            ids: section.all.filter { tileByID[$0] != nil },
            tile: { [weak self] id in self?.tileByID[id] },
            imagePipeline: imagePipeline
        )
        gallery.toolbarItems = makeToolbarItems(primary: false)
        gallery.onSelect = { [weak self, weak gallery] id in
            guard let self, let gallery else { return }
            select(id, order: gallery.ids, source: .gallery(gallery))
        }
        pushedGallery = gallery
        trace("push \(kind.rawValue): \(gallery.ids.count) posts (\(isExpanded ? "expanded" : "collapsed"))")
        navigation.pushViewController(gallery, animated: true)
    }

    #if DEBUG
    /// `-snap-sound-sheet push`: Popular's title and chevron, without the
    /// tap.
    func debugShowPopular() {
        showSection(.popular)
    }

    /// `-snap-sound-sheet push`: back from the pushed section, as the back
    /// button would.
    func debugPopSection() {
        navigationController?.popToRootViewController(animated: true)
    }

    /// `-sound-sheet-open`: a tile's tap, through the same `select` a finger
    /// reaches — see `SoundSheetViewController+QA`.
    func debugSelect(_ id: PostID, in kind: SoundSheetSection.Kind, order: [PostID]) {
        select(id, order: order, source: .sheet(kind))
    }
    #endif

    // MARK: - Expansion

    #if DEBUG
    /// `-snap-sound-sheet large`: up to the expanded detent — fitted or
    /// large — as the grabber would take it.
    func debugExpand() {
        guard let sheet = navigationController?.sheetPresentationController, !isExpanded else { return }
        let expanded = expandedDetentIdentifier
        // A programmatic change is not reported to the delegate.
        detentChanged(to: expanded)
        sheet.animateChanges { sheet.selectedDetentIdentifier = expanded }
    }

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

    /// ⚠️ NOT `isExpanded`: the expanded detent leaves the clip behind playing,
    /// like the collapsed one — only a second sound or a second feed covers it.
    private func refreshCover() {
        setCovering(isPreviewing || isShowingFeed)
    }

    /// A feed opened from a tile covers everything, the page behind the sheet
    /// included: that page pauses for the trip and plays again on the return.
    private var isShowingFeed = false

    /// Where a tapped tile is: in a section of this screen — a post can be
    /// in both — or in a pushed section.
    enum TileSource {
        case sheet(SoundSheetSection.Kind)
        case gallery(SoundSheetGalleryViewController)
    }

    /// A tile's tap: its post opened as a new feed with the hero, the posts
    /// after it in `order` following. Falls back to scrolling the feed behind
    /// (`onSelectPost`) when the host did not hand over a way to open one.
    private func select(_ id: PostID, order: [PostID], source: TileSource) {
        // A placeholder leads nowhere yet: its post is still on its way.
        guard let tile = tileByID[id], tile.isLoaded else { return }
        if openFeed(from: tile, order: order, source: source) { return }
        // Scrolling the feed behind reaches only ITS posts; any other stays
        // put rather than closing the sheet on nothing.
        guard openFeedHero == nil else { return }
        let select = onSelectPost
        dismiss(animated: true) { select?(id) }
    }

    private func openFeed(from tile: Tile, order: [PostID], source: TileSource) -> Bool {
        guard let openFeedHero, let galleryPost,
              (navigationController ?? self).presentedViewController == nil,
              let post = galleryPost(tile.postID)
        else { return false }
        let ordered = order.compactMap { galleryPost($0) }
        guard let start = ordered.firstIndex(where: { $0.id == post.id }) else { return false }
        let stream = Array(ordered[start...])
        let id = tile.postID
        let presenter: UIViewController
        if case .gallery(let pushed) = source { presenter = pushed } else { presenter = self }
        let origin = heroOrigin(for: tile, post: post, stream: stream, source: source)
        trace("open \(id.rawValue) (\(post.kind)) stream \(stream.prefix(3).map(\.id.rawValue))")
        stopPreview()
        isShowingFeed = true
        refreshCover()
        OverSheetFeedHost.present(over: presenter, onFinished: { [weak self] in
            self?.isShowingFeed = false
            self?.refreshCover()
        }) { host in
            #if DEBUG
            Self.debugFeedHost = host
            #endif
            openFeedHero(stream.map(\.id), host, origin)
        }
        return true
    }

    /// The tile, described for the shared flight (`presentSnapFeedHero`): its
    /// hero, and the window it opens through (a text post) or closes through
    /// (any post, once the feed is on words). Internal for the suite.
    func heroOrigin(
        for tile: Tile, post: GalleryPost, stream: [GalleryPost], source: TileSource
    ) -> SnapFeedHeroOrigin {
        let id = tile.postID
        // Weak, both: the hero keeps these closures for the whole trip.
        weak var gallery: SoundSheetGalleryViewController?
        var kind = SoundSheetSection.Kind.popular
        switch source {
        case .gallery(let pushed): gallery = pushed
        case .sheet(let section): kind = section
        }
        let fromGallery = gallery != nil
        let cell: () -> SoundSheetTileCell? = { [weak self] in
            fromGallery ? gallery?.tileCell(for: id) : self?.tileCell(for: id, in: kind)
        }
        let frame: (UICoordinateSpace) -> CGRect? = { [weak self] space in
            fromGallery ? gallery?.tileFrame(for: id, in: space) : self?.tileFrame(for: id, in: kind, space: space)
        }
        let cover = cell()?.cover
        let presenter: UIViewController = gallery ?? self
        // Every tile is the same shape, and the one measured at the tap
        // stands in for a close that finds it scrolled out.
        let tappedSize = cell()?.bounds.size
        let traits = cell()?.traitCollection ?? traitCollection
        let standIn: () -> UIView? = {
            guard let size = cell()?.bounds.size ?? tappedSize else { return nil }
            // The picture the tile shows NOW, or the one it showed at the tap.
            return SoundSheetTileCell.makeStandIn(
                for: tile, cover: cell()?.cover ?? cover, size: size, traits: traits
            )
        }
        return SnapFeedHeroOrigin(
            post: post,
            stream: stream,
            // A text post has no picture to fly: it opens through its window.
            hasHero: post.kind != .text && cover != nil,
            cover: cover,
            style: .tile,
            frame: { space in frame(space) },
            isOnScreen: { [weak presenter] in
                guard let presenter else { return false }
                return frame(presenter.view) != nil
            },
            setConcealed: { concealed in cell()?.setConcealed(concealed) },
            // ⚠️ EVERY TILE, and For You's Following cards are why
            // (`ForYouRowOrigins`): a TEXT post opens as a window out of its
            // tile and closes back onto it — it used to open with the plain
            // push — and a MEDIA post, which opens with its flight, closes
            // through the same window once the viewer has paged onto words,
            // where there is no picture left to fly. Marker-shaped: the feed
            // is a pager, so nothing is aligned; the tile, drawn fresh, is the
            // stand-in at both ends.
            textReveal: TextRevealOrigin(
                rowFrame: { space in frame(space) },
                captionEnd: nil,
                makeDismissStandIn: { _ in standIn() },
                makePresentStandIn: standIn,
                alignsPageToSource: false,
                pageFit: .covering,
                cornerRadius: SoundSheetTileCell.cornerRadius,
                fill: SoundSheetTileCell.standInGround(traits: traits),
                setConcealed: { concealed in cell()?.setConcealed(concealed) }
            ),
            // ⚠️ THE TILE'S OWN CORNER, AND ITS CURVE. Left to the style, the
            // card rounded as a For You brick (16pt) and landed on a 12pt tile:
            // the corners jumped in the frame the card was taken away — the
            // flash at the end of every close. A 12pt SQUIRCLE, like the tile.
            cornerRadius: SoundSheetTileCell.cornerRadius,
            cornerCurve: .continuous,
            // The tile's marks, worn at the source end and faded as the card
            // grows, so a close does not pop them on at the landing.
            restingOverlay: {
                guard let size = cell()?.bounds.size ?? tappedSize else { return nil }
                return SoundSheetTileCell.makeBadgeOverlay(for: tile, size: size)
            }
        )
    }

    private func tileCell(for id: PostID, in kind: SoundSheetSection.Kind) -> SoundSheetTileCell? {
        guard let path = dataSource.indexPath(for: .tile(id, kind)) else { return nil }
        return collectionView.cellForItem(at: path) as? SoundSheetTileCell
    }

    /// The tile's rect in `space` while it is on screen — nil once it has
    /// scrolled out (under the toolbar included, or off a row's side), so the
    /// hero falls back instead of flying to nowhere.
    ///
    /// ⚠️ A ROW'S cell lives in the row's own scroll view: its `frame` is in
    /// that view's coordinates, not the grid's — converted before it is
    /// compared with what the grid shows.
    private func tileFrame(
        for id: PostID, in kind: SoundSheetSection.Kind, space: UICoordinateSpace
    ) -> CGRect? {
        guard let cell = tileCell(for: id, in: kind) else { return nil }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard visible.intersects(cell.convert(cell.bounds, to: collectionView)) else { return nil }
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

    private func share(from item: UIBarButtonItem?) {
        let text = [sound.title ?? "Original sound", sound.artist ?? "@\(authorHandle)"].joined(separator: " — ")
        let activity = UIActivityViewController(activityItems: ["♫ \(text)"], applicationActivities: nil)
        if let item {
            activity.popoverPresentationController?.sourceItem = item
        } else {
            activity.popoverPresentationController?.sourceView = view
        }
        (navigationController ?? self).present(activity, animated: true)
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
    /// the delegate, a programmatic change (`debugExpand`) does not report it
    /// at all. It puts the posts back at their top at collapsed (the Popular
    /// row under the sound, the reveal's line where the fold is), and wakes
    /// the reveal to follow the sheet's spring; nothing else: the clip behind
    /// plays on at either.
    fileprivate func detentChanged(to identifier: UISheetPresentationController.Detent.Identifier?) {
        let expanded = Self.isExpanded(identifier)
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        traceSettledHeight(expanded: expanded)
        reveal.wake()
        guard dataSource != nil, !expanded else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: -collectionView.adjustedContentInset.top),
            animated: true
        )
    }
}

// MARK: - Posts

extension SoundSheetViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .tile(let id, let kind) = dataSource.itemIdentifier(for: indexPath),
              isRevealed(kind, item: indexPath.item),
              let section = sections.first(where: { $0.kind == kind })
        else { return }
        // A row is a window on its whole ranking: the feed goes on past the
        // row's end. The grid's own order is the one it shows.
        select(id, order: kind.isRow ? section.all : section.ids, source: .sheet(kind))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only this collection's own scroll: a row's sideways scroll moves no
        // line.
        guard scrollView === collectionView else { return }
        #if DEBUG
        // `-sound-sheet-trace`: a finger that SCROLLED the posts. Below the
        // fullest detent there must be none — the drag is the sheet's.
        if scrollView.isDragging, ProcessInfo.processInfo.arguments.contains("-sound-sheet-trace") {
            trace("scrolled: offset \(scrollView.contentOffset.y) fullest \(isAtFullestDetent)")
        }
        #endif
        // The line follows the Popular row as the posts scroll.
        guard reveal.progress < 1 else { return }
        updateRevealLine()
    }
}

// MARK: - Scrolling

extension SoundSheetViewController {
    /// Whether the sheet stands at its fullest detent — the fitted one or
    /// large — the one height at which the posts may scroll. The SHEET's own
    /// answer, not `isExpanded`: that one follows a programmatic change only
    /// through `detentChanged`. Off a presented sheet (a test), true.
    var isAtFullestDetent: Bool {
        guard let navigation = navigationController, navigation.presentingViewController != nil,
              let sheet = navigation.sheetPresentationController
        else { return true }
        return Self.isExpanded(sheet.selectedDetentIdentifier)
    }

    /// Puts the posts at their top — the edge UIKit's scroll-to-expand starts
    /// from — when they rest any further in. A pull past the top is left
    /// alone. Called when the sheet appears, never while a finger moves.
    static func restAtTop(_ scrollView: UIScrollView) {
        let top = -scrollView.adjustedContentInset.top
        guard scrollView.contentOffset.y > top else { return }
        scrollView.contentOffset.y = top
    }
}
