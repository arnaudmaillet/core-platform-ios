import MediaCore
import PostGrid
import UIKit

/// The gallery's horizontal pager: three format pages (Activity / Media /
/// Short) in one paging scroll view, embedded in the profile's single
/// vertical timeline. Each format owns a fixed layout — the timeline list
/// for Activity and Short, the 3-column grid for Media — so swiping between
/// pages IS the layout transition.
///
/// The nesting works because the axes never compete: this scroll view pages
/// horizontally only (its content height equals its frame height), so UIKit's
/// standard pan arbitration gives vertical drags to the profile's outer
/// scroll view and horizontal drags to the pager. The pager's own height is
/// pinned to the *active* page's content height and re-animates on every
/// settle, so the vertical timeline below the header always fits the page the
/// user is actually reading (taller neighbors clip during the swipe).
final class ProfileGalleryPagerView: UIView {
    /// Pager order == selector order.
    static let pageOrder: [GalleryFilter.Format] = [.activity, .media, .short]

    var onItemTapped: ((GalleryPost) -> Void)?
    /// Fired when a swipe settles on a page (not for programmatic paging) —
    /// the selector mirrors it.
    var onPageSettled: ((GalleryFilter.Format) -> Void)?
    /// Fractional page position, emitted on every scroll tick.
    ///
    /// This is what lets the selector's lens track the finger instead of
    /// snapping when the swipe ends — the same continuous readout For You's and
    /// the inbox's pagers give the bar they share with this screen. Without it
    /// the same component would behave differently here for no reason a viewer
    /// could name.
    var onProgress: ((CGFloat) -> Void)?

    /// The pan that pages; exposed so the owner can subordinate it to the
    /// navigation stack's edge-swipe pop.
    var horizontalPan: UIPanGestureRecognizer { scrollView.panGestureRecognizer }

    private let scrollView = PagerScrollView()
    private let pages: [ProfileGalleryGridView]
    private var activeIndex = 0
    /// Set once at the end of init (it hangs off `heightAnchor`, unavailable
    /// before super.init).
    private var pagerHeight: NSLayoutConstraint!

