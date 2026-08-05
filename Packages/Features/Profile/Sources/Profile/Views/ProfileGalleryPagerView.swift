import MediaCore
import PostGrid
import UIKit

/// The gallery's horizontal pager: three format pages (Activity / Media /
/// Short) in one paging scroll view, each exactly one viewport tall and
/// scrolling itself.
///
/// ⚠️ **The pager's height is fixed and its pages own all vertical motion.**
/// It used to be the other way around — the profile had one outer scroll view,
/// the pages were non-scrolling and self-sizing, and this container was pinned
/// to whichever page was active. That is where every layout defect on this
/// screen came from: a container that resizes has to be interpolated during a
/// swipe, floored so a short tab cannot clamp the scroll, unclipped so a long
/// tab is not cropped mid-gesture, expanded before a tap animates, and guarded
/// against its own `layoutSubviews`. None of that exists here, because nothing
/// resizes. It also meant no cell was ever recycled: measured at 26 built and
/// 26 after scrolling to the end, where the equivalent For You surface went
/// 34 → 54.
///
/// The header is not in this view. It floats above the pages and is moved by
/// `ProfileHeaderScrollCoordinator` from whichever page is being read, which is
/// what keeps a tab switch from jumping — see that type for the whole rule.
final class ProfileGalleryPagerView: UIView {
    /// Pager order == selector order. Set at init, because how many pages
    /// there are depends on whose profile this is: the viewer's own carries
    /// Saved and Liked, everyone else's does not.
    let pageOrder: [ProfileTab]

    var onItemTapped: ((GalleryPost) -> Void)?
    /// Fired when a swipe settles on a page (not for programmatic paging) —
    /// the selector mirrors it.
    var onPageSettled: ((ProfileTab) -> Void)?
    /// Fractional page position, emitted on every scroll tick.
    ///
    /// This is what lets the selector's lens track the finger instead of
    /// snapping when the swipe ends — the same continuous readout For You's and
    /// the inbox's pagers give the bar they share with this screen.
    var onProgress: ((CGFloat) -> Void)?
    /// The active page's vertical offset, every tick. The header rides this.
    var onVerticalScroll: ((CGFloat) -> Void)?
    /// The active page bounced past its top and let go — the profile's
    /// pull-to-refresh.
    var onPullToRefresh: (() -> Void)?

    /// The pan that pages; exposed so the owner can subordinate it to the
    /// navigation stack's edge-swipe pop.
    var horizontalPan: UIPanGestureRecognizer { scrollView.panGestureRecognizer }

    private let scrollView = PagerScrollView()
    private let pages: [ProfileGalleryGridView]
    private var activeIndex = 0

