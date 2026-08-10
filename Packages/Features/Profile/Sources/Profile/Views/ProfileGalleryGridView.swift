import CoreModels
import DesignSystem
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
    /// This page's vertical offset, every tick — the header rides the active
    /// page's.
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onPullToRefresh: (() -> Void)?
    /// The post to bring clear of the chrome once this page is out of sight.
    /// An ID, not an index: the corpus can change while the post is open.
    private var pendingRevealPostID: PostID?
    /// Fired when a drag ends, with how far the page was pulled past its top.
    var onPullReleased: ((CGFloat) -> Void)?

    /// Clearance the owner asked for — the tab bar, the tray.
    private var baseBottomInset: CGFloat = 0
    /// The header's travel, which this page must always be able to absorb.
    private var minimumTravel: CGFloat = 0
    /// Positions the empty state as though it were the first row.
    private var statusTopConstraint: NSLayoutConstraint?

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

    /// The page's own scroll view.
    ///
    /// ⚠️ **This used to be non-scrolling and self-sizing**, reporting its whole
    /// content as intrinsic size so the profile's outer scroll view could lay it
    /// out like any other view. That made every cell permanently "visible", so
    /// none were ever recycled — measured at 26 built up front and 26 after
    /// scrolling to the end, against 34 → 54 for the equivalent For You surface.
    /// It also made the page's HEIGHT the thing that changed when tabs changed,
    /// which is where every clipping, jumping and straddling bug on this screen
    /// came from.
    ///
    /// It is an ordinary scrolling collection view now, exactly one viewport
    /// tall. The owner insets it below the header rather than sizing it around
    /// the content.
    let collectionView: UICollectionView
    /// The shared empty state, the same object Messages shows when a tab has
    /// nothing in it. It used to be a bare centred label here — a sentence with
    /// no glyph and no headline, which reads as a screen that failed rather than
    /// as an answer, and which said nothing about WHICH tab was empty.
    private let emptyStateView = EmptyStateView()
    private let tab: ProfileTab

    init(imagePipeline: ImagePipeline, style: Style, tab: ProfileTab) {
        self.imagePipeline = imagePipeline
        self.style = style
        self.tab = tab
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: style == .grid ? PostGridMosaic.layout() : PostGridListLayout.layout()
        )
        super.init(frame: .zero)

        collectionView.isScrollEnabled = true
        // No indicators on any page of this screen. The header floats OVER the
        // pages, so a vertical bar runs the full height of the viewport and
        // crosses the chrome rather than stopping under it — and with three to
        // five tabs each holding their own position, an indicator that appears
        // on every switch reads as motion the viewer did not cause.
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        // The owner supplies the top inset (the header's height) and drives the
        // header from this view's offset, so UIKit must not also be adjusting
        // for safe areas underneath it.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
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

        // The pull-down region is the banner's, so the spinner renders above the
        // media in a colour that survives it.
        // ⚠️ **No `UIRefreshControl` here, deliberately.** It positions itself
        // against its scroll view's content top, and this page is inset below
        // the profile header — so the spinner appeared mid-screen, under the
        // identity block, rather than at the top of the page it was refreshing.
        // The indicator is hosted by `ProfileViewController` above the header
        // instead, and driven by the pull this page reports.


        // ⚠️ The empty state is NOT in the collection view, so it does not
        // scroll on its own — and this page is inset below a header now, so a
        // constant from the page's top puts it behind the chrome. Its position
        // is driven from the same two numbers the content uses, which makes it
        // behave as though it were content: below the header at rest, scrolling
        // away with everything else.
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        addSubview(emptyStateView)
        // ⚠️ Positioned by its CENTRE, and the centre is computed rather than
        // pinned. `EmptyStateView` centres itself in its parent, and this
        // parent is the whole page — under the floating header, so a plain
        // centre lands the block behind the identity block. The constant puts
        // it in the middle of what is actually visible, and rides the offset so
        // it scrolls away like content rather than hanging in the chrome.
        let statusTop = emptyStateView.centerYAnchor.constraint(equalTo: topAnchor)
        statusTopConstraint = statusTop
        NSLayoutConstraint.activate([
            statusTop,
            emptyStateView.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // Statuses (empty / failed) need visible height even though the
        // collection view is empty then; the grid provides a floor and
        // grows past it with content (skeletons included).
        let floor = heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        floor.priority = .defaultHigh
        floor.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The room a page needs below its last row depends on how much content
        // it has and how tall it is, and both settle after layout — a page
        // measured before its rows exist would reserve the wrong amount and
        // stop being able to hold the header.
        applyBottomInset()
        // ⚠️ The empty state is centred between the header and the chrome, and
        // BOTH of those are measured from this view's height — which is zero
        // until a layout pass gives it one. Positioned only from the inset, the
        // block centred on the header's own bottom edge and its glyph came out
        // clipped behind the selector. Re-running it here is what lets it
        // settle once the page knows how tall it is.
        positionStatusLabel()
    }

    func render(_ state: ProfileViewModel.GalleryPageState) {
        switch state {
        case .loading:
            emptyStateView.isHidden = true
            apply([], skeleton: true)
        case .content(let posts):
            emptyStateView.isHidden = true
            apply(posts, skeleton: false)
        case .empty(let message):
            let copy = tab.emptyState
            // The model's message wins when it has something the tab cannot
            // know — "no media in reposts" says why this page is narrower than
            // the profile, which is the thing worth reading. A tab that is
            // simply empty has nothing to add, and falls back to its own line.
            emptyStateView.configure(
                symbolName: copy.symbol,
                title: copy.title,
                subtitle: message.isEmpty ? copy.subtitle : message
            )
            emptyStateView.isHidden = false
            apply([], skeleton: false)
        case .failed(let message):
            // A failure is NOT an empty state, and saying so is the point of
            // having both: the glyph and the headline have to read as "this did
            // not work" rather than as "there is nothing here", or a viewer
            // retries nothing and concludes the profile is bare.
            emptyStateView.configure(
                symbolName: "exclamationmark.triangle",
                title: "Couldn't Load",
                subtitle: message
            )
            emptyStateView.isHidden = false
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

    /// Brings the last-tapped tile clear of the chrome, now that the post is
    /// covering this page. Unanimated: nobody is watching, and the dismissal
    /// reads the tile's rect when it starts.
    func applyPendingReveal() {
        guard let id = pendingRevealPostID else { return }
        pendingRevealPostID = nil
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        ScrollIntoView.revealImmediately(
            collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame,
            in: collectionView
        )
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !showsSkeleton, posts.indices.contains(indexPath.item) else { return }
        // Same contract as the For You grids: the flight leaves from where
        // the tile IS, and the reveal waits until the post has covered this
        // page (`applyPendingReveal`). Moving the grid under the thumb at tap
        // time is a jump the viewer is looking straight at.
        pendingRevealPostID = posts[indexPath.item].id
        onItemTapped?(posts[indexPath.item])
    }
}


// MARK: - The vertical axis this page now owns

extension ProfileGalleryGridView {
    /// Where this page is scrolled to, measured from the top of its content
    /// rather than from its own origin.
    ///
    /// The pages sit under a header, so their resting offset is `-inset` rather
    /// than zero. Reporting the distance travelled instead keeps every caller
    /// out of that arithmetic: zero is the top for all three pages, whatever
    /// their insets happen to be mid-transition.
    var verticalOffset: CGFloat {
        collectionView.contentOffset.y + collectionView.contentInset.top
    }

    func setVerticalOffset(_ offset: CGFloat) {
        setVerticalOffset(offset, animated: false)
    }

    /// The same, with the option of travelling there in view of the viewer.
    ///
    /// Animated is for the ONE case a viewer asked for the journey: re-tapping
    /// the tab already showing, which is a request to be taken back rather than
    /// to be put back. Every other caller writes the offset directly, because
    /// they are keeping a page in step with something else and an animation
    /// there is a page arriving late.
    func setVerticalOffset(_ offset: CGFloat, animated: Bool) {
        // ⚠️ **Make room BEFORE asking the page to travel.** The room a page
        // needs is computed from its content size, and on a tab switch the page
        // being handed the offset may not have laid out since its content
        // arrived — so it clamps against a range that has not been extended yet,
        // and the header follows the clamp. Laying out first is what makes the
        // floor arrive before the question rather than after the answer.
        collectionView.layoutIfNeeded()
        applyBottomInset()
        let inset = collectionView.contentInset.top
        // ⚠️ **The bottom inset is part of how far a page can travel**, and
        // leaving it out is why the header still moved on a tab switch. The room
        // reserved by `setMinimumScrollTravel` IS bottom inset — so a clamp that
        // ignored it measured the page as unable to hold the offset, took the
        // shorter number, and the header followed it back up. The floor was
        // being reserved and then not counted.
        let travel = collectionView.contentSize.height
            + inset
            + collectionView.contentInset.bottom
            - collectionView.bounds.height
        // Negative is the pulled-down region, which only the QA hook asks for;
        // a real drag never routes through here.
        let target = offset < 0 ? offset : min(offset, max(0, travel))
        guard abs(verticalOffset - target) > 0.5 else { return }
        let point = CGPoint(x: 0, y: target - inset)
        if animated {
            collectionView.setContentOffset(point, animated: true)
        } else {
            collectionView.contentOffset = point
        }
    }

    /// The height of the header floating above this page.
    func setContentTopInset(_ inset: CGFloat) {
        guard collectionView.contentInset.top != inset else { return }
        let travelled = verticalOffset
        collectionView.contentInset.top = inset
        collectionView.verticalScrollIndicatorInsets.top = inset
        // Changing the inset moves the content under a stationary offset, so the
        // offset is restated to keep the page where it was.
        collectionView.contentOffset = CGPoint(x: 0, y: travelled - inset)
        positionStatusLabel()
    }

    /// Puts the empty state where the first row would be.
    private func positionStatusLabel() {
        // Centre of the region between the header's bottom and the chrome at
        // the foot of the screen — not of the page, which is taller than either.
        let visibleTop = collectionView.contentInset.top
        let visibleBottom = max(visibleTop, bounds.height - baseBottomInset)
        statusTopConstraint?.constant = (visibleTop + visibleBottom) / 2 - verticalOffset
    }

    func setContentBottomInset(_ inset: CGFloat) {
        guard baseBottomInset != inset else { return }
        baseBottomInset = inset
        applyBottomInset()
    }

    /// How far this page must be ABLE to scroll, whatever it holds.
    ///
    /// ⚠️ **This is what freezes the header across a tab switch.** The header
    /// rides the active page's offset, and a page with three rows cannot reach
    /// the offset a page with thirty was sitting at — so switching to it
    /// clamped, and the header followed the clamp back up. Nothing was
    /// auto-scrolling; the short tab simply had nowhere to put the viewer.
    ///
    /// Given room to travel the header's full distance, every tab can hold any
    /// position the header can be in, and a switch moves it by nothing at all.
    /// The room is empty space below the last row — which is exactly what the
    /// other apps show under a sparse tab, and only ever as much as the header
    /// actually needs.
    func setMinimumScrollTravel(_ travel: CGFloat) {
        guard minimumTravel != travel else { return }
        minimumTravel = travel
        applyBottomInset()
    }

    private func applyBottomInset() {
        let needed = minimumTravel
            + collectionView.bounds.height
            - collectionView.contentSize.height
            - collectionView.contentInset.top
        let bottom = max(baseBottomInset, needed)
        guard abs(collectionView.contentInset.bottom - bottom) > 0.5 else { return }
        collectionView.contentInset.bottom = bottom
        collectionView.verticalScrollIndicatorInsets.bottom = baseBottomInset
    }

    /// Kept for the owner's call sites; the visible spinner is the profile's,
    /// so there is nothing to stop here.
    func endRefreshing() {}
}

extension ProfileGalleryGridView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionStatusLabel()
        onVerticalScroll?(verticalOffset)
    }

    /// The finger left the glass. Reports how far past the top the page was
    /// when it did, which is what decides whether a refresh was asked for —
    /// the threshold belongs to the indicator, not to this page.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onPullReleased?(max(0, -verticalOffset))
    }
}
