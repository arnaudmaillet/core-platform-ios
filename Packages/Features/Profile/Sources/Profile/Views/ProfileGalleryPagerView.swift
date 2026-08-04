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
        syncHeight(animated: window != nil && !dissolving)
    }

    /// Selector tap → smooth page. The settle callback is not re-fired (the
    /// selector already knows); height re-syncs when the scroll animation
    /// reports done.
    func setActivePage(_ format: GalleryFilter.Format, animated: Bool) {
        guard let index = Self.pageOrder.firstIndex(of: format), index != activeIndex else { return }
        activeIndex = index
        // ⚠️ **Both of these happen BEFORE the slide, not after it.** A tap has
        // no gesture to hang them off — there is no `willBeginDragging` and no
        // scrub — so the container spent the whole animation at the OUTGOING
        // page's height, and a long list tapped from a short one arrived cut
        // off, filling in only once the slide had finished.
        //
        // Unclipping covers the travel and the height animates alongside it, so
        // the incoming page is whole from the first frame. `syncHeight` restores
        // the clip when its animation completes, which is the same moment the
        // slide lands.
        setPagesUnclipped(true)
        syncHeight(animated: animated)
        scrollView.setContentOffset(CGPoint(x: CGFloat(index) * bounds.width, y: 0), animated: animated)
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
            syncHeight(animated: false)
        } else if !isScrubbing, !scrollView.isDragging, !scrollView.isDecelerating {
            // The text list's rows self-size (estimated heights), so the
            // active page's true height can settle a pass or two after
            // render. Re-pin quietly whenever layout runs; `syncHeight`
            // no-ops once the constant matches, so this can't loop.
            syncHeight(animated: false)
        }
    }

    /// Pins the pager's height to the active page's fitted content height, so
    /// the outer timeline ends exactly where the visible grid does.
    /// Lets the pages draw outside the pager while a gesture is in flight.
    ///
    /// ⚠️ **This is the whole fix for the mid-swipe crop, and it is a rendering
    /// change rather than a layout one.** The pager is as tall as its ACTIVE
    /// page, so during a drag the incoming page — which may be five times
    /// taller — is cut off at the outgoing one's height and only unfolds on
    /// release. Two earlier answers changed the HEIGHT to suit: interpolating
    /// it per frame (a moving target, two layout passes to prime, and a cache
    /// that went stale whenever a page had not laid out yet) and flooring it at
    /// a viewport (no crop, but a screen of dead space under every short tab).
    ///
    /// Not clipping costs neither. The height is left alone for the length of
    /// the gesture — no per-tick recalculation at all — and the incoming page
    /// simply draws past the container into the space below it, which on this
    /// screen is empty background. The height is then settled ONCE, animated,
    /// when the finger has committed to a page.
    private func setPagesUnclipped(_ unclipped: Bool) {
        scrollView.clipsToBounds = !unclipped
    }

    /// The active page's own content height, ignoring any floor — what the
    /// owner asks when deciding whether this page can fill the screen under a
    /// docked header.
    var contentHeight: CGFloat {
        guard bounds.width > 0 else { return 0 }
        let page = pages[activeIndex]
        page.layoutIfNeeded()
        return page.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// The shortest the pager may be, set by the owner — see
    /// `ProfileViewController.updateGalleryFloor`. Zero means "as tall as the
    /// content", which is what this screen wants whenever it can have it.
    private var minimumHeight: CGFloat = 0

    /// Raises or drops the floor, re-pinning the height to match.
    func setMinimumHeight(_ height: CGFloat) {
        guard minimumHeight != height else { return }
        minimumHeight = height
        syncHeight(animated: false)
    }

    /// Pins the pager's height to the active page's fitted content height, or
    /// to the floor its owner is holding, whichever is taller.
    ///
    /// ⚠️ Clipping is restored on COMPLETION, not before the animation. A
    /// shrinking container that re-clipped first would cut the outgoing page to
    /// the new height instantly and animate an empty box down; letting the two
    /// finish together is what makes the settle read as the page arriving
    /// rather than as content being trimmed.
    private func syncHeight(animated: Bool) {
        guard bounds.width > 0 else { return }
        // The grid's reported size is its layout's content size, which is
        // only current after a pass at the target width — force one first.
        let page = pages[activeIndex]
        page.layoutIfNeeded()
        let fitted = page.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let target = max(fitted, minimumHeight)
        guard pagerHeight.constant != target else {
            setPagesUnclipped(false)
            return
        }
        pagerHeight.constant = target
        guard animated, let host = superview else {
            setPagesUnclipped(false)
            return
        }
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: { host.layoutIfNeeded() },
            completion: { [weak self] _ in self?.setPagesUnclipped(false) }
        )
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
    /// Whether the pages may currently draw outside the container.
    var debugIsUnclipped: Bool { !scrollView.clipsToBounds }
    var debugActiveFormat: GalleryFilter.Format { Self.pageOrder[activeIndex] }
    func debugSyncHeight() { syncHeight(animated: false) }
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
        // first frame of one is where the pages are let out of the container.
        setPagesUnclipped(true)
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
            // depends on it switched off, and the pages still unclipped.
            isScrubbing = false
            syncHeight(animated: true)
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
    /// A finger has taken hold: let the pages out of the container for as long
    /// as it is down.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setPagesUnclipped(true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard bounds.width > 0 else { return }
        onProgress?(scrollView.contentOffset.x / bounds.width)
    }

    /// A release that does not throw the pages far enough to decelerate never
    /// reaches `didEndDecelerating`, so it settles from here instead. Missing
    /// it leaves the gesture unfinished: no height, and no clipping.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        settle()
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
        let changedPage = landed != activeIndex
        activeIndex = landed
        // ⚠️ Unconditionally, even when the drag came back to the page it
        // started on. `syncHeight` is what restores clipping, so an early
        // return here — which is what this had — left the pages free to draw
        // outside the container for the rest of the session, and the first
        // short tab after that overlapped whatever was beneath it.
        syncHeight(animated: true)
        guard changedPage else { return }
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