    init(imagePipeline: ImagePipeline) {
        pages = Self.pageOrder.map { format in
            ProfileGalleryGridView(
                imagePipeline: imagePipeline,
                style: format == .media ? .grid : .list
            )
        }
        super.init(frame: .zero)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.clipsToBounds = true
        scrollView.delegate = self
        // The pager never scrolls vertically; all vertical motion belongs to
        // the profile's outer scroll view.
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.pin(to: self)

        // Pages are chained horizontally with NO bottom tie to the content
        // guide: each keeps its own content height (clipped past the pager's
        // active-page height), so a tall neighbor can never inflate the pager.
        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        var leading = content.leadingAnchor
        for page in pages {
            scrollView.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.leadingAnchor.constraint(equalTo: leading),
                page.widthAnchor.constraint(equalTo: frame.widthAnchor)
            ])
            leading = page.trailingAnchor
            page.onItemTapped = { [weak self] post in self?.onItemTapped?(post) }
        }
        NSLayoutConstraint.activate([
            leading.constraint(equalTo: content.trailingAnchor),
            // Content height tracks the pager frame: this axis never scrolls.
            content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        ])

        let height = heightAnchor.constraint(equalToConstant: 140)
        // Below `required` so a zero-frame first pass can't conflict with the
        // stack's internal constraints before real layout happens.
        height.priority = .defaultHigh
        height.isActive = true
        pagerHeight = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ snapshot: ProfileViewModel.GallerySnapshot) {
        // A page leaving its skeleton dissolves in place; animating the
        // height re-pin at the same time would slide everything under the
        // cross-fade (the animated `layoutIfNeeded` also captures any other
        // pending layout in the scroll view's subtree). Snap the height
        // inside the dissolve instead — the fade masks it completely.
        let dissolving = pages[activeIndex].showsSkeleton
        for (index, format) in Self.pageOrder.enumerated() {
            pages[index].render(snapshot.state(for: format))
        }
        // Pre-layout skeleton seed: without a width the fitted height can't
        // be computed yet (`syncHeight` bails), and the first pushed frames
        // would catch the pager at its floor, cropping the shimmer to a row
        // and a half mid-screen. Park it at screen scale instead — the first
        // sized pass converges to the real number, far below the fold.
        if bounds.width == 0, pages[activeIndex].showsSkeleton {
            pagerHeight.constant = 640
        }
        measurePages()
        syncHeight(animated: window != nil && !dissolving)
    }

    /// Selector tap → smooth page. The settle callback is not re-fired (the
    /// selector already knows); height re-syncs when the scroll animation
    /// reports done.
    func setActivePage(_ format: GalleryFilter.Format, animated: Bool) {
        guard let index = Self.pageOrder.firstIndex(of: format), index != activeIndex else { return }
        activeIndex = index
        scrollView.setContentOffset(CGPoint(x: CGFloat(index) * bounds.width, y: 0), animated: animated)
        if !animated { syncHeight(animated: false) }
    }

    private var lastLayoutWidth: CGFloat = 0
    /// True while the SELECTOR's pan is driving the offset.
    ///
    /// ⚠️ A scrub writes `contentOffset` directly, so the scroll view reports
    /// neither dragging nor decelerating — and `layoutSubviews` below re-aligns
    /// the offset to the active page on exactly that condition. Without this
    /// flag any layout pass landing mid-drag (a self-sizing row settling, the
    /// height re-pin this very method triggers) snaps the pages back under the
    /// finger while the lens keeps following it.
    private var isScrubbing = false

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the offset page-aligned through width changes (first layout,
        // rotation) — offsets are in points, not page indices.
        let target = CGFloat(activeIndex) * bounds.width
        if !isScrubbing, !scrollView.isDragging, !scrollView.isDecelerating,
           scrollView.contentOffset.x != target {
            scrollView.contentOffset = CGPoint(x: target, y: 0)
        }
        // Content can land before the pager has real bounds (a fast mock
        // resolves mid-push); the render-time sync bails without a width, so
        // the first sized pass must re-run it or the pager sticks at its floor.
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            measurePages()
            syncHeight(animated: false)
        } else if !isScrubbing, !scrollView.isDragging, !scrollView.isDecelerating {
            measurePages()
            // The text list's rows self-size (estimated heights), so the
            // active page's true height can settle a pass or two after
            // render. Re-pin quietly whenever layout runs; `syncHeight`
            // no-ops once the constant matches, so this can't loop.
            syncHeight(animated: false)
        }
    }

    /// Pins the pager's height to the active page's fitted content height, so
    /// the outer timeline ends exactly where the visible grid does.
    /// Each page's fitted height, measured together and kept until the content
    /// or the width changes.
    ///
    /// Cached because the interpolation below needs TWO pages' heights on every
    /// scroll tick, and `systemLayoutSizeFitting` forces a layout pass to answer
    /// — measuring both, thirty times a second, for the length of a swipe.
    private var fittedHeights: [CGFloat] = []

    private func measurePages() {
        guard bounds.width > 0 else { return }
        fittedHeights = pages.map { page in
            // The grid's reported size is its layout's content size, which is
            // only current after a pass at the target width — force one first.
            page.layoutIfNeeded()
            return page.systemLayoutSizeFitting(
                CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
    }

    private func fittedHeight(at index: Int) -> CGFloat? {
        fittedHeights.indices.contains(index) ? fittedHeights[index] : nil
    }

    /// Grows and shrinks the pager BETWEEN the two pages a drag spans, so the
    /// incoming one is never cropped to the outgoing one's height.
    ///
    /// ⚠️ The pager is exactly as tall as its ACTIVE page — a deliberate rule,
    /// so the profile's single vertical timeline always fits the page being
    /// read. Held literally during a drag it means the taller page arrives
    /// clipped to the shorter one's height and only unfolds on release, which
    /// reads as content loading late rather than as a page sliding in. The
    /// height belongs to whatever is actually on screen, and mid-drag that is
    /// two pages at once.
    private func applyInterpolatedHeight() {
        guard bounds.width > 0, !fittedHeights.isEmpty else { return }
        let progress = (scrollView.contentOffset.x / bounds.width)
            .clamped(to: 0...CGFloat(pages.count - 1))
        let lower = Int(progress.rounded(.down))
        let upper = Int(progress.rounded(.up))
        guard let from = fittedHeight(at: lower), let to = fittedHeight(at: upper) else { return }
        let height = from + (to - from) * (progress - CGFloat(lower))
        guard pagerHeight.constant != height else { return }
        pagerHeight.constant = height
    }

    private func syncHeight(animated: Bool) {
        guard bounds.width > 0 else { return }
        if fittedHeights.isEmpty { measurePages() }
        guard let fitted = fittedHeight(at: activeIndex) else { return }
        guard pagerHeight.constant != fitted else { return }
        pagerHeight.constant = fitted
        guard animated, let host = superview else { return }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            host.layoutIfNeeded()
        }
    }
}

