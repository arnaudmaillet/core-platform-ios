import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The side list (#1425): a leftward swipe on a post shrinks the whole
/// page — its interface included, nothing faded or re-laid out — into a
/// card, and slides a narrow vertical list of other current posts in on the
/// right (Kuaishou's "Works" strip). A tap on one puts it after the post on
/// show and moves to it; a rightward swipe puts everything back.
///
/// On every vertical feed by default since #1473 (the owner, 2026-10-20);
/// it was an experiment behind `-snap-side-list` before. A screen opts out
/// with `SnapFeedViewController.installsSideList` (tests do).
enum SnapSideList {
    /// Where everything sits at a `progress` from 0 (closed) to 1 (open).
    /// Pure, for tests.
    ///
    /// ⚠️ BETWEEN THE BARS (#1509, the owner's screenshot 2026-10-21): the
    /// card and the list sit between the top bar and the bottom toolbar, a
    /// gap from each, never under them.
    ///
    /// ⚠️ THE LIST FIRST (#1545, the owner 2026-10-21): it holds a whole
    /// number of tiles — 10 on an iPhone 18 Pro — exactly between the bars,
    /// so none is ever cut at rest; the card takes the width left. The card
    /// is the page scaled UNIFORMLY to that width (no re-layout of the page),
    /// and what overruns the height between the bars is cropped off its top
    /// and bottom (`pageInset`): the card's ratio changes, never the page's.
    struct Geometry: Equatable {
        /// The screen's bounds.
        let size: CGSize
        /// What the bars cover: `top` from the screen's top to the top bar's
        /// bottom, `bottom` from the bottom toolbar's top to the screen's
        /// bottom (safe areas included).
        var bars: UIEdgeInsets = .zero
        /// The device's own corner radius (`ScreenGeometry`): the page's
        /// corners when closed.
        var deviceCornerRadius: CGFloat = 0

        /// Between the card, the list, the bars and the screen's edges.
        static let gap: CGFloat = 6
        /// The card's corners when open, on screen (#1509).
        static let cornerRadius: CGFloat = 12
        /// ⚠️ THE LIST'S TILES WEAR THE CARD'S CORNER (the owner,
        /// 2026-10-21): the same radius side by side, where they used to be
        /// concentric with it (6 pt, a gap in).
        static var tileCornerRadius: CGFloat { cornerRadius }
        /// The list never narrower than this, whatever the bars leave.
        static let minimumListWidth: CGFloat = 44
        /// Between two tiles.
        static let tileSpacing: CGFloat = 6
        /// The tile height the count aims at: 10 tiles on an iPhone 18 Pro.
        static let targetTileHeight: CGFloat = 62
        /// The most tiles the list shows at once.
        static let maximumTiles = 10

        /// How many whole tiles the list shows: as many of about
        /// `targetTileHeight` as fill the height between the bars, at most
        /// `maximumTiles` — fewer on a shorter screen, never a cut one.
        var tileCount: Int {
            let height = openArea.height
            guard height > 0 else { return 1 }
            let fitting = ((height + Self.tileSpacing) / (Self.targetTileHeight + Self.tileSpacing)).rounded()
            return min(max(Int(fitting), 1), Self.maximumTiles)
        }

        /// The width of a tile per point of its height: 3:4, narrow, for the
        /// widest card. The owner tried square tiles beside it and kept these
        /// (device check, 2026-10-22; #1580).
        static let tileAspect: CGFloat = 3 / 4

        /// The list's height — the card's: the height between the bars, or
        /// less where the page scaled to the width the list leaves is
        /// shorter than that (an SE). Solved, since a shorter list makes
        /// narrower tiles and so a wider, taller card: `L = min(open,
        /// H · (W − 3g − a·(L − (n−1)s)/n) / W)`, linear in `L`.
        var listHeight: CGFloat {
            let open = openArea.height
            guard size.width > 0, size.height > 0, open > 0 else { return open }
            let count = CGFloat(tileCount), spacing = Self.tileSpacing
            let perPoint = Self.tileAspect / count
            let solved = size.height * (size.width - 3 * Self.gap + perPoint * (count - 1) * spacing)
                / (size.width + size.height * perPoint)
            return min(open, solved)
        }

        /// One tile: `tileCount` of them and their spacing fill the list's
        /// height exactly.
        var tileSize: CGSize {
            let count = CGFloat(tileCount)
            let height = max(0, (listHeight - Self.tileSpacing * (count - 1)) / count)
            return CGSize(width: max(height * Self.tileAspect, Self.minimumListWidth), height: height)
        }

        /// The open card's room: between the bars, a gap from each.
        var openArea: CGRect {
            let top = bars.top + Self.gap
            let bottom = size.height - bars.bottom - Self.gap
            return CGRect(x: 0, y: top, width: size.width, height: max(0, bottom - top))
        }

        /// The list's width: one tile's.
        var listWidth: CGFloat { tileSize.width }

        /// The card's scale when open: the page scaled to the width the list
        /// leaves (the screen less the list and 3 gaps).
        var cardScale: CGFloat {
            guard size.width > 0, size.height > 0 else { return 1 }
            return max(0.01, (size.width - listWidth - 3 * Self.gap) / size.width)
        }

        /// The open card, on screen: a gap from the leading edge, as tall as
        /// the scaled page allows within the bars, centred between them.
        var cardFrame: CGRect {
            let width = size.width * cardScale
            let height = min(size.height * cardScale, openArea.height)
            return CGRect(x: Self.gap, y: openArea.midY - height / 2, width: width, height: height)
        }

        /// How much of the page's top and bottom the card crops at
        /// `progress`, in the PAGE's own points: what the uniformly scaled
        /// page overruns the card's height by, halved — none closed.
        func pageInset(progress: CGFloat) -> CGFloat {
            let scale = 1 - (1 - cardScale) * progress
            let visible = size.height + (cardFrame.height - size.height) * progress
            let overrun = max(0, size.height * scale - visible) / 2
            return overrun / max(scale, 0.01)
        }

        /// The pager's transform: scaled about its centre, then moved onto
        /// the open card's frame.
        func pagerTransform(progress: CGFloat) -> CGAffineTransform {
            let scale = 1 - (1 - cardScale) * progress
            let shiftX = (cardFrame.midX - size.width / 2) * progress
            let shiftY = (cardFrame.midY - size.height / 2) * progress
            return CGAffineTransform(translationX: shiftX, y: shiftY).scaledBy(x: scale, y: scale)
        }

        /// The list beside the card, its top and bottom on the card's,
        /// sliding in from beyond the trailing edge.
        func listFrame(progress: CGFloat) -> CGRect {
            let card = cardFrame
            let openX = card.maxX + Self.gap
            let x = size.width + (openX - size.width) * progress
            return CGRect(x: x, y: card.minY, width: listWidth, height: card.height)
        }

        /// The page's corner ON SCREEN (#1509): the device's when closed,
        /// the card's when open, interpolated in between — never square.
        func screenCornerRadius(progress: CGFloat) -> CGFloat {
            deviceCornerRadius + (Self.cornerRadius - deviceCornerRadius) * progress
        }

        /// The gap kept under the overlay's lowest element once open (#1549,
        /// the owner 2026-10-21): the overlay's own horizontal margin (the
        /// caption's and the strip's leading inset), so it reads even all
        /// round.
        static let overlayBottomMargin: CGFloat = Spacing.lg

        /// How far the page's overlay moves down, in the page's own space
        /// (#1509): into the band the bottom toolbar covers, which holds
        /// nothing once the page is a card between the bars — less what the
        /// card crops off the page's bottom (#1545), and stopping
        /// `overlayBottomMargin` short of the card's foot (#1549). The
        /// overlay's lowest element rests at the toolbar band plus the
        /// strip's gap (`SnapChromeView.pageBarToolbarGap`) above the page's
        /// bottom.
        func overlayOffset(progress: CGFloat) -> CGFloat {
            let travel = bars.bottom + SnapChromeView.pageBarToolbarGap - Self.overlayBottomMargin
            return max(0, travel * progress - pageInset(progress: progress))
        }

        /// The finger's travel for a full open.
        var travel: CGFloat { max(80, size.width * 0.25) }

        /// Whether a release settles open: where the drag would carry on to,
        /// past half way (the flick projection UIKit's own interactive
        /// transitions use).
        func settlesOpen(progress: CGFloat, velocityX: CGFloat) -> Bool {
            let projected = progress - velocityX / travel * 0.15
            return projected > 0.5
        }
    }
}

extension SnapSideList {
    /// Where the list's scroll comes to rest (#1527, #1545). Pure, read off
    /// the tiles' frames in the list's content space, for tests.
    ///
    /// ⚠️ ONE RULE (#1545, the owner 2026-10-21: "un seul suffit"): the list
    /// holds a whole number of tiles exactly (`Geometry.tileCount`), so a
    /// tile's top on the top edge leaves the bottom tile whole on the bottom
    /// edge too — no by-direction pair, and no edge blur: nothing is cut at
    /// rest.
    enum Snapping {
        /// The offset a released scroll settles on: the tile top nearest the
        /// offset it would have stopped at (`proposed`), kept within the
        /// content.
        static func target(proposed: CGFloat, tiles: [CGRect], viewport: CGFloat, contentHeight: CGFloat) -> CGFloat {
            let maxOffset = max(0, contentHeight - viewport)
            guard let nearest = tiles.map(\.minY).min(by: { abs($0 - proposed) < abs($1 - proposed) }) else {
                return min(max(0, proposed), maxOffset)
            }
            return min(max(0, nearest), maxOffset)
        }

        /// The offset that shows `tile` whole from `offset`, moving as little
        /// as possible: its top on the top edge when the top edge cuts it,
        /// its bottom on the bottom edge when the bottom one does. Nil: it is
        /// whole already. A tile taller than the list shows its top.
        static func reveal(_ tile: CGRect, offset: CGFloat, viewport: CGFloat) -> CGFloat? {
            if tile.minY < offset || tile.height > viewport { return tile.minY == offset ? nil : tile.minY }
            if tile.maxY > offset + viewport { return tile.maxY - viewport }
            return nil
        }
    }
}

/// The side list's gesture, state and views, for one snap feed screen.
@MainActor
///
/// ⚠️ ITS DRAG IS THE SCREEN'S SWIPE CHAIN'S (#1525): no pan of its own. The
/// feed's `SwipeStageArbiter` picks it as the panel stage — leftward on a
/// media post, rightward while open — and hands it the drag
/// (`SwipePanel`); a leftward drag with the list open goes to the next stage,
/// the author's profile.
final class SnapSideListController: NSObject, SwipePanel {
    private weak var host: SnapFeedViewController?
    let listView: SnapSideListView
    /// 0 closed … 1 open.
    private(set) var progress: CGFloat = 0
    private var startProgress: CGFloat = 0
    private(set) var isSettling = false
    /// A drag drives the list now.
    private var isDragging = false
    private var loadTask: Task<Void, Never>?
    /// The post the list on show was made for (#1509: a new list per
    /// anchor, cached while the screen lives — `SnapFeedViewController
    /// .sideListCandidates`).
    private var loadedAnchor: PostID?

    /// Open, opening or closing: the screen's dismissals stand aside.
    var isEngaged: Bool {
        progress > 0 || isSettling || isDragging
    }

    var isOpen: Bool { progress >= 1 }

    init(host: SnapFeedViewController, imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController? = nil) {
        self.host = host
        listView = SnapSideListView(imagePipeline: imagePipeline)
        // Its video tiles loop, muted, on the app's one pool (#1509).
        listView.autoplay = videoPlayback.map { SnapSideListAutoplay(pool: $0, imagePipeline: imagePipeline) }
        // The post on show's tile mirrors the card's playback (#1581).
        listView.autoplay?.cardSurface = { [weak host] id in host?.liveVideoSurface(for: id) }
        super.init()
        listView.isHidden = true
        listView.onSelect = { [weak self] entry in self?.host?.showSideListEntry(entry) }
    }

    func install(in view: UIView) {
        view.addSubview(listView)
    }

    private var geometry: SnapSideList.Geometry {
        guard let host else { return SnapSideList.Geometry(size: .zero) }
        return SnapSideList.Geometry(
            size: host.view.bounds.size, bars: host.sideListBars,
            deviceCornerRadius: ScreenGeometry.cornerRadius(behind: host.view)
        )
    }

    /// Re-applies the pose (a rotation, a first layout).
    func relayout() {
        guard progress > 0 else { return }
        apply(progress)
    }

    private func apply(_ value: CGFloat) {
        guard let host else { return }
        progress = value
        let geometry = geometry
        let pager = host.collectionView!
        pager.transform = geometry.pagerTransform(progress: value)
        applyCardShape(geometry, progress: value)
        host.setSideListOverlayOffset(geometry.overlayOffset(progress: value))
        listView.tileSize = geometry.tileSize
        listView.frame = geometry.listFrame(progress: value)
        if value > 0 { listView.isHidden = false }
        // A paused clip's mark crosses from the card to its tile with the
        // move, not at its end (#1580).
        host.sideListPoseDidChange(progress: value)
    }

    /// The card's shape (#1545): the scaled page cropped top and bottom to
    /// the card's height, its corners rounded — a mask VIEW in the pager's
    /// own space (where its scroll moves it), so the open and close springs
    /// animate it with the transform — and a hairline around it on screen,
    /// so a light page reads as a card on a light ground.
    private func applyCardShape(_ geometry: SnapSideList.Geometry, progress value: CGFloat) {
        guard let host, let pager = host.collectionView else { return }
        guard value > 0 else {
            pager.mask = nil
            cardOutline.removeFromSuperview()
            return
        }
        let scale = 1 - (1 - geometry.cardScale) * value
        let inset = geometry.pageInset(progress: value)
        let radius = geometry.screenCornerRadius(progress: value)
        cardMask.backgroundColor = .black
        cardMask.layer.cornerCurve = .continuous
        cardMask.frame = pager.bounds.insetBy(dx: 0, dy: inset)
        cardMask.layer.cornerRadius = radius / max(scale, 0.01)
        if pager.mask !== cardMask { pager.mask = cardMask }
        // On screen: the transformed pager's frame, less the crop.
        if cardOutline.superview !== host.view {
            cardOutline.isUserInteractionEnabled = false
            cardOutline.layer.borderWidth = 0.5
            cardOutline.layer.cornerCurve = .continuous
            host.view.insertSubview(cardOutline, aboveSubview: pager)
        }
        cardOutline.frame = pager.frame.insetBy(dx: 0, dy: inset * scale)
        cardOutline.layer.cornerRadius = radius
        cardOutline.layer.borderColor = UIColor.separator.resolvedColor(with: host.traitCollection).cgColor
    }

    private let cardMask = UIView()
    private let cardOutline = UIView()

    /// The pager scrolled: its crop is in its own space, and moves with it.
    func pagerDidScroll() {
        guard progress > 0, !isSettling else { return }
        UIView.performWithoutAnimation { applyCardShape(geometry, progress: progress) }
    }

    // MARK: The drag (`SwipePanel`, driven by the screen's arbiter)

    func panelDragDidBegin() {
        guard let host else { return }
        isDragging = true
        startProgress = progress
        host.setContentScrollEnabled(false)
        loadIfNeeded()
    }

    func panelDragDidChange(translationX: CGFloat) {
        apply(min(1, max(0, startProgress - translationX / geometry.travel)))
    }

    func panelDragDidEnd(velocityX: CGFloat) {
        isDragging = false
        settle(open: geometry.settlesOpen(progress: progress, velocityX: velocityX))
    }

    func panelDragDidCancel() {
        isDragging = false
        settle(open: startProgress >= 1)
    }

    /// Springs to open or closed, then gives the pager back.
    func settle(open: Bool, animated: Bool = true) {
        isSettling = true
        let finish = { [weak self] in
            guard let self else { return }
            isSettling = false
            if !open { listView.isHidden = true }
            // The tiles play while the list is open, and only then.
            listView.setPlaying(open)
            host?.setContentScrollEnabled(true)
            host?.sideListDidSettle(open: open)
        }
        guard animated else {
            apply(open ? 1 : 0)
            finish()
            return
        }
        // A first open with no pose yet (a release before any `.changed`,
        // the QA hook): the list starts beyond the trailing edge, not from
        // the screen's corner where a never-placed frame sits.
        if listView.frame == .zero {
            UIView.performWithoutAnimation { apply(progress) }
        }
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.apply(open ? 1 : 0)
        } completion: { _ in finish() }
    }

    // MARK: The list

    func loadIfNeeded() {
        // While the list drives the card, it is the list on show.
        guard loadTask == nil, let host, !host.isSideListSessionActive,
              let anchor = host.activePostID, anchor != loadedAnchor,
              // Reopened on a post picked in the list on show: kept, and
              // where it was scrolled (#1580).
              host.sideListResumeAnchor != loadedAnchor || loadedAnchor == nil else { return }
        loadTask = Task { [weak self, weak host] in
            let entries = await host?.sideListCandidates() ?? []
            guard let self else { return }
            loadTask = nil
            loadedAnchor = anchor
            listView.show(entries)
            listView.autoplay?.mirror(host?.activePostID)
            listView.outline(anchor)
            // Settled open before the list came: it drives the card now.
            if isOpen { host?.beginSideListSessionIfNeeded() }
        }
    }

    #if DEBUG
    /// Opens the list as a released drag would: loads it, springs open.
    func debugOpen() {
        loadIfNeeded()
        host?.setContentScrollEnabled(false)
        settle(open: true)
    }
    #endif

    /// The post on show changed: outlined in the list when it is one of its.
    func activePostDidChange(_ id: PostID?) {
        listView.autoplay?.mirror(id)
        // The tile left behind plays on its own again; the new one mirrors.
        if listView.autoplay?.isActive == true { listView.reconcileNow() }
        listView.outline(id)
    }
}