    init(imagePipeline: ImagePipeline, tabs: [ProfileTab] = ProfileTab.publicTabs) {
        pageOrder = tabs
        pages = tabs.map { tab in
            ProfileGalleryGridView(
                imagePipeline: imagePipeline,
                // The mosaic is for pages that are mostly pictures. Saved and
                // Liked are whatever the viewer kept, which is mostly not.
                style: tab == .format(.media) ? .grid : .list,
                tab: tab
            )
        }
        super.init(frame: .zero)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = self
        // This scroll view pages horizontally ONLY; each page scrolls itself
        // vertically, so the two axes never arbitrate for the same drag.
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.pin(to: self)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        var leading = content.leadingAnchor
        for page in pages {
            scrollView.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.leadingAnchor.constraint(equalTo: leading),
                page.widthAnchor.constraint(equalTo: frame.widthAnchor),
                // Every page is exactly one viewport tall. This is the line the
                // whole refactor turns on.
                page.heightAnchor.constraint(equalTo: frame.heightAnchor)
            ])
            leading = page.trailingAnchor
            page.onItemTapped = { [weak self] post in self?.onItemTapped?(post) }
            page.onVerticalScroll = { [weak self] offset in
                guard let self, page === pages[activeIndex] else { return }
                onVerticalScroll?(offset)
            }
            page.onPullToRefresh = { [weak self] in self?.onPullToRefresh?() }
        }
        NSLayoutConstraint.activate([
            leading.constraint(equalTo: content.trailingAnchor),
            content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ snapshot: ProfileViewModel.GallerySnapshot) {
        for (index, tab) in pageOrder.enumerated() {
            pages[index].render(snapshot.state(for: tab))
        }
    }

    func endRefreshing() {
        pages.forEach { $0.endRefreshing() }
    }

    /// How far the pages' content starts below their own top — the height of
    /// the header floating over them.
    func setContentTopInset(_ inset: CGFloat) {
        pages.forEach { $0.setContentTopInset(inset) }
    }

    /// Clearance below the last row — the tab bar, the tray, the transparent
    /// bar's glass capsules.
    func setContentBottomInset(_ inset: CGFloat) {
        pages.forEach { $0.setContentBottomInset(inset) }
    }

    /// How far every page must be able to travel — the header's distance.
    func setMinimumScrollTravel(_ travel: CGFloat) {
        pages.forEach { $0.setMinimumScrollTravel(travel) }
    }

    /// The active page's vertical offset.
    var verticalOffset: CGFloat {
        pages[activeIndex].verticalOffset
    }

    /// Puts every page at the same vertical offset.
    ///
    /// ⚠️ **This is what keeps the HEADER still, and it has to reach the pages
    /// that are NOT being looked at.** A page keeps its own offset; left alone,
    /// swiping to a neighbour would arrive at wherever that neighbour was last
    /// left, and the header — which rides whichever page is active — would snap
    /// with it.
    ///
    /// A page whose content is too short to reach the offset takes as much of it
    /// as it can, which is the same clamp UIKit would apply, done deliberately
    /// rather than discovered on arrival.
    func setVerticalOffset(_ offset: CGFloat, excluding excluded: ProfileGalleryGridView? = nil) {
        for page in pages where page !== excluded {
            page.setVerticalOffset(offset)
        }
    }

    /// How far the screen scrolls before the header has finished travelling —
    /// the line either side of which the offset means a different thing.
    private var dockLine: CGFloat = 0
    /// The least a tab may sit at once the header is docked: the offset that
    /// puts its FIRST ROW directly under the navigation bar.
    ///
    /// ⚠️ **Not the same number as `dockLine`, and the difference is a visible
    /// gap.** The header docks once its selector reaches the bar, but the pages
    /// are inset by the header's whole height — selector slot included — so at
    /// the dock line a tab's first row still sits a slot's height lower. A tab
    /// arriving at `dockLine` therefore opens with an empty band under the
    /// chrome. (Measured: 60pt of white above the first tile.)
    private var contentFloor: CGFloat = 0

    func setSharedTravel(dockLine: CGFloat, contentFloor: CGFloat) {
        self.dockLine = max(0, dockLine)
        self.contentFloor = max(0, contentFloor)
    }

    /// Where a page should sit, given where the screen currently is.
    ///
    /// **The offset is two things stacked, and only one of them belongs to the
    /// tab.** BELOW `dockLine` the header is still travelling, and a header
    /// is one object that cannot be in two places: every page has to agree, or
    /// changing tabs teleports the identity block. ABOVE it the header is docked
    /// and stays docked whatever the number is — so each tab is free to keep its
    /// own place in its own content, which is the whole point of there being
    /// three of them.
    ///
    /// This is the one rule that reconciles two things that sound contradictory:
    /// every tab remembers where it was, AND switching tabs moves the chrome by
    /// nothing. What it costs is that scrolling back up past the dock line
    /// carries every tab up with it — unavoidable, because up there the tabs and
    /// the header are the same number. A tab therefore remembers its place for
    /// exactly as long as the viewer stays below the line, which is the whole
    /// time the memory is worth anything.
    private func alignedOffset(for page: ProfileGalleryGridView) -> CGFloat {
        let current = verticalOffset
        guard dockLine > 0, current >= dockLine else { return current }
        return max(page.verticalOffset, contentFloor)
    }

    /// A tap on the tab already showing: take the viewer back to the top of it.
    ///
    /// **The top of THAT TAB, not of the profile.** A tab's top is its first row
    /// under the docked bar — `contentFloor` — because that is where a tab
    /// starts now that each keeps its own place. Carrying on past it to the
    /// identity block would answer a different question, and it would drag the
    /// other two tabs up on the way, since below the dock line the offset stops
    /// belonging to the tab and starts belonging to the screen.
    ///
    /// Never downwards. From above the line the list is already showing its
    /// first row, and a "back to the top" that scrolled DOWN to get there is a
    /// surprise rather than a service.
    func scrollActivePageToTop() {
        let page = pages[activeIndex]
        guard page.verticalOffset > contentFloor + 0.5 else { return }
        page.setVerticalOffset(contentFloor, animated: true)
    }

    /// Selector tap → smooth page.
    func setActivePage(_ tab: ProfileTab, animated: Bool) {
        guard let index = pageOrder.firstIndex(of: tab), index != activeIndex else { return }
        // The destination takes its position BEFORE it travels, so the page
        // sliding in is already where it belongs rather than arriving somewhere
        // else and correcting.
        pages[index].setVerticalOffset(alignedOffset(for: pages[index]))
        activeIndex = index
        scrollView.setContentOffset(CGPoint(x: CGFloat(index) * bounds.width, y: 0), animated: animated)
        reportVerticalOffset()
    }

    /// ⚠️ **Tells the header where the new page ACTUALLY landed.** A page too
    /// short to reach the offset takes as much of it as it has content for, so
    /// the number the header is riding can be stale the instant a tab changes —
    /// and a header that thinks it is still docked while its page sits at the
    /// top stays hidden, leaving the tab's first rows behind the chrome. The
    /// offset is re-read from the page rather than assumed from the request.
    private func reportVerticalOffset() {
        onVerticalScroll?(verticalOffset)
    }

    private var lastLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the offset page-aligned through width changes (first layout,
        // rotation) — offsets are in points, not page indices.
        let target = CGFloat(activeIndex) * bounds.width
        // Nothing writes this offset by hand any more, so "neither dragging nor
        // decelerating" is once again the whole of "nobody is holding it".
        if !scrollView.isDragging, !scrollView.isDecelerating,
           scrollView.contentOffset.x != target {
            scrollView.contentOffset = CGPoint(x: target, y: 0)
        }
        lastLayoutWidth = bounds.width
    }
}