#if DEBUG
extension ProfileGalleryPagerView {
    /// Test seams for the scrub arithmetic — the page it committed to and the
    /// offset the finger left it at. Both are private state whose only
    /// observable consequences are pixels, and the landing rule is the kind of
    /// thing a screenshot cannot check at the ends.
    var debugActiveIndex: Int { activeIndex }
    var debugContentOffsetX: CGFloat { scrollView.contentOffset.x }
    /// Whether layout is currently forbidden from re-owning the offset.
    var debugIsScrubbing: Bool { isScrubbing }
    var debugScrollView: UIScrollView { scrollView }
    /// The height the container is currently holding, and the per-page heights
    /// it interpolates between.
    var debugPagerHeight: CGFloat { pagerHeight.constant }
    func debugSetFittedHeights(_ heights: [CGFloat]) { fittedHeights = heights }
    /// Parks the offset without going through `scrub`, which re-measures the
    /// pages — so a test can state the two heights it is interpolating between
    /// instead of depending on what empty fixture pages happen to measure.
    func debugSetOffsetX(_ x: CGFloat) { scrollView.contentOffset = CGPoint(x: x, y: 0) }
    func debugApplyInterpolatedHeight() { applyInterpolatedHeight() }
}
#endif

// MARK: - Driven by the selector's own drag

extension ProfileGalleryPagerView {
    /// Drives the pager from something other than its own pan — the selector
    /// capsule, which can be grabbed and dragged like the pages themselves.
    /// Unanimated by design: this is called per frame of a finger.
    func scrub(to progress: CGFloat) {
        guard bounds.width > 0, pages.count > 1 else { return }
        // The selector's drag has no `willBeginDragging` of its own, so the
        // first frame of one is where its heights get taken.
        if !isScrubbing { measurePages() }
        isScrubbing = true
        let clamped = min(max(progress, 0), CGFloat(pages.count - 1))
        scrollView.setContentOffset(CGPoint(x: clamped * bounds.width, y: 0), animated: false)
    }