/// The narrow strip of post thumbnails.
@MainActor
final class SnapSideListView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let imagePipeline: ImagePipeline
    private let collection: UICollectionView
    private(set) var entries: [FeedEntry] = []
    /// The video tiles playing on their own, muted (#1509). Nil: none do
    /// (no pool, tests).
    var autoplay: SnapSideListAutoplay?
    private var outlined: PostID?
    /// The stopped mark on the tile of the post on show, when its clip was
    /// paused from the list (#1550): the card's own component, sized to the
    /// tile.
    private let tileMark: PausedClipMarkView = {
        let mark = PausedClipMarkView()
        mark.contentMode = .scaleAspectFit
        return mark
    }()
    private var pausedMarkID: PostID?
    /// The mark's glyph, as a share of the tile's width.
    static let tileMarkScale: CGFloat = 0.42

    /// Shows or takes down the stopped mark on `id`'s tile (#1550).
    func setPausedMark(_ visible: Bool, on id: PostID?, animated: Bool = true) {
        pausedMarkID = visible ? id : nil
        if !visible { pausedMarkShare = 1 }
        guard visible, let id, let index = entries.firstIndex(where: { $0.post.id == id }),
              let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) else {
            tileMark.setVisible(false, animated: animated)
            return
        }
        attachMark(to: cell)
        tileMark.setVisible(true, animated: animated)
        tileMark.alpha = pausedMarkShare
    }

    /// The tile's mark's share while the list's move carries it from the
    /// card (#1580): its opacity, from 0 closed to 1 open — the card's mark
    /// wears the rest. Kept for a tile drawn later in the move.
    func setPausedMarkShare(_ share: CGFloat) {
        pausedMarkShare = share
        if tileMark.superview != nil { tileMark.alpha = share }
    }

    private var pausedMarkShare: CGFloat = 1

    /// On the CELL, above its content: a tile's looping clip mounts its
    /// surface in the content after the mark, and covered it.
    private func attachMark(to cell: UICollectionViewCell) {
        let side = cell.bounds.width * Self.tileMarkScale
        tileMark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        tileMark.center = CGPoint(x: cell.bounds.midX, y: cell.bounds.midY)
        if tileMark.superview !== cell { cell.addSubview(tileMark) }
        cell.bringSubviewToFront(tileMark)
    }

    /// Whether `id`'s tile wears the stopped mark. Tests.
    func debugShowsPausedMark(on id: PostID) -> Bool {
        pausedMarkID == id && tileMark.isShowing && tileMark.superview != nil
    }

    /// The list's viewport corner. Tests.
    var debugViewportCornerRadius: CGFloat { collection.clipsToBounds ? collection.layer.cornerRadius : 0 }

    /// The tile's mark's opacity. Tests.
    var debugPausedMarkAlpha: CGFloat { tileMark.alpha }

    /// How much each tile wears the ring, 0…1 (#1546): the post on show's
    /// alone at rest, two sharing it while the card moves between them.
    private var ringWeights: [PostID: CGFloat] = [:]
    var onSelect: ((FeedEntry) -> Void)?
    /// One tile, from the geometry (#1545): a whole number of them fills
    /// the list exactly. Zero: not placed yet — a 3:4 tile of the width.
    var tileSize: CGSize = .zero {
        didSet { if tileSize != oldValue { collection.collectionViewLayout.invalidateLayout() } }
    }
    /// The skeletons over the tiles whose media is on its way (#1553), by
    /// cell.
    private var bones: [ObjectIdentifier: UIView] = [:]

    static var tileSpacing: CGFloat { SnapSideList.Geometry.tileSpacing }
    /// Before the geometry places the list: portrait, as a post's media is.
    static let fallbackTileAspect: CGFloat = 4 / 3

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = Self.tileSpacing
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        collection.backgroundColor = .clear
        // ⚠️ THE LIST'S EDGES WEAR THE TILES' CORNER (the owner, 2026-10-22):
        // scrolled, a tile met the list's top and bottom on a flat cut; the
        // viewport is rounded like a tile, so a tile half out is a rounded
        // shape too.
        collection.layer.cornerRadius = SnapSideList.Geometry.tileCornerRadius
        collection.layer.cornerCurve = .continuous
        collection.clipsToBounds = true
        collection.showsVerticalScrollIndicator = false
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(PostGridTileCell.self, forCellWithReuseIdentifier: PostGridTileCell.reuseID)
        collection.frame = bounds
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(collection)
        accessibilityIdentifier = "snap.sideList"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ entries: [FeedEntry]) {
        self.entries = entries
        collection.reloadData()
        collection.layoutIfNeeded()
        // A new list starts at its top: its first tile is the post on show
        // (#1509) — wherever the last list was scrolled.
        collection.setContentOffset(CGPoint(x: 0, y: -collection.adjustedContentInset.top), animated: false)
        reconcilePlayback()
    }

    /// The tiles' frames, in the content's space.
    private var tileFrames: [CGRect] {
        (0..<collection.numberOfItems(inSection: 0)).compactMap {
            collection.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
    }

    /// Settles a released scroll on whole tiles (#1545): a tile's top on
    /// the top edge, the one it was going to stop nearest.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        targetContentOffset.pointee.y = SnapSideList.Snapping.target(
            proposed: targetContentOffset.pointee.y, tiles: tileFrames,
            viewport: scrollView.bounds.height, contentHeight: scrollView.contentSize.height
        )
    }

    /// The list is open (its tiles may play) or closed (they give their
    /// players back now).
    func setPlaying(_ playing: Bool) {
        autoplay?.setActive(playing)
        if playing { reconcilePlayback() }
    }

    /// Reconciles now (the post on show changed, #1581).
    func reconcileNow() { reconcilePlayback() }

    /// Where `id`'s tile's own clip is, in seconds — nil when it plays none
    /// (#1581: a picked post's card starts on that frame).
    func tilePlayhead(for id: PostID) -> (url: URL, seconds: Double)? {
        guard let autoplay, let index = entries.firstIndex(where: { $0.post.id == id }),
              let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? PostGridTileCell,
              let surface = cell.loadedVideoRenderView,
              let url = ForYouRepository.galleryPost(from: entries[index]).videoURL,
              let seconds = autoplay.playheadSeconds(in: surface) else { return nil }
        return (url, seconds)
    }

    /// Reconciles the tiles' players against the tiles on screen.
    private func reconcilePlayback() {
        guard let autoplay else { return }
        let items = collection.indexPathsForVisibleItems.compactMap { path -> SnapSideListAutoplay.Item? in
            guard entries.indices.contains(path.item),
                  let cell = collection.cellForItem(at: path) as? PostGridTileCell else { return nil }
            return .init(post: ForYouRepository.galleryPost(from: entries[path.item]), cell: cell)
        }
        autoplay.reconcile(items, in: collection)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reconcilePlayback()
    }

    /// ⚠️ RESTYLED AS IT COMES ON SCREEN (the owner, 2026-10-22: at either
    /// end of the list, the tile the card paged onto wore no ring). The list
    /// PREFETCHES: a cell is made — and ringed for the post on show then —
    /// before it is visible, and `setRing` restyles visible cells only, so
    /// the tile scrolled in by the card's next page kept the ring of when it
    /// was made: none.
    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        style(cell, at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        autoplay?.stop(cell)
    }

    func outline(_ id: PostID?) {
        outlined = id
        // Settled on `id`: the ring is its alone — what the card's scroll
        // left there already, so nothing visibly changes.
        ringWeights = id.map { [$0: 1] } ?? [:]
        restyleVisibleCells(animated: false)
        // ⚠️ JUST ENOUGH TO SHOW IT WHOLE (#1527): a tile cut by an edge —
        // tapped, or reached by paging the card — comes fully into view on
        // that edge; a whole one does not move. It used to be centred, which
        // left its neighbours cut.
        // ⚠️ NEVER AGAINST AN EMPTY VIEWPORT (#1580): the list loads as a
        // swipe begins, often at once from its cache, before any pose has
        // placed it. Against 0 pt, "show the first tile whole" scrolled a
        // tile and a half past it, for the whole opening, and the outline at
        // the settle scrolled back — the owner's recording.
        guard collection.bounds.height > 0 else { return }
        if let id, let index = entries.firstIndex(where: { $0.post.id == id }),
           let tile = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame,
           let offset = SnapSideList.Snapping.reveal(
               tile, offset: collection.contentOffset.y, viewport: collection.bounds.height
           ) {
            let maxOffset = max(0, collection.contentSize.height - collection.bounds.height)
            collection.setContentOffset(CGPoint(x: 0, y: min(max(0, offset), maxOffset)), animated: true)
        }
    }

    /// Each tile's share of the ring, from the card's scroll (#1546).
    /// `animated`: a jump with no finger behind it, faded rather than cut.
    func setRing(_ weights: [PostID: CGFloat], animated: Bool) {
        guard weights != ringWeights else { return }
        ringWeights = weights
        restyleVisibleCells(animated: animated)
    }

    private func restyleVisibleCells(animated: Bool) {
        for cell in collection.visibleCells {
            guard let path = collection.indexPath(for: cell) else { continue }
            style(cell, at: path, animated: animated)
        }
    }

    /// The ring's width at full strength, and the hairline's at none.
    static let ringWidth: CGFloat = 2
    static let hairlineWidth: CGFloat = 0.5

    private func style(_ cell: UICollectionViewCell, at path: IndexPath, animated: Bool = false) {
        let weight = entries.indices.contains(path.item) ? ringWeights[entries[path.item].post.id] ?? 0 : 0
        // The post on show: a 2 pt border in the app's tint, concentric with
        // the tile's corner (#1509). The rest: a hairline, so a text tile (a
        // card on the page's own ground) still reads as a tile. In between —
        // the card moving between two posts — a blend of the two (#1546).
        let width = Self.hairlineWidth + (Self.ringWidth - Self.hairlineWidth) * weight
        // The design system's blend (`HeroInk.blend`), resolved for this list.
        let color = HeroInk.blend(page: .separator, picture: Palette.tint, onPicture: weight)
            .resolvedColor(with: traitCollection).cgColor
        let layer = cell.contentView.layer
        if animated, window != nil, !UIAccessibility.isReduceMotionEnabled {
            for (key, value) in [("borderWidth", width as Any), ("borderColor", color as Any)] {
                let fade = CABasicAnimation(keyPath: key)
                fade.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
                fade.toValue = value
                fade.duration = 0.2
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "ring." + key)
            }
        }
        layer.borderWidth = width
        layer.borderColor = color
    }

    /// A tile's ring: its border's width and how much of the tint it is.
    /// Tests.
    func debugRing(at index: Int) -> (width: CGFloat, weight: CGFloat)? {
        guard entries.indices.contains(index),
              let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) else { return nil }
        return (cell.contentView.layer.borderWidth, ringWeights[entries[index].post.id] ?? 0)
    }

    /// Whether `id`'s tile wears the indicator border. Tests.
    var outlinedPostID: PostID? { outlined }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath)
        if let tile = cell as? PostGridTileCell {
            tile.cornerRadius = SnapSideList.Geometry.tileCornerRadius
            let entry = entries[indexPath.item]
            // A text post's tile is its words; a picture speaks for itself.
            tile.configure(
                with: ForYouRepository.galleryPost(from: entry), imagePipeline: imagePipeline,
                showsInfo: entry.post.attachments.isEmpty
            )
            // A cover landing late is when a still tile may start, and when
            // its skeleton gives way (#1553).
            tile.onCoverLoaded = { [weak self, weak tile] in
                guard let self else { return }
                if let tile { removeBone(from: tile, animated: true) }
                reconcilePlayback()
            }
            tile.onCoverFailed = { [weak self, weak tile] in
                guard let self, let tile else { return }
                stillBone(on: tile)
            }
            // A media tile whose cover is not drawn yet wears a skeleton; a
            // resident one, or a text tile (its words), none.
            if !entry.post.attachments.isEmpty, tile.renderedCover == nil {
                showBone(on: tile)
            } else {
                removeBone(from: tile, animated: false)
            }
        }
        cell.contentView.layer.cornerRadius = SnapSideList.Geometry.tileCornerRadius
        cell.contentView.layer.cornerCurve = .continuous
        style(cell, at: indexPath)
        // The stopped mark follows its post's tile through reuse (#1550).
        if entries[indexPath.item].post.id == pausedMarkID {
            attachMark(to: cell)
            tileMark.setVisible(true, animated: false)
            tileMark.alpha = pausedMarkShare
        } else if tileMark.superview === cell {
            tileMark.removeFromSuperview()
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        if tileSize.width > 0, tileSize.height > 0 { return tileSize }
        let width = collectionView.bounds.width
        return CGSize(width: width, height: (width * Self.fallbackTileAspect).rounded())
    }

    // MARK: Skeletons (#1553)

    /// The app's shimmering bone over `tile`, on its own shape. It stills
    /// itself under Reduce Motion and Power Saving (`SkeletonBoneView`).
    private func showBone(on tile: PostGridTileCell) {
        let key = ObjectIdentifier(tile)
        let bone = bones[key] ?? {
            let bone = SkeletonBoneView(rounding: .fixed(SnapSideList.Geometry.tileCornerRadius))
            bones[key] = bone
            return bone
        }()
        bone.alpha = 1
        bone.frame = tile.contentView.bounds
        bone.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if bone.superview !== tile.contentView { tile.contentView.addSubview(bone) }
    }

    /// The cover landed: the bone fades to the picture.
    private func removeBone(from tile: PostGridTileCell, animated: Bool) {
        guard let bone = bones.removeValue(forKey: ObjectIdentifier(tile)) else { return }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            return bone.removeFromSuperview()
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) {
            bone.alpha = 0
        } completion: { _ in bone.removeFromSuperview() }
    }

    /// The cover failed: a still bone, never an endless shimmer — the
    /// emotes' rule (#1504).
    private func stillBone(on tile: PostGridTileCell) {
        let key = ObjectIdentifier(tile)
        guard let bone = bones[key], bone is SkeletonBoneView else { return }
        let still = UIView(frame: bone.frame)
        still.autoresizingMask = bone.autoresizingMask
        still.isUserInteractionEnabled = false
        still.backgroundColor = .tertiarySystemFill
        still.layer.cornerRadius = SnapSideList.Geometry.tileCornerRadius
        still.layer.cornerCurve = .continuous
        bone.superview?.insertSubview(still, aboveSubview: bone)
        bone.removeFromSuperview()
        bones[key] = still
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard entries.indices.contains(indexPath.item) else { return }
        onSelect?(entries[indexPath.item])
    }

    #if DEBUG
    /// The list's scroll offset. Tests.
    var debugOffset: CGFloat {
        get { collection.contentOffset.y }
        set { collection.contentOffset.y = newValue }
    }
    var debugTileFrames: [CGRect] { tileFrames }
    /// Whether `cell` wears a skeleton, and whether it shimmers. Tests.
    func debugBone(on cell: PostGridTileCell) -> (shown: Bool, shimmers: Bool) {
        guard let bone = bones[ObjectIdentifier(cell)], bone.superview != nil else { return (false, false) }
        return (true, bone is SkeletonBoneView)
    }

    /// The tiles on screen. Tests.
    var debugTileCells: [PostGridTileCell] { collection.visibleCells.compactMap { $0 as? PostGridTileCell } }
    /// The strip itself. Tests.
    var debugCollection: UICollectionView { collection }

    /// Selects the item at `index`, for a QA hook or a test.
    func debugSelect(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        onSelect?(entries[index])
    }
    #endif
}
