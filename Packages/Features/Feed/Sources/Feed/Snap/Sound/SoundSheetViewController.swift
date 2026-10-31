import AVFoundation
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
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
///  │▢♪Original ▢ ▢ ▢┆→                    │  a row; its title + chevron push
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
/// **THE RECORD IS THE SHEET'S OWN TRACK** (the owner, 2026-10-31, reversing
/// #1148's mirror of the post): two tracks, the sheet's and the post's, and
/// playing one pauses the other. The record plays the sound's preview on a
/// player of its own; while it plays, the post behind is covered
/// (`onCoverChanged`), and when the post plays again the feed stops the
/// track (`releaseTrack`). A feed opened from a tile covers the post too,
/// for the trip. The post also pauses under the expanded sheet: the sheet
/// declares itself a cover while expanded (`ScreenCovering`, #1970).
final class SoundSheetViewController: UIViewController {
    struct Tile: Hashable, Sendable {
        let postID: PostID
        let thumbnailURL: URL?
        /// What a text post shows in its tile, having no picture.
        let caption: String?
        /// The post the sound was first published with — first in "Popular".
        let isOriginal: Bool
        /// Whether the post itself is known yet. The sheet lists EVERY post set
        /// to the sound, most of them outside the feed behind: those arrive as
        /// placeholders — so the sheet rises at once, at its final size — and
        /// are filled in by `update(sections:tiles:)` once the repository has
        /// them.
        let isLoaded: Bool
        /// The post's likes, drawn at the tile's foot — nil draws none (a
        /// placeholder, or a post that carries no count).
        let likeCount: Int64?
        /// The clip the tile plays on its own, muted, like every grid's
        /// (`SoundSheetAutoplay`, #884) — nil for a photograph, words or a
        /// placeholder.
        let videoURL: URL?
        /// The post itself, once known — what the standard tile draws: its
        /// picture, and its author, caption and likes by size (#1280).
        let post: GalleryPost?

        /// ⚠️ THE ONE TILE CONTRACT (#1280, epic #1269): a loaded MEDIA post is
        /// drawn by the standard tile (`PostGridTileCell`), as on every other
        /// surface. A text post and a placeholder keep this sheet's own tile.
        var drawsStandardTile: Bool {
            guard isLoaded, let post else { return false }
            return post.kind != .text
        }

        init(
            postID: PostID, thumbnailURL: URL?, caption: String?,
            isOriginal: Bool = false, isLoaded: Bool = true, likeCount: Int64? = nil,
            videoURL: URL? = nil, post: GalleryPost? = nil
        ) {
            self.postID = postID
            self.thumbnailURL = thumbnailURL
            self.caption = caption
            self.isOriginal = isOriginal
            self.isLoaded = isLoaded
            self.likeCount = likeCount
            self.videoURL = videoURL
            self.post = post
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(postID)
            hasher.combine(isLoaded)
            hasher.combine(likeCount)
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

    /// Whether the clip behind should pause: a feed opened from a tile covers
    /// it. NEVER the detent alone, and never the sheet just being open.
    var onCoverChanged: ((Bool) -> Void)?

    /// What the record shows: the sheet's own track.
    struct RecordPlayback: Equatable {
        /// The preview plays: the record turns, the glyph is ❚❚. No muted
        /// state since #1931 — the sound follows the device.
        var playing = false
        /// The sound has a preview to play; false shows the record with no
        /// glyph, refusing taps.
        var available = true
    }

    private(set) var record = RecordPlayback()

    private func setRecord(_ playback: RecordPlayback) {
        guard playback != record else { return }
        let availabilityChanged = playback.available != record.available
        record = playback
        guard let header else { return }
        if availabilityChanged { configure(header) } else { apply(playback, to: header) }
    }

    private func apply(_ playback: RecordPlayback, to header: SoundSheetHeaderView) {
        header.setPlaying(playback.available && playback.playing)
    }

    #if DEBUG
    /// The track reached its end. Tests.
    func debugEndTrack() { loopPreview() }
    /// Whether the bar's feed runs. Tests.
    var debugPreviewFeedRuns: Bool { previewFeed != nil }

    /// Draws the record in a state, for the glyph's tests.
    func debugShowRecord(playing: Bool, available: Bool) {
        setRecord(RecordPlayback(playing: playing, available: available))
    }
    #endif
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
    /// The app's one player pool, which a pushed section plays on too.
    private let videoPlayback: VideoPlaybackController?
    /// The video tiles playing on their own (#884); nil without a pool.
    private(set) var autoplay: SoundSheetAutoplay?

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    /// The sheet's lookahead (#970): the Popular row's and the Recent grid's
    /// covers a screen ahead decoded, two and a half ahead on disk, under the
    /// sheet's own owner while it is on screen.
    private lazy var lookahead: ScrollLookahead = {
        let lookahead = ScrollLookahead(pipeline: imagePipeline, name: "sound-sheet", kind: .grid) { [weak self] path in
            guard let self, case .tile(let id, _)? = dataSource?.itemIdentifier(for: path),
                  let url = tileByID[id]?.thumbnailURL else { return [] }
            // At the bucket the tile decodes it at (#1505).
            return [PostGridTileCell.coverRequest(url, at: path, in: collectionView)]
        }
        lookahead.attach(to: collectionView)
        return lookahead
    }()
    private weak var header: SoundSheetHeaderView?
    #if DEBUG
    /// The header as the sheet last configured it.
    var debugHeader: SoundSheetHeaderView? { header }
    #endif
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
    /// Nothing under the sound — no Popular row, no Recent post (the post the
    /// sheet opened over is never listed, #1161): the sheet has ONE detent,
    /// the collapsed one. An expanded detent opened an empty band under the
    /// sound (#1162; the owner, on a device).
    private(set) var hasNothingBelow = false
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
    private var isCovering = false

    /// The post the sheet opens over (#1147): in no section, but one of the
    /// posts set to the sound, so the header's count includes it.
    private let watchedPosts: Int
    /// "N posts" in the header: every tile, and the post watched.
    private var postCount: Int { tiles.count + watchedPosts }

    init(
        sound: PostSound,
        authorHandle: String,
        fallbackArtworkURL: URL?,
        sections: [SoundSheetSection],
        tiles: [Tile],
        imagePipeline: ImagePipeline,
        savedSounds: SavedSoundStore = SavedSoundStore(),
        videoPlayback: VideoPlaybackController? = nil,
        watchedPosts: Int = 0
    ) {
        self.watchedPosts = watchedPosts
        self.sound = sound
        self.authorHandle = authorHandle
        self.fallbackArtworkURL = fallbackArtworkURL
        self.sections = sections
        self.tiles = tiles
        self.tileByID = Dictionary(tiles.map { ($0.postID, $0) }, uniquingKeysWith: { first, _ in first })
        self.imagePipeline = imagePipeline
        self.savedSounds = savedSounds
        self.videoPlayback = videoPlayback
        record = RecordPlayback(playing: false, available: sound.previewURL != nil)
        autoplay = videoPlayback.map { SoundSheetAutoplay(pool: $0, imagePipeline: imagePipeline) }
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
        guard !hasNothingBelow else { return [collapsed] }
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
        if hasNothingBelow { return Self.collapsedDetent }
        return expandsToFit ? Self.fittedDetent : .large
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
        reveal.onChange = { [weak self] progress in
            self?.traceReveal(progress)
            // What is faint does not play: the line moving changes what may.
            self?.scheduleAutoplay()
        }
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
        lookahead.setOnScreen(true)
        // The sheet rising: this screen holds all of it, so its tiles play
        // from the rise (#1914). A section popping off it: from half.
        if isBeingPresented || navigationController?.isBeingPresented == true {
            viewportShare.report(1)
            if !isShowingFeed { setAutoplayActive(true) }
        } else {
            _ = viewportShare.screenWillAppear(self)
        }
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
        // Up, or back from a pushed section: the tiles are the viewer's
        // again — unless a feed opened from one still covers them.
        viewportShare.report(1)
        if !isShowingFeed { setAutoplayActive(true) }
        installRecordTap()
        #if DEBUG
        debugOpenTileIfRequested()
        #endif
    }

    // MARK: - The record's tap (#1162)

    /// ⚠️ THE RECORD'S TAP LIVES ON THE SHEET, NOT ON THE RECORD. The record's
    /// upper half sits under the sheet's navigation bar, and a recognizer on
    /// the record never fired there — not even with the bar passing the hit
    /// through: something in the bar's band takes the touch at the gesture
    /// level (#1162; the owner, on a device: "very hard to pause from the
    /// cover"). A recognizer on the presented navigation controller's view
    /// sees every touch in the sheet whichever view is hit, and begins only
    /// inside the record — the WHOLE disc, not the glyph (#1162).
    private var recordTap: UITapGestureRecognizer?

    private func installRecordTap() {
        guard recordTap == nil, let host = navigationController?.view else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(recordTapped))
        tap.delegate = self
        tap.cancelsTouchesInView = true
        host.addGestureRecognizer(tap)
        recordTap = tap
    }

