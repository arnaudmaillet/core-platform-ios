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
    /// card used to be scaled by the WIDTH alone and centred, so it ran
    /// under both bars — the back button on its top edge, the author pill
    /// and the actions over its bottom. It is now the page scaled UNIFORMLY
    /// to fit the height between the top bar and the bottom toolbar, a gap
    /// from each, and the list takes the width left.
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

        /// The open card's room: between the bars, a gap from each.
        var openArea: CGRect {
            let top = bars.top + Self.gap
            let bottom = size.height - bars.bottom - Self.gap
            return CGRect(x: 0, y: top, width: size.width, height: max(0, bottom - top))
        }

        /// The card's scale when open: the page fitted to the height between
        /// the bars, kept narrow enough to leave the list its minimum.
        var cardScale: CGFloat {
            guard size.width > 0, size.height > 0 else { return 1 }
            let fitsHeight = openArea.height / size.height
            let leavesList = (size.width - Self.minimumListWidth - 3 * Self.gap) / size.width
            return max(0.01, min(fitsHeight, leavesList))
        }

        /// The open card, on screen: a gap from the leading edge, centred
        /// between the bars.
        var cardFrame: CGRect {
            let width = size.width * cardScale, height = size.height * cardScale
            return CGRect(x: Self.gap, y: openArea.midY - height / 2, width: width, height: height)
        }

        /// The width the card leaves: the screen less the card and 3 gaps.
        var listWidth: CGFloat { max(Self.minimumListWidth, size.width - cardFrame.width - 3 * Self.gap) }

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

        /// How far the page's overlay moves down, in the page's own space
        /// (#1509): by the band the bottom toolbar covers, which holds
        /// nothing once the page is a card between the bars.
        func overlayOffset(progress: CGFloat) -> CGFloat {
            bars.bottom * progress
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
    /// Where the list's scroll comes to rest, and what it shows at its edges
    /// (#1527). Pure, read off the tiles' frames in the list's content space,
    /// for tests.
    ///
    /// ⚠️ A TILE IS NEVER LEFT CUT BY AN EDGE AT REST (the owner,
    /// 2026-10-21): a drag going down settles with the top tile whole at the
    /// top edge, one going up with the bottom tile whole at the bottom edge,
    /// and a tap on a cut tile scrolls just enough to show it whole. While a
    /// tile IS cut — mid-scroll — that edge wears a soft blur, gone again
    /// once the tile is whole.
    enum Snapping {
        /// Which way the list's content travels under the finger.
        enum Direction: Equatable {
            /// Towards later tiles: the offset grows.
            case down
            /// Towards earlier tiles.
            case up
        }

        /// The offset a scroll released towards `direction` settles on, the
        /// tile edge nearest the offset it would have stopped at (`proposed`)
        /// — a tile's top on the top edge going down, its bottom on the
        /// bottom edge going up — kept within the content.
        static func target(
            proposed: CGFloat, direction: Direction, tiles: [CGRect], viewport: CGFloat, contentHeight: CGFloat
        ) -> CGFloat {
            let maxOffset = max(0, contentHeight - viewport)
            let candidates = tiles.map { direction == .down ? $0.minY : $0.maxY - viewport }
            guard let nearest = candidates.min(by: { abs($0 - proposed) < abs($1 - proposed) }) else {
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

        /// How much of a tile each edge hides at `offset`, in points: zero
        /// when the edge falls between tiles or on a tile's own edge.
        static func cuts(offset: CGFloat, viewport: CGFloat, tiles: [CGRect]) -> (top: CGFloat, bottom: CGFloat) {
            let bottomEdge = offset + viewport
            let top = tiles.first { $0.minY < offset && offset < $0.maxY }.map { offset - $0.minY } ?? 0
            let bottom = tiles.first { $0.minY < bottomEdge && bottomEdge < $0.maxY }.map { $0.maxY - bottomEdge } ?? 0
            return (top, bottom)
        }

        /// The edge blur's height.
        static let blurHeight: CGFloat = 40
        /// How far a tile goes past an edge before that edge's blur is full:
        /// it eases in over the first points of the cut and out over the
        /// last, following the scroll — never popping.
        static let blurRamp: CGFloat = 24

        /// An edge's blur strength (0…1) for a tile cut by `cut` points.
        static func blurStrength(cut: CGFloat) -> CGFloat {
            let linear = min(1, max(0, cut / blurRamp))
            // Smoothstep: no visible corner where it starts or saturates.
            return linear * linear * (3 - 2 * linear)
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
        let scale = 1 - (1 - geometry.cardScale) * value
        // On screen, divided by the scale the layer wears. Closed, nothing
        // to round: the page is the screen.
        pager.layer.cornerRadius = value > 0 ? geometry.screenCornerRadius(progress: value) / max(scale, 0.01) : 0
        pager.layer.cornerCurve = .continuous
        host.setSideListOverlayOffset(geometry.overlayOffset(progress: value))
        // A hairline, so a light page reads as a card on a light ground.
        pager.layer.borderWidth = value > 0 ? 0.5 / max(scale, 0.01) : 0
        pager.layer.borderColor = UIColor.separator.resolvedColor(with: host.traitCollection).cgColor
        // Its tiles start below the top bar and end above the bottom one:
        // the list's own safe area, which UIKit insets it by.
        listView.frame = geometry.listFrame(progress: value)
        if value > 0 { listView.isHidden = false }
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
              let anchor = host.activePostID, anchor != loadedAnchor else { return }
        loadTask = Task { [weak self, weak host] in
            let entries = await host?.sideListCandidates() ?? []
            guard let self else { return }
            loadTask = nil
            loadedAnchor = anchor
            listView.show(entries)
            listView.autoplay?.focus(anchor)
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
        listView.autoplay?.focus(id)
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
    var onSelect: ((FeedEntry) -> Void)?
    /// The soft blur over the top and bottom edges while a tile is cut
    /// there (#1527). The system's material, set once on screen.
    private let topBlur = ProgressiveFrostView(maskColors: [.black, .clear], maskLocations: [0, 1])
    private let bottomBlur = ProgressiveFrostView(maskColors: [.clear, .black], maskLocations: [0, 1])
    /// The way the content last moved, for a release with no speed.
    private var lastDirection: SnapSideList.Snapping.Direction = .down
    private var lastOffset: CGFloat = 0

    static let tileSpacing: CGFloat = 6
    /// Portrait, as a post's media is.
    static let tileAspect: CGFloat = 4 / 3

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = Self.tileSpacing
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        collection.backgroundColor = .clear
        collection.showsVerticalScrollIndicator = false
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(PostGridTileCell.self, forCellWithReuseIdentifier: PostGridTileCell.reuseID)
        collection.frame = bounds
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(collection)
        for blur in [topBlur, bottomBlur] {
            blur.isHidden = true
            addSubview(blur)
        }
        accessibilityIdentifier = "snap.sideList"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ entries: [FeedEntry]) {
        self.entries = entries
        collection.reloadData()
        collection.layoutIfNeeded()
        reconcilePlayback()
        updateEdgeBlurs()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // On screen, never in `init`: a blur made there stalls a headless
        // test host (see `ProgressiveFrostView`'s users).
        guard window != nil else { return }
        for blur in [topBlur, bottomBlur] where blur.effect == nil {
            blur.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = min(SnapSideList.Snapping.blurHeight, bounds.height / 2)
        topBlur.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        bottomBlur.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        updateEdgeBlurs()
    }

    /// The tiles' frames, in the content's space.
    private var tileFrames: [CGRect] {
        (0..<collection.numberOfItems(inSection: 0)).compactMap {
            collection.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
    }

    /// Each edge's blur, as strong as the tile it cuts is cut.
    private func updateEdgeBlurs() {
        // The tiles on screen only: this runs every frame of a scroll.
        let onScreen = collection.collectionViewLayout.layoutAttributesForElements(in: collection.bounds)?
            .filter { $0.representedElementCategory == .cell }.map(\.frame) ?? []
        let cuts = SnapSideList.Snapping.cuts(
            offset: collection.contentOffset.y, viewport: collection.bounds.height, tiles: onScreen
        )
        topBlur.setRampStrength(SnapSideList.Snapping.blurStrength(cut: cuts.top))
        bottomBlur.setRampStrength(SnapSideList.Snapping.blurStrength(cut: cuts.bottom))
    }

    /// Settles a released scroll on a whole tile (#1527): the one it was
    /// going to stop on, by the way it was going.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let direction: SnapSideList.Snapping.Direction = velocity.y > 0 ? .down : velocity.y < 0 ? .up : lastDirection
        targetContentOffset.pointee.y = SnapSideList.Snapping.target(
            proposed: targetContentOffset.pointee.y, direction: direction, tiles: tileFrames,
            viewport: scrollView.bounds.height, contentHeight: scrollView.contentSize.height
        )
    }

    /// The list is open (its tiles may play) or closed (they give their
    /// players back now).
    func setPlaying(_ playing: Bool) {
        autoplay?.setActive(playing)
        if playing { reconcilePlayback() }
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
        let offset = scrollView.contentOffset.y
        if scrollView.isDragging, offset != lastOffset { lastDirection = offset > lastOffset ? .down : .up }
        lastOffset = offset
        updateEdgeBlurs()
    }

    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        autoplay?.stop(cell)
    }

    func outline(_ id: PostID?) {
        outlined = id
        for cell in collection.visibleCells {
            guard let path = collection.indexPath(for: cell) else { continue }
            style(cell, at: path)
        }
        // ⚠️ JUST ENOUGH TO SHOW IT WHOLE (#1527): a tile cut by an edge —
        // tapped, or reached by paging the card — comes fully into view on
        // that edge; a whole one does not move. It used to be centred, which
        // left its neighbours cut.
        if let id, let index = entries.firstIndex(where: { $0.post.id == id }),
           let tile = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame,
           let offset = SnapSideList.Snapping.reveal(
               tile, offset: collection.contentOffset.y, viewport: collection.bounds.height
           ) {
            let maxOffset = max(0, collection.contentSize.height - collection.bounds.height)
            collection.setContentOffset(CGPoint(x: 0, y: min(max(0, offset), maxOffset)), animated: true)
        }
    }

    private func style(_ cell: UICollectionViewCell, at path: IndexPath) {
        let isOutlined = entries.indices.contains(path.item) && entries[path.item].post.id == outlined
        // The post on show: a 2 pt border in the app's tint, concentric with
        // the tile's corner (#1509). The rest: a hairline, so a text tile (a
        // card on the page's own ground) still reads as a tile.
        cell.contentView.layer.borderWidth = isOutlined ? 2 : 0.5
        cell.contentView.layer.borderColor = (isOutlined ? Palette.tint : UIColor.separator)
            .resolvedColor(with: traitCollection).cgColor
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
            // A cover landing late is when a still tile may start.
            tile.onCoverLoaded = { [weak self] in self?.reconcilePlayback() }
        }
        cell.contentView.layer.cornerRadius = SnapSideList.Geometry.tileCornerRadius
        cell.contentView.layer.cornerCurve = .continuous
        style(cell, at: indexPath)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width
        return CGSize(width: width, height: (width * Self.tileAspect).rounded())
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard entries.indices.contains(indexPath.item) else { return }
        onSelect?(entries[indexPath.item])
    }

    #if DEBUG
    /// The list's scroll offset, and each edge blur's strength. Tests.
    var debugOffset: CGFloat {
        get { collection.contentOffset.y }
        set { collection.contentOffset.y = newValue; updateEdgeBlurs() }
    }
    var debugBlurStrengths: (top: CGFloat, bottom: CGFloat) { (topBlur.rampStrength, bottomBlur.rampStrength) }
    var debugTileFrames: [CGRect] { tileFrames }

    /// The tiles on screen. Tests.
    var debugTileCells: [PostGridTileCell] { collection.visibleCells.compactMap { $0 as? PostGridTileCell } }

    /// Selects the item at `index`, for a QA hook or a test.
    func debugSelect(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        onSelect?(entries[index])
    }
    #endif
}
