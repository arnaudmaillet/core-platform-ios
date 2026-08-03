import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The For You pager: three format pages (Activity / Media / Short) in one
/// horizontally paging scroll view. Each format owns a fixed layout, so
/// swiping between pages IS the layout transition.
///
/// The nesting works because the axes never compete: this scroll view pages
/// horizontally only (its content height equals its frame height), and each
/// page scrolls vertically only (its content width equals the frame's), so
/// UIKit's standard pan arbitration routes each drag to exactly one of them.
///
/// Unlike the profile gallery's pager, this one does NOT sync its height to
/// the active page: every page is viewport-height and scrolls on its own.
final class ForYouPagerView: UIView {
    /// Pager order == selector order.
    static let pageOrder: [GalleryFilter.Format] = [.activity, .media, .short]

    /// The tapped post's index into the *given format page's* posts.
    var onItemTapped: ((GalleryFilter.Format, Int) -> Void)?
    /// Fired when a page becomes active: a settled finger swipe or a finished
    /// programmatic page. Not fired when the page is unchanged.
    var onPageSettled: ((GalleryFilter.Format) -> Void)?
    /// Fractional page position (e.g. `1.42` — 42% of the way from Gallery to
    /// Short), emitted on every scroll tick, drag or animation.
    ///
    /// This is what lets the top tab capsule's lens track the finger instead of
    /// snapping at the end of a swipe, and it is why the pager is a plain
    /// paging scroll view rather than a `UIPageViewController` — the latter
    /// exposes no continuous position at all.
    var onProgress: ((CGFloat) -> Void)?
    var onNearEnd: (() -> Void)?
    var onRefresh: (() -> Void)?

    private let scrollView = UIScrollView()
    private let pages: [ForYouGridPage]
    private var activeIndex = 0
    /// The last index handed to `onPageSettled`. Tracked separately from
    /// `activeIndex` because a tab tap sets the TARGET immediately and only
    /// arrives a beat later — comparing the landing against `activeIndex`
    /// alone would make every tap-driven page change look like a no-op.
    private var reportedIndex = 0

    /// The posts a page is showing — what a tile tap seeds from.
    func posts(for format: GalleryFilter.Format) -> [GalleryPost] {
        page(for: format)?.posts ?? []
    }

    /// The page itself, for a hero source that needs its geometry.
    func page(for format: GalleryFilter.Format) -> ForYouGridPage? {
        guard let index = Self.pageOrder.firstIndex(of: format) else { return nil }
        return pages[index]
    }

