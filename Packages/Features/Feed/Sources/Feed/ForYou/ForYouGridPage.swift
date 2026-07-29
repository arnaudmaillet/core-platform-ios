import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// One format page of the For You pager: a **real scrolling** collection view
/// over the shared `PostGrid` layouts.
///
/// This is where a discovery root parts company with the profile gallery.
/// `ProfileGalleryGridView` is deliberately non-scrolling and self-sizing,
/// because the profile's outer scroll view owns all vertical motion and one
/// fetch fills it. A root tab has no outer scroll view, pages indefinitely, and
/// must recycle cells — so it hosts the same pattern in an ordinary scrolling
/// collection view instead. The pattern and the cells are shared; the host is
/// not.
final class ForYouGridPage: UIView {
    /// The page's fixed shape, chosen by its format at init.
    enum Style {
        case grid
        case list
    }

    /// The tapped item's index into `posts`.
    var onItemTapped: ((Int) -> Void)?
    /// The page scrolled near its end and wants another page.
    var onNearEnd: (() -> Void)?
    var onRefresh: (() -> Void)?

    private(set) var posts: [GalleryPost] = []

    private let imagePipeline: ImagePipeline
    private let style: Style
    private let collectionView: UICollectionView
    private let statusLabel = UILabel()
    private let refreshControl = UIRefreshControl()
    private var showsSkeleton = false
    /// Suppresses prefetch while the page repositions itself.
    ///
    /// Pagination is a response to the VIEWER reaching the end, not to the code
    /// moving the content. Without this, the hero's staging scroll
    /// (`scrollPostIntoView`) reports as an ordinary scroll, asks for the next
    /// page, and the corpus re-sorts under the active ordering — so every tile
    /// reshuffles at the exact moment the flight is landing on one of them.
    /// Caught in-sim as the grid visibly rearranging just after the card set
    /// down on the right tile.
    private var isRepositioning = false

    /// List pages show a column of placeholder cards; the mosaic shows two
    /// full 8-brick patterns — a scrolling page has a whole viewport to fill,
    /// where the profile's one pattern only had to reach the fold.
    private var skeletonCount: Int { style == .grid ? PostGridMosaic.patternLength * 2 : 6 }

    /// How close to the end a scroll gets before the next page is requested.
    private static let prefetchDistance: CGFloat = 800

    init(imagePipeline: ImagePipeline, style: Style) {
        self.imagePipeline = imagePipeline
        self.style = style
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: style == .grid ? PostGridMosaic.layout() : PostGridListLayout.layout()
        )
        super.init(frame: .zero)

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.register(PostGridTileCell.self, forCellWithReuseIdentifier: PostGridTileCell.reuseID)
        collectionView.register(PostGridListRowCell.self, forCellWithReuseIdentifier: PostGridListRowCell.reuseID)
        collectionView.register(
            PostGridSkeletonTileCell.self, forCellWithReuseIdentifier: PostGridSkeletonTileCell.reuseID
        )
        collectionView.register(
            PostGridSkeletonListCell.self, forCellWithReuseIdentifier: PostGridSkeletonListCell.reuseID
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        refreshControl.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        collectionView.pin(to: self)

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.constrain(in: self) { parent in
            statusLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 120)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The content inset the pager's owner needs to clear with its tray — the
    /// page scrolls under it, so the last row must be reachable above it.
    var additionalBottomInset: CGFloat {
        get { collectionView.contentInset.bottom }
        set {
            collectionView.contentInset.bottom = newValue
            collectionView.verticalScrollIndicatorInsets.bottom = newValue
        }
    }

    func endRefreshing() {
        refreshControl.endRefreshing()
    }

    // MARK: - Hero geometry

    // What the zoom transition needs to fly a post's media: where it is, what
    // it looks like, and the ability to hide it while its twin is in the air.
    // All of it is asked of the *page* rather than of a cell, because cells are
    // recycled — the page resolves an id to whatever cell is showing it now, or
    // reports that none is.

    /// Everything a flight needs from a realized cell, resolved together so the
    /// rect, the cover and the style cannot describe different objects.
    struct Hero {
        let frame: CGRect
        let cover: UIImage?
        let style: PostGridFlightCard.Style
    }

    /// The post's flyable media in `space`, or nil when there is nothing to
    /// fly: no realized cell (scrolled out), or a text-only row, which has no
    /// media surface at all. The caller pushes plainly in that case.
    func hero(for postID: PostID, in space: UICoordinateSpace) -> Hero? {
        guard let cell = cell(for: postID), let appearance = heroAppearance(for: postID) else {
            return nil
        }
        let rect: CGRect = switch cell {
        // A brick IS its media, edge to edge; a row is a card of which the
        // media is one part, so fly that part.
        case let tile as PostGridTileCell: tile.bounds
        case let row as PostGridListRowCell: row.mediaHeroRect ?? .zero
        default: .zero
        }
        guard rect != .zero else { return nil }
        return Hero(frame: cell.convert(rect, to: space), cover: appearance.cover, style: appearance.style)
    }

    /// What the flight card should *look* like, without needing a coordinate
    /// space — the card is built before anyone knows the container, and asking
    /// for a frame there would mean inventing one.
    func heroAppearance(for postID: PostID) -> (cover: UIImage?, style: PostGridFlightCard.Style)? {
        switch cell(for: postID) {
        case let tile as PostGridTileCell:
            (cover: tile.renderedCover, style: .tile)
        case let row as PostGridListRowCell:
            row.mediaHeroRect == nil ? nil : (cover: row.renderedCover, style: .listMedia)
        default:
            nil
        }
    }

    /// Whether a realized cell for the post is currently within the viewport —
    /// the hero falls back to a centered collapse when it isn't.
    func isPostVisible(_ postID: PostID) -> Bool {
        guard let cell = cell(for: postID) else { return false }
        return collectionView.bounds.intersects(cell.frame)
    }

    /// Brings the post fully into view without animation, so a dismissal can
    /// land on a cell the viewer had scrolled past — or only half scrolled to.
    ///
    /// "Fully" is measured against the *inset* viewport, not the raw bounds: a
    /// cell tucked under the filter tray or the tab bar passes an intersection
    /// test while being somewhere no card should land. A cell already clear of
    /// the insets is left exactly where it is, so a dismissal to something the
    /// viewer can already see never jerks the grid under them.
    func scrollPostIntoView(_ postID: PostID) {
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let attributes = collectionView.layoutAttributesForItem(
                  at: IndexPath(item: index, section: 0)
              )
        else { return }
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard !viewport.contains(attributes.frame) else { return }
        isRepositioning = true
        defer { isRepositioning = false }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false
        )
        // The rect the caller is about to read must reflect the new offset.
        collectionView.layoutIfNeeded()
    }