    @objc private func recordTapped() {
        togglePreview()
    }

    /// Whether `point`, in `view`'s space, is on the record (and the record
    /// takes taps: a post with sound).
    func recordTakesTap(at point: CGPoint, in view: UIView) -> Bool {
        // A screen pushed over the sheet covers the record; a header a
        // recycled cell took off the sheet is no record to tap.
        guard navigationController?.topViewController === self,
              let header, isViewLoaded, header.isDescendant(of: self.view) else { return false }
        return header.recordTakesTap(at: view.convert(point, to: header))
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
        // The sheet going: this screen holds all of it to the end, and its
        // tiles play through the fall (#1914). A section pushed over it: until
        // it covers half. Every tile gives its player back once the screen
        // is gone (`viewDidDisappear`) — none is left bound to a sheet nobody
        // sees (#884).
        if isSheetBeingDismissed { return }
        if viewportShare.screenWillDisappear(self) == .flight {
            setAutoplayActive(false)
        }
    }

    /// The share of this screen in its SHEET (#1914): its tiles play while it
    /// holds half of the sheet — through the sheet's own rise and fall, where
    /// it holds all of it, and until half way through a section pushed over
    /// it or its own pop. Measured against the sheet, not the display: at a
    /// medium detent the sheet is all the viewer reads.
    private lazy var viewportShare: ViewportShare = {
        let share = ViewportShare(host: view)
        share.reference = { [weak self] in self?.navigationController?.view }
        share.onPlaysChange = { [weak self] plays in
            guard let self else { return }
            setAutoplayActive(plays && !isShowingFeed)
        }
        return share
    }()


    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Off screen (a section pushed over it, or gone): nothing to watch,
        // and nothing to fetch ahead for — the stay's owner is revoked.
        setAutoplayActive(false)
        reveal.sleep()
        lookahead.setOnScreen(false)
        guard isSheetBeingDismissed else { return }
        releaseTrack()
        tearDownPreview()
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
        close.identifier = "soundSheet.close"
        closeItem = close
        return close
    }

