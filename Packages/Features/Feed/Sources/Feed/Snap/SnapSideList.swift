import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
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
        /// The list's tiles' corner.
        static let tileCornerRadius: CGFloat = 6
        /// The card's corners when open, on screen: concentric with the
        /// list's tiles, a gap out (#1509).
        static var cornerRadius: CGFloat { tileCornerRadius + gap }
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

/// The side list's gesture, state and views, for one snap feed screen.
@MainActor
final class SnapSideListController: NSObject, UIGestureRecognizerDelegate {
    private weak var host: SnapFeedViewController?
    let pan = UIPanGestureRecognizer()
    let listView: SnapSideListView
    /// 0 closed … 1 open.
    private(set) var progress: CGFloat = 0
    private var startProgress: CGFloat = 0
    private var isSettling = false
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false

    /// Open, opening or closing: the screen's dismissals stand aside.
    var isEngaged: Bool {
        progress > 0 || isSettling || pan.state == .began || pan.state == .changed
    }

    var isOpen: Bool { progress >= 1 }

    init(host: SnapFeedViewController, imagePipeline: ImagePipeline) {
        self.host = host
        listView = SnapSideListView(imagePipeline: imagePipeline)
        super.init()
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        listView.isHidden = true
        listView.onSelect = { [weak self] entry in self?.host?.showSideListEntry(entry) }
    }

    func install(in view: UIView) {
        view.addGestureRecognizer(pan)
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

    // MARK: Gesture

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let host, !isSettling else { return false }
        let velocity = pan.velocity(in: host.view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        // Open: a rightward drag closes. Closed: a leftward one opens, where
        // the screen has nothing else for it.
        if progress > 0 { return velocity.x > 0 }
        guard velocity.x < 0 else { return false }
        let origin = CGPoint(
            x: pan.location(in: host.view).x - pan.translation(in: host.view).x,
            y: pan.location(in: host.view).y - pan.translation(in: host.view).y
        )
        return host.sideListMayOpen(from: origin)
    }

    /// Alongside the dismissal drivers (which never begin leftward, and
    /// stand aside while the list is engaged) and the pager, which is frozen
    /// the moment this begins.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let host else { return }
        switch pan.state {
        case .began:
            startProgress = progress
            host.setContentScrollEnabled(false)
            loadIfNeeded()
        case .changed:
            let dx = pan.translation(in: host.view).x
            apply(min(1, max(0, startProgress - dx / geometry.travel)))
        case .ended:
            settle(open: geometry.settlesOpen(progress: progress, velocityX: pan.velocity(in: host.view).x))
        case .cancelled, .failed:
            settle(open: startProgress >= 1)
        default:
            break
        }
    }

    /// Springs to open or closed, then gives the pager back.
    func settle(open: Bool, animated: Bool = true) {
        isSettling = true
        let finish = { [weak self] in
            guard let self else { return }
            isSettling = false
            if !open { listView.isHidden = true }
            host?.setContentScrollEnabled(true)
            host?.sideListDidSettle(open: open)
        }
        guard animated else {
            apply(open ? 1 : 0)
            finish()
            return
        }
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.apply(open ? 1 : 0)
        } completion: { _ in finish() }
    }

    // MARK: The list

    private func loadIfNeeded() {
        guard !hasLoaded, loadTask == nil, let host else { return }
        loadTask = Task { [weak self, weak host] in
            let entries = await host?.sideListCandidates() ?? []
            guard let self else { return }
            loadTask = nil
            hasLoaded = true
            listView.show(entries)
            if let active = host?.activePostID { listView.outline(active) }
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
        listView.outline(id)
    }
}

/// The narrow strip of post thumbnails.
@MainActor
final class SnapSideListView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let imagePipeline: ImagePipeline
    private let collection: UICollectionView
    private(set) var entries: [FeedEntry] = []
    private var outlined: PostID?
    var onSelect: ((FeedEntry) -> Void)?

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
        accessibilityIdentifier = "snap.sideList"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ entries: [FeedEntry]) {
        self.entries = entries
        collection.reloadData()
    }

    func outline(_ id: PostID?) {
        outlined = id
        for cell in collection.visibleCells {
            guard let path = collection.indexPath(for: cell) else { continue }
            style(cell, at: path)
        }
        if let id, let index = entries.firstIndex(where: { $0.post.id == id }) {
            collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: true)
        }
    }

    private func style(_ cell: UICollectionViewCell, at path: IndexPath) {
        let isOutlined = entries.indices.contains(path.item) && entries[path.item].post.id == outlined
        // The post on show: a bold outline. The rest: a hairline, so a text
        // tile (a card on the page's own ground) still reads as a tile.
        cell.contentView.layer.borderWidth = isOutlined ? 2 : 0.5
        cell.contentView.layer.borderColor = (isOutlined ? UIColor.label : UIColor.separator)
            .resolvedColor(with: traitCollection).cgColor
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath)
        if let tile = cell as? PostGridTileCell {
            tile.cornerRadius = 6
            let entry = entries[indexPath.item]
            // A text post's tile is its words; a picture speaks for itself.
            tile.configure(
                with: ForYouRepository.galleryPost(from: entry), imagePipeline: imagePipeline,
                showsInfo: entry.post.attachments.isEmpty
            )
        }
        cell.contentView.layer.cornerRadius = 6
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
    /// Selects the item at `index`, for a QA hook or a test.
    func debugSelect(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        onSelect?(entries[index])
    }
    #endif
}