    /// Hides the real cell while its twin is flying.
    func setHeroHidden(_ hidden: Bool, for postID: PostID) {
        cell(for: postID)?.isHidden = hidden
    }

    /// The post behind an id, for a flight card that must configure itself
    /// from the model rather than from a cell that may not be realized.
    func post(for postID: PostID) -> GalleryPost? {
        posts.first { $0.id == postID }
    }

    private func cell(for postID: PostID) -> UICollectionViewCell? {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0))
    }

    func render(_ state: ForYouViewModel.PageState) {
        switch state {
        case .loading:
            statusLabel.isHidden = true
            // A refresh keeps the existing rows under the spinner rather than
            // blanking to skeletons — the content is still valid until the
            // new page lands.
            apply(posts, skeleton: !refreshControl.isRefreshing && posts.isEmpty)
        case .content(let posts):
            statusLabel.isHidden = true
            apply(posts, skeleton: false)
        case .empty(let message), .failed(let message):
            statusLabel.text = message
            statusLabel.isHidden = false
            apply([], skeleton: false)
        }
    }

    private func apply(_ posts: [GalleryPost], skeleton: Bool) {
        guard self.posts != posts || showsSkeleton != skeleton else { return }
        // Hydration retires the skeleton with a cross-dissolve, the same
        // in-place hand-off the profile gallery uses.
        let dissolving = showsSkeleton && !skeleton && !posts.isEmpty && window != nil
        self.posts = posts
        showsSkeleton = skeleton
        if dissolving {
            UIView.transition(
                with: collectionView, duration: 0.35,
                options: [.transitionCrossDissolve, .allowUserInteraction, .curveEaseInOut],
                animations: { self.collectionView.reloadData() }
            )
        } else {
            collectionView.reloadData()
        }
    }
}

// MARK: - Data source / delegate

extension ForYouGridPage: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        showsSkeleton ? skeletonCount : posts.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if showsSkeleton {
            switch style {
            case .list:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PostGridSkeletonListCell.reuseID, for: indexPath
                ) as! PostGridSkeletonListCell
                cell.configure(variant: indexPath.item)
                return cell
            case .grid:
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: PostGridSkeletonTileCell.reuseID, for: indexPath
                )
            }
        }
        let post = posts[indexPath.item]
        switch style {
        case .list:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridListRowCell.reuseID, for: indexPath
            ) as! PostGridListRowCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            return cell
        case .grid:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath
            ) as! PostGridTileCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !showsSkeleton, posts.indices.contains(indexPath.item) else { return }
        collectionView.deselectItem(at: indexPath, animated: false)
        onItemTapped?(indexPath.item)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !showsSkeleton, !posts.isEmpty, !isRepositioning else { return }
        let remaining = scrollView.contentSize.height
            - (scrollView.contentOffset.y + scrollView.bounds.height)
        guard remaining < Self.prefetchDistance else { return }
        onNearEnd?()
    }
}