    init(imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController? = nil) {
        pages = Self.pageOrder.map { format in
            ForYouGridPage(
                imagePipeline: imagePipeline,
                style: format == .media ? .grid : .list,
                videoPlayback: videoPlayback
            )
        }
        super.init(frame: .zero)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.pin(to: self)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        var leading = content.leadingAnchor
        for (index, page) in pages.enumerated() {
            scrollView.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: leading),
                page.widthAnchor.constraint(equalTo: frame.widthAnchor)
            ])
            leading = page.trailingAnchor
            let format = Self.pageOrder[index]
            page.onItemTapped = { [weak self] item in self?.onItemTapped?(format, item) }
            page.onRefresh = { [weak self] in self?.onRefresh?() }
            // Only the page the user is actually reading may drive pagination:
            // the other two are laid out and would otherwise fire on their own
            // resting offsets while off-screen.
            page.onNearEnd = { [weak self] in
                guard let self, Self.pageOrder[activeIndex] == format else { return }
                onNearEnd?()
            }
        }
        NSLayoutConstraint.activate([
            leading.constraint(equalTo: content.trailingAnchor),
            content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ snapshot: ForYouViewModel.Snapshot) {
        for (index, format) in Self.pageOrder.enumerated() {
            pages[index].render(snapshot.state(for: format))
        }
    }

    func endRefreshing() {
        pages.forEach { $0.endRefreshing() }
    }

    /// Only the page being read shows the footer spinner. The other two are
    /// laid out off-screen and would otherwise reserve a band nobody can see.
    func setPaging(_ paging: Bool) {
        for (index, page) in pages.enumerated() {
            page.setPaging(paging && index == activeIndex)
        }
    }

    /// Tab tap → smooth page. The scroll animation reports progress every
    /// frame, so a tap drives the capsule's lens through exactly the same path
    /// a finger does — a tap from Activity to Short visibly carries the lens
    /// *through* Gallery.
    func setActivePage(_ format: GalleryFilter.Format, animated: Bool) {
        guard let index = Self.pageOrder.firstIndex(of: format), index != activeIndex else { return }
        activeIndex = index
        guard bounds.width > 0 else { return }
        scrollView.setContentOffset(CGPoint(x: offsetX(for: index), y: 0), animated: animated)
        syncAutoplay()
        if !animated {
            onProgress?(CGFloat(index))
            settle()
        }
    }

    /// Drives the pager from something other than its own pan — the tab
    /// capsule, which can be grabbed and dragged like the pages themselves.
    /// Unanimated by design: this is called per frame of a finger.
    ///
    /// Lives here rather than in the caller so the index↔offset conversion (and
    /// with it the RTL mirroring) stays in one place; a caller writing
    /// `contentOffset` itself would be right in English and wrong in Arabic.
    func scrub(to progress: CGFloat) {
        guard bounds.width > 0, pages.count > 1 else { return }
        let clamped = min(max(progress, 0), CGFloat(pages.count - 1))
        let slot = isRTL ? CGFloat(pages.count - 1) - clamped : clamped
        scrollView.setContentOffset(CGPoint(x: slot * bounds.width, y: 0), animated: false)
    }

    /// Ends a scrub on a whole page, carrying the fling through: a flick that
    /// barely moved still lands on the next page, the same way the pager's own
    /// pan behaves.
    func settleAfterScrub(velocityInPages: CGFloat) {
        guard bounds.width > 0, pages.count > 1 else { return }
        // Half a page of "throw" per unit velocity — enough that a flick
        // commits, small enough that a slow drag released mid-way falls back to
        // whichever page it is actually nearest.
        let projected = progress + velocityInPages * 0.5
        let landing = min(max(Int(projected.rounded()), 0), pages.count - 1)
        activeIndex = landing
        syncAutoplay()
        // Always animate, even when the landing is the page we started on:
        // that case is a scrub that didn't commit, and it still has to travel
        // back from wherever the finger left it.
        scrollView.setContentOffset(CGPoint(x: offsetX(for: landing), y: 0), animated: true)
    }

    // MARK: - Autoplay

    /// Whether this surface may autoplay at all — tab frontmost, nothing
    /// presented over it, app foregrounded. ANDed with per-page activity below.
    private var isSurfaceActive = false
    /// Exempt from the stop sweep: the post whose player a flight is carrying.
    private var flightPostID: PostID?

    func setAutoplayActive(_ active: Bool, keeping kept: PostID? = nil) {
        isSurfaceActive = active
        flightPostID = kept
        syncAutoplay()
    }

    func beginPlaybackHandoff(of postID: PostID) {
        pages.forEach { $0.beginPlaybackHandoff(of: postID) }
    }

    /// Closes the handoff on every page and reconciles. One call, one restored
    /// grid — no per-tile bookkeeping survives a flight.
    func endPlaybackHandoff() {
        pages.forEach { $0.endPlaybackHandoff() }
    }

    /// Retires a handoff nobody adopted. The pool parks at most one player, so
    /// asking any page is asking the pool — no need to know which one parked it.
    func discardPlaybackHandoff() {
        pages.forEach { $0.discardPlaybackHandoff() }
    }

    /// Only the page the viewer is actually on plays. The pager keeps all three
    /// laid out, so without this the off-screen formats would hold pool slots
    /// for video nobody can see.
    private func syncAutoplay() {
        for (index, page) in pages.enumerated() {
            page.setAutoplayActive(isSurfaceActive && index == activeIndex, keeping: flightPostID)
        }
    }

    private var lastLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the offset page-aligned through width changes (first layout,
        // rotation) — offsets are in points, not page indices.
        guard bounds.width != lastLayoutWidth, bounds.width > 0 else { return }
        lastLayoutWidth = bounds.width
        scrollView.contentOffset = CGPoint(x: offsetX(for: activeIndex), y: 0)
        onProgress?(CGFloat(activeIndex))
    }

    // MARK: - Index ↔ offset

    /// Right-to-left languages lay the pages out mirrored (the constraints use
    /// leading/trailing), but `contentOffset.x` still counts from the left
    /// edge. Every conversion goes through these, so the rest of the pager —
    /// and the tab capsule above it — can think in logical page indices only.
    private var isRTL: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }

    private func offsetX(for index: Int) -> CGFloat {
        let slot = isRTL ? pages.count - 1 - index : index
        return CGFloat(slot) * bounds.width
    }

    /// The fractional *logical* page position for the current offset.
    private var progress: CGFloat {
        guard bounds.width > 0 else { return CGFloat(activeIndex) }
        let slot = scrollView.contentOffset.x / bounds.width
        let clamped = min(max(slot, 0), CGFloat(pages.count - 1))
        return isRTL ? CGFloat(pages.count - 1) - clamped : clamped
    }
}

// MARK: - UIScrollViewDelegate

extension ForYouPagerView: UIScrollViewDelegate {
    // The pages own their own delegate (`ForYouGridPage`), so nothing vertical
    // reaches any of these — only the horizontal pager reports here.

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard bounds.width > 0 else { return }
        onProgress?(progress)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    /// A drag released without enough velocity to decelerate still lands on a
    /// page; without this the capsule would keep the old selection.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    private func settle() {
        guard bounds.width > 0 else { return }
        let landed = Int(progress.rounded())
        guard pages.indices.contains(landed), landed != reportedIndex else { return }
        activeIndex = landed
        reportedIndex = landed
        syncAutoplay()
        onPageSettled?(Self.pageOrder[landed])
    }
}