#if DEBUG
extension ProfileGalleryPagerView {
    var debugActiveFormat: ProfileTab { pageOrder[activeIndex] }
    var debugActiveIndex: Int { activeIndex }
    var debugContentOffsetX: CGFloat { scrollView.contentOffset.x }
    var debugScrollView: UIScrollView { scrollView }
    var debugVerticalOffsets: [CGFloat] { pages.map(\.verticalOffset) }
    /// Where a given page would be put for the screen's current position —
    /// the split between the screen's share of the offset and the tab's, which
    /// is otherwise only observable by switching tabs and looking.
    func debugAlignedOffset(forPage index: Int) -> CGFloat {
        alignedOffset(for: pages[index])
    }

    /// Leaves one page somewhere without moving the others, which is what a
    /// viewer does by scrolling a tab and then switching away from it.
    func debugSetOffset(_ offset: CGFloat, forPage index: Int) {
        pages[index].setVerticalOffset(offset)
    }
    /// Parks the active page in its pulled-down region, so the banner's
    /// stretch-over-overscroll can be screenshotted without touch injection.
    func debugOverscroll(by distance: CGFloat) {
        pages[activeIndex].setVerticalOffset(-distance)
    }
}
#endif

// MARK: - UIScrollViewDelegate

extension ProfileGalleryPagerView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView, bounds.width > 0 else { return }
        onProgress?(scrollView.contentOffset.x / bounds.width)
        // ⚠️ Mid-swipe both pages are on screen, so the one arriving has to be
        // settled every frame rather than on release — a viewer watching a
        // neighbour slide in and then correct itself has already seen the jump.
        //
        // Where it settles TO is `alignedOffset`'s to decide: level with this
        // page while the header is still travelling, its own remembered place
        // once the header is docked.
        let active = pages[activeIndex]
        for page in pages where page !== active {
            page.setVerticalOffset(alignedOffset(for: page))
        }
    }

    /// A release that does not throw the pages far enough to decelerate never
    /// reaches `didEndDecelerating`, so it settles from here instead.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === self.scrollView, !decelerate else { return }
        settle()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        settle()
    }

    /// A finger swipe settled on a page: adopt it and tell the selector.
    private func settle() {
        guard bounds.width > 0 else { return }
        let landed = Int((scrollView.contentOffset.x / bounds.width).rounded())
            .clamped(to: 0...(pages.count - 1))
        guard landed != activeIndex else { return }
        activeIndex = landed
        reportVerticalOffset()
        onPageSettled?(pageOrder[landed])
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Edge-yielding scroll view

/// The pager's scroll view, with one deviation from stock: its pan REFUSES
/// touches originating in the screen's leading edge zone, so the navigation
/// stack's interactive pop owns that strip outright. The `require(toFail:)`
/// the owner installs covers recognizer-level ordering; this covers the
/// product contract absolutely — an edge-origin drag must never page, even
/// if the pop recognizer declines the touch (stack root, mid-transition).
private final class PagerScrollView: UIScrollView {
    /// Matches the system's edge-gesture strip.
    private static let popEdgeZone: CGFloat = 20

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            // Location is in content coordinates; remove the offset to get
            // the viewport-relative x the edge zone is defined in.
            let viewportX = gestureRecognizer.location(in: self).x - contentOffset.x
            if viewportX <= Self.popEdgeZone { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
