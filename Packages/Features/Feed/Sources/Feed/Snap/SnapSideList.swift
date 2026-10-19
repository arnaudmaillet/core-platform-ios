import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// ⚠️ EXPERIMENTAL (#1425), behind `-snap-side-list`: a leftward swipe on a
/// post shrinks the whole page — its interface included, nothing faded or
/// re-laid out — into a card, and slides a narrow vertical list of other
/// current posts in on the right (Kuaishou's "Works" strip). A tap on one
/// puts it after the post on show and moves to it; a rightward swipe puts
/// everything back. Off — the default, and always in Release — no recognizer
/// is installed and the feed is today's.
enum SnapSideList {
    static let launchArgument = "-snap-side-list"

    /// Whether `arguments` ask for it. Release builds never do.
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// This process's answer — the screen's default; tests pass their own.
    static let isEnabled = isEnabled(arguments: ProcessInfo.processInfo.arguments)

    /// Where everything sits at a `progress` from 0 (closed) to 1 (open).
    /// Pure, for tests.
    struct Geometry: Equatable {
        /// The screen's bounds.
        let size: CGSize

        /// Between the card, the list and the screen's edges.
        static let gap: CGFloat = 6
        /// The card's corners when open, on screen.
        static let cornerRadius: CGFloat = 22

        /// About a ninth of the screen, as Kuaishou's strip is.
        var listWidth: CGFloat { max(44, (size.width / 9).rounded()) }

        /// The card's scale when open: the screen less the list and the gaps.
        var cardScale: CGFloat {
            guard size.width > 0 else { return 1 }
            return (size.width - listWidth - 3 * Self.gap) / size.width
        }

        /// The pager's transform: scaled about its centre, then moved so the
        /// card keeps one gap from the leading edge.
        func pagerTransform(progress: CGFloat) -> CGAffineTransform {
            let scale = 1 - (1 - cardScale) * progress
            let shift = (Self.gap - size.width * (1 - cardScale) / 2) * progress
            return CGAffineTransform(translationX: shift, y: 0).scaledBy(x: scale, y: scale)
        }

        /// The list beside the card, as tall as the open card, sliding in
        /// from beyond the trailing edge.
        func listFrame(progress: CGFloat) -> CGRect {
            let height = size.height * cardScale
            let openX = size.width - Self.gap - listWidth
            let x = size.width + (openX - size.width) * progress
            return CGRect(x: x, y: (size.height - height) / 2, width: listWidth, height: height)
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

    private var geometry: SnapSideList.Geometry { SnapSideList.Geometry(size: host?.view.bounds.size ?? .zero) }

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
        pager.layer.cornerRadius = SnapSideList.Geometry.cornerRadius * value / max(scale, 0.01)
        pager.layer.cornerCurve = .continuous
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