    /// Down and gone, however high the sheet stands — the same dismissal as a
    /// swipe down: the feed behind is uncovered on the way out
    /// (`viewDidDisappear`).
    func close() {
        closePresentation()
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
    /// size or the OS's bar margins (`BarItems.stretched`). Its bubble is the
    /// BAR's, prominent in the theme's pink: the item draws no glass of its
    /// own (the bar contract, `dev/BAR_CONTRACT.md`).
    private func makeToolbarItems(primary: Bool) -> [UIBarButtonItem] {
        let share = UIBarButtonItem(systemItem: .action)
        share.primaryAction = UIAction { [weak self, weak share] _ in self?.share(from: share) }
        share.accessibilityLabel = "Share sound"
        share.identifier = "soundSheet.share"
        // ⚠️ AN ACTION WITHOUT AN IMAGE, the glyph on the ITEM: an action's
        // image is re-applied to its item when it fires, and put the
        // star outline back over the fill just set (measured: the fill
        // flashed during the press and was gone at rest).
        let bookmark = UIBarButtonItem(primaryAction: UIAction { [weak self] _ in self?.toggleSaved() })
        bookmark.identifier = "soundSheet.save"
        bookmarkItems.add(bookmark)
        if primary {
            shareItem = share
            bookmarkItem = bookmark
        }
        refreshBookmark()
        let trailing: [UIBarButtonItem] = [bookmark, .fixedSpace(), share]
        guard onUseSound != nil else { return [.flexibleSpace()] + trailing }
        // The bar draws its prominent bubble (#1679, `BarItems.stretched`):
        // no button with a glass of its own.
        let use = BarItems.stretched(id: "soundSheet.use", title: "Use this sound", prominent: true) { [weak self] in
            self?.useSound()
        }
        use.label.accessibilityIdentifier = "sound.use"
        if primary {
            useItem = use.item
            useControl = use.label
        }
        return [use.item, .fixedSpace()] + trailing
    }

    /// The "Use this sound" control — what a test reads.
    private(set) weak var useControl: StretchedBarLabel?

    // MARK: - Saved

    /// Saves the sound, or unsaves it; the glyph and its label follow.
    private func toggleSaved() {
        MemberGates.perform(.saveSound, from: self) { [weak self] in
            guard let self else { return }
            let saved = savedSounds.toggle(sound.id)
            // The fill says it; the hand feels it, saving only (#803, #1881).
            Feedback.toggled(on: saved)
            refreshBookmark()
            trace("saved \(sound.id): \(saved)")
        }
    }

    /// The bookmark's glyph for the sound's state — what a test reads.
    var bookmarkSymbol: String { SaveStar.symbol(saved: savedSounds.isSaved(sound.id)) }

    private func refreshBookmark() {
        let saved = savedSounds.isSaved(sound.id)
        for item in bookmarkItems.allObjects {
            // The star, filled in the one save gold once saved (`SaveStar`,
            // #1190 — it had a gold of its own).
            item.image = SaveStar.image(saved: saved)
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
            // The LAST section closes the content with the gutter, whichever
            // it is — the sound alone, or the row with no "Recent" (#1147).
            let isLast = index == (self?.dataSource?.snapshot().numberOfSections ?? 1) - 1
            let gap = isLast ? Self.contentBottom : (metrics?.sectionGap ?? 18)
            switch self?.dataSource?.sectionIdentifier(for: index) ?? .sound {
            case .sound:
                return Self.soundSection(height: metrics?.headerHeight ?? 112, bottom: gap)
            case .posts(let kind):
                let section = kind.isRow
                    ? Self.rowSection(environment, bottom: gap) { [weak self] in self?.scheduleAutoplay() }
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
    /// before the "Recent" title. `onScroll` hears the row move sideways —
    /// its own scroll view, which never reaches the collection's delegate.
    private static func rowSection(
        _ environment: NSCollectionLayoutEnvironment, bottom: CGFloat, onScroll: @escaping () -> Void
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
        // Room above the tiles for "Original" across a tile's top edge: the
        // row's own scroll view clips what reaches past it (#1280).
        section.contentInsets = .init(top: ribbonRoom, leading: gutter, bottom: bottom, trailing: gutter)
        // Called from inside a layout pass: the listener defers its work.
        section.visibleItemsInvalidationHandler = { _, _, _ in onScroll() }
        return section
    }

    /// Three columns of 3:4 tiles, one gutter from the sheet's sides and from
    /// each other — the "Recent" grid, and Popular's pushed gallery.
    static func gridSection(
        _ environment: NSCollectionLayoutEnvironment, bottom: CGFloat
    ) -> NSCollectionLayoutSection {
        // ⚠️ A COLUMN ON THE PIXEL GRID (#1507): thirds of the row, each
        // snapped by UIKit, came out a pixel wide apiece at 2x — the iPhone
        // SE's right margin was 9 where the gutter is 10. Floored to a device
        // pixel, the columns leave at most a pixel or two at the trailing edge.
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .absolute(columnWidth(
                width: environment.container.effectiveContentSize.width,
                scale: environment.traitCollection.displayScale
            )),
            heightDimension: .fractionalHeight(1)
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

    /// A grid column's width on a sheet `width` wide, floored to a device
    /// pixel at `scale` (none given: a point).
    static func columnWidth(width: CGFloat, scale: CGFloat) -> CGFloat {
        let column = max(0, width - CGFloat(columns + 1) * gutter) / CGFloat(columns)
        let pixels = max(1, scale)
        return (column * pixels).rounded(.down) / pixels
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
    /// What the tiles leave clear above them: half the "Original" chip that
    /// straddles a tile's top edge (`TileRibbonView.overhang`, #1280).
    static var ribbonRoom: CGFloat { TileRibbonView.overhang.rounded(.up) }

    static func rowTileHeight(width: CGFloat) -> CGFloat {
        (rowTileWidth(width: width) * 4 / 3).rounded()
    }

    /// The standard tile as the sheet wears it — shared by the sheet's rows
    /// and its pushed gallery (#1280): the post with the sheet's own count,
    /// its words by size (`PostTileInfo`), the sheet's corner, and
    /// "Original" across the top edge of the post the sound was first
    /// published with.
    static func configureStandardTile(
        _ cell: PostGridTileCell, tile: Tile, post: GalleryPost, pipeline: ImagePipeline
    ) {
        var drawn = post
        if let likes = tile.likeCount { drawn.reactionCount = likes }
        cell.cornerRadius = SoundSheetTileCell.cornerRadius
        cell.configure(with: drawn, imagePipeline: pipeline, showsInfo: true)
        cell.setRibbon(tile.isOriginal ? "Original" : nil, symbolName: "music.note")
    }

    private func configureDataSource() {
        let pipeline = imagePipeline
        let tileRegistration = UICollectionView.CellRegistration<SoundSheetTileCell, PostID> {
            [weak self] cell, _, id in
            guard let tile = self?.tileByID[id] else { return }
            cell.configure(tile, pipeline: pipeline)
            // A tile plays once its poster is up: its arrival asks again.
            cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
        }
        // ⚠️ A LOADED MEDIA POST IS THE STANDARD TILE (#1280, epic #1269): its
        // picture, its words by size, its likes — and "Original" across its
        // top edge, as the shop marks its best pack.
        let mediaRegistration = UICollectionView.CellRegistration<PostGridTileCell, PostID> {
            [weak self] cell, _, id in
            guard let self, let tile = tileByID[id], let post = tile.post else { return }
            Self.configureStandardTile(cell, tile: tile, post: post, pipeline: pipeline)
            // A tile plays once its poster is up: its arrival asks again.
            cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
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
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, path, item in
            switch item {
            case .sound:
                view.dequeueConfiguredReusableCell(using: soundRegistration, for: path, item: item)
            case .tile(let id, _):
                if self?.tileByID[id]?.drawsStandardTile == true {
                    view.dequeueConfiguredReusableCell(using: mediaRegistration, for: path, item: id)
                } else {
                    view.dequeueConfiguredReusableCell(using: tileRegistration, for: path, item: id)
                }
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
        // A placeholder that arrives as a media post changes CELL (#1280):
        // reloaded, since a reconfigure keeps the cell it has.
        let swapped = Set(changed.filter { id in
            tileByID[id]?.drawsStandardTile != newTiles.first { $0.postID == id }?.drawsStandardTile
        })
        sections = newSections
        tiles = newTiles
        tileByID = Dictionary(newTiles.map { ($0.postID, $0) }, uniquingKeysWith: { first, _ in first })
        guard dataSource != nil else { return }
        var snapshot = makeSnapshot()
        // Every item of a changed post: in the row, in the grid, or both.
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            if case .tile(let id, _) = $0 { changed.contains(id) && !swapped.contains(id) } else { false }
        })
        snapshot.reloadItems(snapshot.itemIdentifiers.filter {
            if case .tile(let id, _) = $0 { swapped.contains(id) } else { false }
        })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        lookahead.setNeedsPlan()
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
        header?.setMeta(Self.meta(duration: sound.duration, posts: postCount))
        if let gallery = pushedGallery {
            let ids = newSections.first { $0.kind == gallery.kind }?.all.filter { tileByID[$0] != nil } ?? []
            gallery.update(ids: ids, reconfiguring: Array(changed))
        }
        // Placeholders filled in can be clips now.
        scheduleAutoplay()
    }

    private func configure(_ header: SoundSheetHeaderView) {
        self.header = header
        header.configure(
            title: sound.title ?? "Original sound",
            subtitle: sound.artist ?? "@\(authorHandle)",
            meta: Self.meta(duration: sound.duration, posts: postCount),
            canToggle: record.available
        )
        apply(record, to: header)
        // The track's bar: the video's handling (#1964) — a drag or a tap
        // moves the preview.
        header.trackBar.isScrubbable = preview != nil
        header.trackBar.onScrubBegan = { [weak self] in self?.beginTrackScrub() }
        header.trackBar.onSeekRequested = { [weak self] fraction in self?.seekTrack(to: fraction) }
        header.trackBar.onScrubEnded = { [weak self] fraction in self?.endTrackScrub(at: fraction) }
        header.setTrackProgress(previewFraction, loading: false)
        header.onTogglePlayback = { [weak self] in
            // A transport control: silent (#1881).
            guard let self, record.available else { return }
            togglePreview()
        }
        if let url = sound.artworkURL ?? fallbackArtworkURL {
            header.loadArtwork(url, pipeline: imagePipeline)
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
        /// Whether "Recent" is there (#1147): not when every other post fits
        /// the row, or when there is none.
        var hasRecent: Bool = true
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
        // No "Recent" (#1147): the content is whole at collapsed — the sound
        // and the row, if any, then the gutter. Nothing below to glimpse.
        guard metrics.hasRecent else { return topInset + contentHeight(metrics, recentCount: 0) }
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
        return soundBottom(metrics) + metrics.sectionHeaderHeight + ribbonRoom + rowTileHeight(width: metrics.width)
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
        guard metrics.hasRecent else { return contentHeight(metrics, recentCount: 0) }
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
        guard recentCount > 0 else {
            // The sound alone ends at its header, not at the gap a section
            // title would stand on.
            return (metrics.hasPopular ? popularRowBottom(metrics) : metrics.headerHeight) + contentBottom
        }
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
            hasPopular: hasPopular,
            hasRecent: recentCount > 0
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
                band \(metrics.toolbarBand) popular \(metrics.hasPopular) recent \(metrics.hasRecent) → \(height) \
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
        let nothingBelow = recentCount == 0 && !hasPopular
        let previous = fittedHeight
        guard height != previous || fits != expandsToFit || nothingBelow != hasNothingBelow else { return }
        fittedHeight = height
        let flipped = fits != expandsToFit || nothingBelow != hasNothingBelow
        expandsToFit = fits
        hasNothingBelow = nothingBelow
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
                meta: Self.meta(duration: sound.duration, posts: postCount),
                canToggle: record.available
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
            let use: CGRect = useControl.map { $0.convert($0.bounds, to: nil) } ?? .zero
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
    /// 2. every other post set to the sound, as the provider ranks them —
    ///    across the whole corpus, not only the feed behind the sheet.
    /// Each post once. The post watched is the caller's to leave out
    /// (`SoundSheetSections`, #1147).
    ///
    /// `isMedia` is nil for a post not loaded yet. An unknown original still
    /// leads — it is a clip's post far more often than not, and holding its
    /// place keeps the row from reshuffling when it loads — but it is marked
    /// only once it is KNOWN to be a media post.
    static func gridPostIDs(
        original: PostID?,
        using: [PostID],
        isMedia: (PostID) -> Bool?
    ) -> (ids: [PostID], original: PostID?) {
        let leading = original.flatMap { isMedia($0) == false ? nil : $0 }
        var ids: [PostID] = []
        var seen = Set<PostID>()
        for id in [leading].compactMap({ $0 }) + using where seen.insert(id).inserted {
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
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback
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

    /// The sheet's own track playing, or a feed opened from a tile: either
    /// covers the post behind. (The expanded detent pauses it too: the sheet
    /// is a declared cover, `ScreenCovering`.)
    private func refreshCover() {
        setCovering(isTrackEngaged || isShowingFeed)
    }

    // MARK: - The sheet's own track

    /// Whether the record plays the sound's preview.
    private(set) var isPreviewing = false
    /// Whether the sheet's track holds the sound: from its first play until
    /// the post is played again or the sheet goes. PAUSED, it still holds it
    /// (the owner, 2026-10-31): pausing the record does not hand the sound
    /// back to the post behind.
    private(set) var isTrackEngaged = false
    private var preview: AVPlayer?
    private var previewEndObserver: NSObjectProtocol?
    private var previewStart: Task<Void, Never>?
    /// Feeds the header's bar while the track plays (#1964): 30 fps, the
    /// Shots clip bar's feed (`SnapCellPlayback.startPlayheadFeed`).
    private var previewFeed: CADisplayLink?
    /// Where the track last stood, 0…1 — the bar holds it while paused.
    private var previewFraction: Double?

    private func togglePreview() {
        isPreviewing ? stopPreview() : startPreview()
    }

    private func startPreview() {
        guard let url = sound.previewURL, !isPreviewing else { return }
        isPreviewing = true
        isTrackEngaged = true
        setRecord(RecordPlayback(playing: true, available: record.available))
        refreshCover()
        // The bar shows from the first play: loading until the track says its
        // length, then its position (#1964).
        header?.setTrackProgress(previewFraction, loading: preview == nil)
        startPreviewFeed()
        // A transport control: silent (#1881).
        if let preview {
            preview.play()
            return
        }
        // The sound's address can be one only the pool opens (a clip's
        // original sound, `mock://` in the mock): resolved through it.
        let pool = videoPlayback
        previewStart = Task { [weak self] in
            let playable: URL
            if url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                playable = url
            } else if let resolved = try? await pool?.playableURL(for: url) {
                playable = resolved
            } else {
                self?.stopPreview()
                return
            }
            guard let self, isPreviewing, !Task.isCancelled else { return }
            let player = makePreviewPlayer(for: playable)
            player.actionAtItemEnd = .pause
            previewEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.loopPreview() }
            }
            preview = player
            header?.trackBar.isScrubbable = true
            player.play()
        }
    }

    /// The preview's player: through the pool's byte cache when there is one
    /// (#895), so a sound previewed twice, or a clip's original sound whose
    /// clip already played, is not fetched again.
    func makePreviewPlayer(for url: URL) -> AVPlayer {
        AVPlayer(playerItem: videoPlayback?.soundItem(for: url) ?? AVPlayerItem(url: url))
    }

    /// Pauses the sheet's own track: its record's tap, or the sheet going.
    /// The track keeps the sound (`isTrackEngaged`): the post behind stays
    /// paused, and the bar holds where the track is, so the next tap resumes
    /// visibly from there.
    func stopPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        preview?.pause()
        stopPreviewFeed()
        header?.setTrackProgress(previewFraction, loading: false)
        setRecord(RecordPlayback(playing: false, available: record.available))
    }

    /// The post was played again — the viewer's tap on it — or the sheet
    /// goes: the sheet's track gives the sound back (the two tracks never
    /// play together).
    func releaseTrack() {
        stopPreview()
        guard isTrackEngaged else { return }
        isTrackEngaged = false
        refreshCover()
    }

    /// The end of the track: it LOOPS (the owner, 2026-10-31) — back to the
    /// start, the bar with it, and on.
    fileprivate func loopPreview() {
        previewFraction = 0
        header?.setTrackProgress(0, loading: false)
        preview?.seek(to: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPreviewing else { return }
                self.preview?.play()
            }
        }
    }

    /// The preview's player and its observers go with the sheet.
    private func tearDownPreview() {
        previewStart?.cancel()
        previewStart = nil
        if let previewEndObserver { NotificationCenter.default.removeObserver(previewEndObserver) }
        previewEndObserver = nil
        stopPreviewFeed()
        previewFraction = nil
        header?.setTrackProgress(nil, loading: false)
        header?.trackBar.isScrubbable = false
        preview?.pause()
        preview = nil
    }

    // MARK: - The track's scrub (#1964)

    /// Whether the track was playing when the finger took the bar.
    private var resumesAfterTrackScrub = false
    /// A finger is dragging the bar: it moves the bar, not the player.
    private var isTrackScrubbing = false

    /// The finger took the bar: the track holds still under it (the record
    /// still says it plays — the scrub is a pause the viewer did not ask for).
    private func beginTrackScrub() {
        isTrackScrubbing = true
        resumesAfterTrackScrub = isPreviewing && preview?.timeControlStatus != .paused
        preview?.pause()
        stopPreviewFeed()
    }

    /// The bar asked for `fraction`. ⚠️ DRAGGING, THE BAR MOVES ALONE (the
    /// owner, 2026-10-31: the release stuttered against the video's): an
    /// exact seek per finger move kept a streamed track seeking, and the
    /// feed read the old position at the release and caught up with a jump.
    /// The player is moved once, where the finger lets go (`endTrackScrub`)
    /// — or here, for a tap.
    private func seekTrack(to fraction: Double) {
        previewFraction = fraction
        guard !isTrackScrubbing else { return }
        land(at: fraction, resuming: isPreviewing)
    }

    /// The finger let go at `fraction` (nil: cancelled).
    private func endTrackScrub(at fraction: Double?) {
        isTrackScrubbing = false
        let resumes = resumesAfterTrackScrub && isPreviewing
        resumesAfterTrackScrub = false
        guard let fraction else {
            if resumes { preview?.play(); startPreviewFeed() }
            return
        }
        land(at: fraction, resuming: resumes)
    }

    /// One exact seek; the track plays on — and the bar is fed again — only
    /// once the player has LANDED, as the video's bar waits for its seeks
    /// (`VideoPlaybackController.whenSeeksSettle`). Until then the bar holds
    /// the finger's position.
    private func land(at fraction: Double, resuming: Bool) {
        guard let player = preview, let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        stopPreviewFeed()
        player.seek(
            to: CMTime(seconds: duration * fraction, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] finished in
            MainActor.assumeIsolated {
                guard let self, finished else { return }
                if resuming, self.isPreviewing { player.play() }
                if self.isPreviewing {
                    self.startPreviewFeed()
                } else {
                    self.header?.setTrackProgress(fraction, loading: false)
                }
            }
        }
    }

    private func startPreviewFeed() {
        stopPreviewFeed()
        let link = CADisplayLink(target: PreviewFeedTarget(self), selector: #selector(PreviewFeedTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        previewFeed = link
    }

    private func stopPreviewFeed() {
        previewFeed?.invalidate()
        previewFeed = nil
    }

    /// One frame of the bar: the track's position against ITS OWN length —
    /// `sound.duration` can be missing — and loading while that length is
    /// unknown or the player waits.
    fileprivate func feedPreview() {
        guard isPreviewing else { return stopPreviewFeed() }
        guard let player = preview, let item = player.currentItem else {
            header?.setTrackProgress(previewFraction, loading: true)
            return
        }
        let duration = item.duration.seconds
        let current = player.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite else {
            header?.setTrackProgress(previewFraction, loading: true)
            return
        }
        let fraction = min(max(current / duration, 0), 1)
        previewFraction = fraction
        header?.setTrackProgress(fraction, loading: isStalled(player))
    }

    /// Since when the track has been waiting to play, if it is.
    private var previewWaitingSince: CFTimeInterval?
    /// How long a wait lasts before the bar says "loading".
    static let stallDelay: CFTimeInterval = 0.4

    /// ⚠️ A WAIT THAT LASTS, NOT EVERY WAIT (the owner, 2026-10-31: a micro
    /// jump at every release of the bar). A seek and its play leave the
    /// player waiting for a frame or two; called loading at once, the bar
    /// cross-faded to the pulse and dropped its cursor for a frame. The
    /// video's bar says it only for a wait the viewer would see.
    private func isStalled(_ player: AVPlayer) -> Bool {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            previewWaitingSince = nil
            return false
        }
        let now = CACurrentMediaTime()
        let since = previewWaitingSince ?? now
        previewWaitingSince = since
        return now - since >= Self.stallDelay
    }

    /// The feed's target, holding the sheet weakly: a link retains its target.
    @MainActor
    private final class PreviewFeedTarget: NSObject {
        weak var sheet: SoundSheetViewController?
        init(_ sheet: SoundSheetViewController) { self.sheet = sheet }
        @objc func tick(_ link: CADisplayLink) {
            guard let sheet else { return link.invalidate() }
            sheet.feedPreview()
        }
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
        closePresentation { select?(id) }
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
        isShowingFeed = true
        refreshCover()
        // The tapped tile's clip is parked for a close that pages on and comes
        // home to it (#951), on the screen it was tapped on.
        let screenAutoplay: SoundSheetAutoplay?
        switch source {
        case .gallery(let pushed): screenAutoplay = pushed.autoplay
        case .sheet: screenAutoplay = autoplay
        }
        screenAutoplay?.beginOpen(of: id)
        // The feed covers the tiles for the trip — its host is presented
        // over full screen, so no screen hears it disappear: told here. The
        // tapped tile is concealed, and its card flies its poster.
        setAutoplayActive(false)
        pushedGallery?.setAutoplayActive(false)
        OverSheetFeedHost.present(over: presenter, onFinished: { [weak self, weak screenAutoplay] in
            self?.isShowingFeed = false
            self?.refreshCover()
            self?.resumeTilesAfterFeed()
            screenAutoplay?.endOpen()
        }) { host in
            #if DEBUG
            Self.debugFeedHost = host
            #endif
            openFeedHero(stream.map(\.id), host, origin)
        }
        return true
    }

    /// Back from a feed opened from a tile: the screen the viewer is on
    /// plays its tiles again.
    private func resumeTilesAfterFeed() {
        // The NAVIGATION controller's window: a pushed section takes this
        // screen's view out of it.
        guard let navigation = navigationController, navigation.view.window != nil else { return }
        if navigation.topViewController === self {
            setAutoplayActive(true)
        } else if let gallery = pushedGallery, navigation.topViewController === gallery {
            gallery.setAutoplayActive(true)
        }
    }

    // MARK: - Autoplay

    /// The tiles are (or are no longer) the viewer's: on screen and not
    /// covered. Inactive, every one gives its player back at once.
    private func setAutoplayActive(_ active: Bool) {
        // Covered by a feed opened from a tile: minimum windows (#970).
        lookahead.setHidden(!active)
        guard let autoplay else { return }
        autoplay.setActive(active)
        guard active else { return }
        // An unrealised cell is not a candidate: laid out first.
        collectionView.layoutIfNeeded()
        reconcileAutoplay()
    }

    /// Reconciles the tiles' players against what is on screen now: the
    /// visible tiles that can be touched (`isRevealed` — what is faint does
    /// not play either), ranked and budgeted by `SoundSheetAutoplay`.
    func reconcileAutoplay(allowingStarts: Bool = true) {
        guard let autoplay, dataSource != nil else { return }
        let items = collectionView.indexPathsForVisibleItems.compactMap { path -> SoundSheetAutoplay.Item? in
            guard case .tile(let id, let kind) = dataSource.itemIdentifier(for: path),
                  isRevealed(kind, item: path.item),
                  let tile = tileByID[id],
                  let cell = collectionView.cellForItem(at: path) as? any SoundSheetTileDrawing
            else { return nil }
            return .init(tile: tile, cell: cell)
        }
        autoplay.reconcile(items, in: collectionView, allowingStarts: allowingStarts)
    }

    /// A reconcile at the end of this turn, once however often it is asked
    /// — for what calls from inside a layout pass (a row's sideways scroll)
    /// or on every frame (the reveal following the sheet's height).
    private func scheduleAutoplay() {
        guard autoplay != nil, !isAutoplayScheduled else { return }
        isAutoplayScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isAutoplayScheduled = false
            reconcileAutoplay()
        }
    }

    private var isAutoplayScheduled = false
    /// The lift a committed long press opens from, while the flight takes
    /// off (#1543) — the grid's rule (`ForYouGridPage.previewLaunch`).
    var previewLaunch: PreviewLaunch?

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
        let cell: () -> (any SoundSheetTileDrawing)? = { [weak self] in
            fromGallery ? gallery?.tileCell(for: id) : self?.tileCell(for: id, in: kind)
        }
        // The standard tile hides whole for a flight; the sheet's own knows
        // its own way (#1280).
        let conceal: (Bool) -> Void = { [weak self] concealed in
            // The lift the flight took off from goes with the tile (#1543).
            if concealed, !fromGallery, let launch = self?.previewLaunch, launch.postID == id { launch.conceal() }
            switch cell() {
            case let own as SoundSheetTileCell: own.setConcealed(concealed)
            case let standard?: standard.isHidden = concealed
            case nil: break
            }
        }
        let standard = tile.drawsStandardTile ? tile.post : nil
        let pipeline = imagePipeline
        let frame: (UICoordinateSpace) -> CGRect? = { [weak self] space in
            if fromGallery { return gallery?.tileFrame(for: id, in: space) }
            // ⚠️ A COMMITTED PREVIEW IS WHERE THE FLIGHT TAKES OFF (#1543):
            // the card leaves from the lift as captured at the commit
            // (`PreviewLaunch`), never back through the tile; once the
            // capture has expired, the tile is the answer.
            if let launch = self?.previewLaunch, launch.postID == id, let lift = launch.frame(in: space) {
                return lift
            }
            return self?.tileFrame(for: id, in: kind, space: space)
        }
        let cover = cell()?.renderedCover
        let presenter: UIViewController = gallery ?? self
        // Every tile is the same shape, and the one measured at the tap
        // stands in for a close that finds it scrolled out.
        let tappedSize = cell()?.bounds.size
        let traits = cell()?.traitCollection ?? traitCollection
        let standIn: () -> UIView? = {
            guard let size = cell()?.bounds.size ?? tappedSize else { return nil }
            if let standard {
                // The standard tile's twin, its words by size (#1280).
                return PostGridTileStandInView(
                    post: standard, size: size, cornerRadius: SoundSheetTileCell.cornerRadius,
                    imagePipeline: pipeline, showsInfo: true
                )
            }
            // The picture the tile shows NOW, or the one it showed at the tap.
            return SoundSheetTileCell.makeStandIn(
                for: tile, cover: cell()?.renderedCover ?? cover, size: size, traits: traits
            )
        }
        // ⚠️ THE CARD WEARS THE TILE'S COUNT. A `.tile` flight card draws the
        // post's likes at the tile's foot (`PostGridFlightCard`), and the
        // tile draws the count the feed knew when the sheet was dealt — the
        // repository's copy can be a like behind or ahead. The number the
        // card lands on is the one on the tile, or it changes in the frame
        // the card is taken away.
        var flown = post
        if let likes = tile.likeCount { flown.reactionCount = likes }
        // The screen the tile is on, whose players hold its parked clip (#951).
        let screenAutoplay: () -> SoundSheetAutoplay? = { [weak self] in
            fromGallery ? gallery?.autoplay : self?.autoplay
        }
        let hasThumbnail = tile.thumbnailURL != nil
        let videoURL = tile.videoURL
        return SnapFeedHeroOrigin(
            post: flown,
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
            setConcealed: { concealed in conceal(concealed) },
            // ⚠️ THE ONE TILE CONTRACT (#1280, epic #1269): the card takes off
            // PLAYING on the tile's own surface, and a close onto the same
            // post hands it back — the playhead continues, the card waiting
            // for the tile to draw.
            donateLiveMedia: {
                guard let videoURL else { return nil }
                return screenAutoplay()?.playback.tileFlightSurface(for: id, url: videoURL, cell: cell())
            },
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
                fill: standard.map(PostGridTileCell.fillColor(for:)) ?? SoundSheetTileCell.standInGround(traits: traits),
                setConcealed: { concealed in conceal(concealed) }
            ),
            // ⚠️ THE TILE'S OWN CORNER, AND ITS CURVE. Left to the style, the
            // card rounded as a For You brick (16pt) and landed on a 12pt tile:
            // the corners jumped in the frame the card was taken away — the
            // flash at the end of every close. A 12pt SQUIRCLE, like the tile.
            cornerRadius: SoundSheetTileCell.cornerRadius,
            cornerCurve: .continuous,
            adoptLandingLiveMedia: { view in
                guard let view = view as? VideoRenderView, let videoURL, let tileCell = cell() else { return }
                // In a drawing hierarchy first, or the surface lands invisible.
                conceal(false)
                screenAutoplay()?.playback.adoptTileLanding(view, for: id, url: videoURL, cell: tileCell)
            },
            landingMediaIsReady: {
                screenAutoplay()?.playback.isTileLandingReady(
                    for: id, expectsVideo: videoURL != nil, cell: cell(), hasThumbnail: hasThumbnail
                ) ?? true
            },
            // A close from another post comes home with the tile's OWN clip,
            // parked at the tap (#951) — never the page's. The source reveals
            // the tile before it lands it.
            returnLiveMedia: { screenAutoplay()?.playback.makeReturnSurface(for: id) },
            pauseReturnLiveMedia: { screenAutoplay()?.playback.pauseReturnPlayback(of: id) },
            adoptReturnLiveMedia: { view in
                guard let view = view as? VideoRenderView, let tileCell = cell() else { return }
                screenAutoplay()?.playback.landReturnPlayback(view, for: id, cell: tileCell)
            },
            returnLandingIsReady: {
                screenAutoplay()?.playback.isReturnLandingReady(
                    for: id, cell: cell(), hasThumbnail: hasThumbnail
                ) ?? true
            },
            // The tile's marks, worn at the source end and faded as the card
            // grows, so a close does not pop them on at the landing.
            restingOverlay: {
                guard let size = cell()?.bounds.size ?? tappedSize else { return nil }
                // The standard tile's words, faded in on a close (#1280).
                if let standard {
                    return PostGridTileCell.makeInfoOverlay(for: standard, restingSize: size, imagePipeline: pipeline)
                }
                return SoundSheetTileCell.makeBadgeOverlay(for: tile, size: size)
            }
        )
    }

    private func tileCell(for id: PostID, in kind: SoundSheetSection.Kind) -> (any SoundSheetTileDrawing)? {
        guard let path = dataSource.indexPath(for: .tile(id, kind)) else { return nil }
        return collectionView.cellForItem(at: path) as? any SoundSheetTileDrawing
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

    // MARK: - Actions

    private func useSound() {
        guard let onUseSound else { return }
        let sound = sound
        // "Use" opens the camera: a guest signs up first, then lands in it.
        MemberGates.perform(.useSound, from: self) { [weak self] in
            self?.closePresentation { onUseSound(sound) }
        }
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
    /// the reveal to follow the sheet's spring, and tells the window's covers
    /// (`coverChanged()`, #1970): the post behind plays under the collapsed
    /// sheet and pauses under the expanded one.
    fileprivate func detentChanged(to identifier: UISheetPresentationController.Detent.Identifier?) {
        let expanded = Self.isExpanded(identifier)
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        traceSettledHeight(expanded: expanded)
        reveal.wake()
        coverChanged()
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
        // Tiles start as they slide in and stop as they leave; nothing starts
        // during a hard fling (`GridAutoplayRanking.allowsStarts`).
        reconcileAutoplay(allowingStarts: GridAutoplayRanking.allowsStarts(
            atVelocity: scrollView.panGestureRecognizer.velocity(in: scrollView).y
        ))
        lookahead.scrollViewDidScroll()
        // The line follows the Popular row as the posts scroll.
        guard reveal.progress < 1 else { return }
        updateRevealLine()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
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

    // MARK: - The native preview (#1318)

    /// ⚠️ THE SOUND SHEET'S TILES LIFT TOO (the owner, 2026-10-17: every
    /// tile). The lift is the grid's (`ForYouPostPreviewViewController`, the
    /// clip playing inside it); the menu is the post's own rows (#1498 §3),
    /// with no author rows — the sheet has no road to a profile, and it is a
    /// sheet over the post, where the post itself carries them.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              case .tile(let id, let kind) = dataSource.itemIdentifier(for: indexPath),
              isRevealed(kind, item: indexPath.item),
              let tile = tileByID[id], tile.isLoaded, let post = tile.post
        else { return nil }
        let width = max(0, view.bounds.width - Spacing.lg * 2)
        let pipeline = imagePipeline
        let pool = videoPlayback
        return UIContextMenuConfiguration(
            identifier: id.rawValue as NSString,
            previewProvider: {
                ForYouPostPreviewViewController(post: post, imagePipeline: pipeline, width: width, videoPlayback: pool)
            },
            actionProvider: { [weak self, weak collectionView] _ in
                // The post's own rows (#1498 §3). No author submenu: the sheet
                // has no road to a profile, and it sits over the post, which
                // carries them; no Comment or Like, which the post's own
                // screen holds. A tap on the preview opens the post.
                let anchor: UIView? = collectionView?.cellForItem(at: indexPath) ?? self?.view
                guard let anchor else { return nil }
                let rows = PostMenuRows(bookmarks: PostBookmarkStore.shared).rows(for: post, anchor: anchor)
                return PostCardMenu.menu(for: rows, author: nil)
            }
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        tilePreview(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        // A committed lift fades where it is, under its flight (#1543).
        previewLaunch?.dismissalTarget() ?? tilePreview(at: indexPath)
    }

    /// Tapping the lift opens the post out of the lift itself (#1543): a
    /// picture's flight, or words' window (`TextRevealInstaller`).
    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let raw = configuration.identifier as? String else { return }
        let id = PostID(raw)
        guard let kind = sections.first(where: { $0.ids.contains(id) || $0.all.contains(id) })?.kind else { return }
        // From the lift, not back through the tile (#1543), captured now
        // (`heroOrigin`'s frame, or its window's).
        previewLaunch = PreviewLaunch.commit(animator, opening: id) { [weak self] in
            self?.openFromPreview(id, kind: kind)
        }
    }

    /// The tap's open, for a post lifted from `kind`'s tiles.
    private func openFromPreview(_ id: PostID, kind: SoundSheetSection.Kind) {
        guard let section = sections.first(where: { $0.kind == kind }) else { return }
        select(id, order: kind.isRow ? section.all : section.ids, source: .sheet(kind))
    }

    private func tilePreview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath), cell.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let card = cell.contentView
        let radius = max(card.layer.cornerRadius, cell.layer.cornerRadius)
        parameters.visiblePath = UIBezierPath(roundedRect: card.bounds, cornerRadius: radius)
        return UITargetedPreview(view: card, parameters: parameters)
    }

    #if DEBUG
    /// The lift a long press on item `item` of the posts would raise.
    func debugTileMenuConfiguration(at indexPath: IndexPath) -> UIContextMenuConfiguration? {
        collectionView(collectionView, contextMenuConfigurationForItemsAt: [indexPath], point: .zero)
    }
    #endif
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

extension SoundSheetViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === recordTap,
              let view = gestureRecognizer.view else { return true }
        return recordTakesTap(at: touch.location(in: view), in: view)
    }

    /// Alongside whatever the sheet's bar band runs on the same touch.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === recordTap
    }
}

// MARK: - Cover (#1970)

/// ⚠️ THE SHEET'S STATE, NOT A SHARE OF THE DISPLAY (#1914, the owner
/// 2026-10-31): its expanded detent can be a fitted one shorter than half
/// the screen, so the default table (large only) would miss it. It covers
/// while expanded; the gallery inside it is at its own level, never paused
/// by it.
extension SoundSheetViewController: ScreenCovering {
    var coversScreen: Bool { isExpanded }
}