    /// The finger let go: commit to a page.
    ///
    /// ⚠️ **`settle()` will not do this job.** It only runs on the scroll view's
    /// own deceleration, and a scrub never decelerates — the offset was being
    /// written directly, frame by frame, so releasing mid-way would leave the
    /// pager parked between two pages with no callback coming to rescue it.
    func settleAfterScrub(velocityInPages: CGFloat) {
        guard bounds.width > 0, pages.count > 1 else {
            isScrubbing = false
            return
        }
        // Half a page of "throw" per unit velocity — enough that a flick
        // commits, small enough that a slow drag released mid-way falls back to
        // whichever page it is actually nearest.
        let progress = scrollView.contentOffset.x / bounds.width
        let landing = (progress + velocityInPages * 0.5)
            .rounded()
            .clamped(to: 0...CGFloat(pages.count - 1))
        let index = Int(landing)
        let changedPage = index != activeIndex
        // ⚠️ **`activeIndex` first, and the scrub flag last.** This ordering IS
        // the fix for pages left straddling two tabs.
        //
        // `layoutSubviews` re-aligns the offset to `activeIndex` whenever the
        // scroll view is neither dragging nor decelerating — which an ANIMATED
        // `setContentOffset` is not. Updating the index after starting that
        // animation left a window where any layout pass (a self-sizing row
        // settling, the height re-pin below) yanked the offset back to the page
        // being left, mid-flight; clearing the flag before it opened that window
        // in the first place. So the index is true before the animation starts,
        // and the flag stays up until the animation reports itself finished.
        activeIndex = index
        let target = landing * bounds.width
        if scrollView.contentOffset.x == target {
            // Nothing to travel: an animation that has no distance to cover may
            // never report a finish, and waiting for one would leave the flag
            // raised for the life of the screen — with the re-alignment that
            // depends on it switched off.
            isScrubbing = false
        } else {
            // Always animate, even when the landing is the page it started on:
            // that case is a scrub that did not commit, and it still has to
            // travel back from wherever the finger left it.
            scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: true)
        }
        guard changedPage else { return }
        syncHeight(animated: true)
        onPageSettled?(Self.pageOrder[index])
    }
}

// MARK: - UIScrollViewDelegate

extension ProfileGalleryPagerView: UIScrollViewDelegate {
    /// ⚠️ **Re-measured at the start of every gesture, not just when content
    /// lands.** The cache is filled when a snapshot renders and when the width
    /// changes — and at both of those moments a page may still be empty or
    /// unlaid-out, so the height recorded for it is whatever it happened to be
    /// then. Interpolating towards a stale number is what left the incoming page
    /// cropped even with the interpolation in place: the arithmetic was right
    /// and one of its inputs was a page that had no rows yet. A drag is the last
    /// moment before the heights matter and the cheapest place to be sure of
    /// them — once per gesture, not once per frame.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        measurePages()
        #if DEBUG
        // `-profile-height-audit` prints the per-page heights this drag will
        // interpolate between.
        //
        // Worth keeping: "the incoming page looks cropped" and "the incoming
        // page is genuinely short" are the same picture, and the only way to
        // tell them apart is the numbers. Chasing this by eye cost a round of
        // wrong conclusions — the Gallery grid measures 268pt against
        // Activity's 1308, so most of what looked like clipping was a two-row
        // grid being two rows tall.
        if ProcessInfo.processInfo.arguments.contains("-profile-height-audit") {
            print("HEIGHT-AUDIT width=\(bounds.width) fitted=\(fittedHeights) pager=\(pagerHeight.constant)")
        }
        #endif
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard bounds.width > 0 else { return }
        applyInterpolatedHeight()
        onProgress?(scrollView.contentOffset.x / bounds.width)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // The settle animation has arrived, so the offset is the active page's
        // again and layout may resume owning it. Programmatic paging (a
        // selector tap) also lands here, where clearing an already-clear flag
        // costs nothing.
        isScrubbing = false
        syncHeight(animated: true)
    }

    /// A finger swipe settled on a page: adopt it and tell the selector.
    private func settle() {
        guard bounds.width > 0 else { return }
        let landed = Int((scrollView.contentOffset.x / bounds.width).rounded())
            .clamped(to: 0...(pages.count - 1))
        guard landed != activeIndex else { return }
        activeIndex = landed
        syncHeight(animated: true)
        onPageSettled?(Self.pageOrder[landed])
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
