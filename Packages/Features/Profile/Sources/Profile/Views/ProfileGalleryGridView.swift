import MediaCore
import PostGrid
import UIKit

/// One format page of the gallery pager, in the fixed shape its format owns:
/// an asymmetric media mosaic (Media) or a 1-column timeline of full-width
/// rows (Activity, Short). Layouts are format-bound, so the page's shape is
/// set at init and never morphs — moving between shapes IS the pager's
/// horizontal swipe.
///
/// The pattern, the cells and the skeletons come from `PostGrid`, shared with
/// every other post-grid surface. What is NOT shared is this host: it is
/// deliberately NOT a scrolling collection view, because the profile's outer
/// scroll view owns all vertical motion (nested vertical scrolling would fight
/// the stretchy banner and the pull-to-refresh). This view self-sizes to its
/// full content and lets the outer surface scroll it. The cost is no cell
/// reuse; acceptable at today's one-page fetch, revisit alongside pagination.
/// A surface that scrolls in its own right builds a plain scrolling collection
/// view over the same `PostGrid` layouts instead of reusing this.
final class ProfileGalleryGridView: UIView {
    /// The page's fixed shape.
    enum Style {
        /// The asymmetric media mosaic, full bleed.
        case grid
        /// 1-column full-width self-sizing rows with reading margins.
        case list
    }

    var onItemTapped: ((GalleryPost) -> Void)?

    private let imagePipeline: ImagePipeline
    private let style: Style
    private var posts: [GalleryPost] = []
    /// While a fetch is in flight the page renders shimmering placeholder
    /// cells through its own (real) layout, so the loading state already has
    /// the shape the content will hydrate into. Read by the pager to keep its
    /// height re-pin out of the hydration cross-fade.
    private(set) var showsSkeleton = false

    /// List pages show a column of placeholder cards; the mosaic shows one
    /// full 8-brick pattern.
    private var skeletonCount: Int { style == .grid ? PostGridMosaic.patternLength : 5 }

    private let collectionView: SelfSizingCollectionView
    private let statusLabel = UILabel()

    init(imagePipeline: ImagePipeline, style: Style) {
        self.imagePipeline = imagePipeline
        self.style = style
        collectionView = SelfSizingCollectionView(
            frame: .zero,
            collectionViewLayout: style == .grid ? PostGridMosaic.layout() : PostGridListLayout.layout()
        )
        super.init(frame: .zero)

        collectionView.isScrollEnabled = false
        collectionView.backgroundColor = .clear
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
        collectionView.pin(to: self)

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.constrain(in: self) { parent in
            statusLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 48)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }

        // Statuses (empty / failed) need visible height even though the
        // collection view is empty then; the grid provides a floor and
        // grows past it with content (skeletons included).
        let floor = heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        floor.priority = .defaultHigh
        floor.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ state: ProfileViewModel.GalleryPageState) {
        switch state {
        case .loading:
            statusLabel.isHidden = true
            apply([], skeleton: true)
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
        // Hydration retires the skeleton with a cross-dissolve: the shimmer
        // hands off to content inside the same silhouette instead of popping.
        let dissolving = showsSkeleton && !skeleton && !posts.isEmpty && window != nil
        self.posts = posts
        showsSkeleton = skeleton
        let reload = {
            self.collectionView.reloadData()
            self.collectionView.invalidateIntrinsicContentSize()
        }
        if dissolving {
            // The block runs with implicit animations disabled (stock
            // `UIView.transition` behavior, `.allowAnimatedContent` NOT set),
            // so the relayout inside commits instantly and only the
            // cross-fade itself is visible: a pure in-place dissolve.
            UIView.transition(
                with: collectionView, duration: 0.35,
                options: [.transitionCrossDissolve, .allowUserInteraction, .curveEaseInOut],
                animations: reload
            )
        } else {
            reload()
        }
    }
}

// MARK: - Data source / delegate

extension ProfileGalleryGridView: UICollectionViewDataSource, UICollectionViewDelegate {
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
        guard !showsSkeleton else { return }
        onItemTapped?(posts[indexPath.item])
    }
}

// MARK: - Self-sizing host

/// Reports the layout's full content size as intrinsic size, so the outer
/// scroll view can Auto-Layout the (non-scrolling) grid like any other view.
private final class SelfSizingCollectionView: UICollectionView {
    override var intrinsicContentSize: CGSize {
        collectionViewLayout.collectionViewContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size.height != intrinsicContentSize.height {
            invalidateIntrinsicContentSize()
        }
    }
}
