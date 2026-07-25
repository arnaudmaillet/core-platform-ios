import UIKit

/// The inbox's horizontal pager: full-height pages in one paging scroll view,
/// one page per surface. Swiping between them IS the tab change.
///
/// Nesting works because the axes never compete: this scroll view pages
/// horizontally only (its content height equals its frame height, and it never
/// bounces vertically), so UIKit's standard pan arbitration hands vertical
/// drags to each page's own list and horizontal drags here. That is the same
/// arrangement `ProfileGalleryPagerView` documents — minus the height-syncing,
/// which full-height pages don't need.
///
/// Unlike a `UIPageViewController`, a scroll view exposes a *continuous*
/// position: `onProgress` fires every frame of the drag with a fractional page
/// index, which is what lets the header's selection pill track the finger
/// rather than snap at the end.
final class InboxPagerView: UIView {
    /// Fractional page position (e.g. `1.42` — 42% of the way from Requests to
    /// Suggestions), emitted on every scroll tick, drag or animation.
    var onProgress: ((CGFloat) -> Void)?
    /// A page became active: a settled finger swipe or a finished programmatic
    /// page. Not fired when the index is unchanged.
    var onSettled: ((Int) -> Void)?

    /// The pan that pages; exposed so the owner can subordinate it to the
    /// navigation stack's interactive pop.
    var horizontalPan: UIPanGestureRecognizer { scrollView.panGestureRecognizer }

    /// Paging is suspended while the active surface is in multi-selection
    /// editing — swiping a half-made selection off screen has no good outcome.
    var isPagingEnabled: Bool {
        get { scrollView.isScrollEnabled }
        set { scrollView.isScrollEnabled = newValue }
    }

    /// The paging scroll view as a plain `UIScrollView`. Tests drive
    /// fractional offsets through it, which is the only way to exercise the
    /// continuous progress signal without a real gesture.
    var pagingScrollView: UIScrollView { scrollView }

    /// The page the pager is on (or animating to). Offset math reads this.
    private(set) var activeIndex: Int
    /// The last index handed to `onSettled`. Tracked separately from
    /// `activeIndex` because a tap sets the TARGET immediately and only
    /// arrives a beat later — comparing the landing against `activeIndex`
    /// alone would make every tap-driven page change look like a no-op, and
    /// the destination surface would never be woken or publish its chrome.
    private var reportedIndex: Int
    private let scrollView = InboxPagerScrollView()
    private let pages: [UIView]
    private var lastLayoutWidth: CGFloat = 0

    init(pages: [UIView], initialIndex: Int = 0) {
        self.pages = pages
        let start = pages.indices.contains(initialIndex) ? initialIndex : 0
        activeIndex = start
        reportedIndex = start
        super.init(frame: .zero)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        // Rows must highlight the instant a finger lands, exactly as they do
        // in a plain table: without this the enclosing scroll view holds
        // touches back to decide whether they're a page drag, and every tap
        // inside the inbox feels a frame late.
        scrollView.delaysContentTouches = false
        scrollView.pin(to: self)

        NSLayoutConstraint.activate([
            scrollView.contentLayoutGuide.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        buildPageChain()
    }

    /// Re-states where the pager is: snaps the offset onto the active page and
    /// republishes its progress.
    ///
    /// Needed because an animated page change can be interrupted — a row tap
    /// pushes a thread mid-scroll, and the scroll animation that was in flight
    /// never reports its settle. The offset lands on the target but the last
    /// progress anyone heard is from part-way through, so the header's lens is
    /// left pointing at a different tab than the one on screen. Called when
    /// the inbox returns, which is BEFORE the pop draws its first frame.
    func reassertActivePage() {
        guard bounds.width > 0, pages.indices.contains(activeIndex) else { return }
        scrollView.setContentOffset(CGPoint(x: offsetX(for: activeIndex), y: 0), animated: false)
        reportedIndex = activeIndex
        onProgress?(CGFloat(activeIndex))
    }

    /// Pages chain horizontally, each exactly one viewport wide and tall — the
    /// content guide's height is tied to the frame, so this axis never scrolls
    /// and the pages' own lists own all vertical motion.
    private func buildPageChain() {
        var pageConstraints: [NSLayoutConstraint] = []
        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        var leading = content.leadingAnchor
        for page in pages {
            scrollView.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            pageConstraints += [
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: leading),
                page.widthAnchor.constraint(equalTo: frame.widthAnchor),
                page.heightAnchor.constraint(equalTo: frame.heightAnchor)
            ]
            leading = page.trailingAnchor
        }
        pageConstraints.append(leading.constraint(equalTo: content.trailingAnchor))
        NSLayoutConstraint.activate(pageConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Header tap → smooth page. The scroll animation reports progress every
    /// frame, so a tap drives the header through exactly the same path a
    /// finger does; `onSettled` fires on arrival, so lazy surfaces wake the
    /// same way they do after a swipe.
    func setActivePage(_ index: Int, animated: Bool) {
        guard pages.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        guard bounds.width > 0 else { return }
        scrollView.setContentOffset(CGPoint(x: offsetX(for: index), y: 0), animated: animated)
        if !animated {
            onProgress?(CGFloat(index))
            settle()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Offsets are points, not page indices: re-align through every width
        // change (first layout, rotation, split-view resize) or the pager
        // drifts off-page.
        guard bounds.width != lastLayoutWidth, bounds.width > 0 else { return }
        lastLayoutWidth = bounds.width
        scrollView.contentOffset = CGPoint(x: offsetX(for: activeIndex), y: 0)
        onProgress?(CGFloat(activeIndex))
    }

    // MARK: - Index ↔ offset

    /// Right-to-left languages lay the pages out mirrored (the constraints use
    /// leading/trailing), but `contentOffset.x` still counts from the left
    /// edge. Every conversion goes through these two, so the rest of the pager
    /// — and the whole header — can think in logical page indices only.
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

extension InboxPagerView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard bounds.width > 0 else { return }
        onProgress?(progress)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    /// A drag released without enough velocity to decelerate still lands on a
    /// page; without this the header would keep the old selection.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    private func settle() {
        let landed = Int(progress.rounded())
        guard pages.indices.contains(landed), landed != reportedIndex else { return }
        activeIndex = landed
        reportedIndex = landed
        onSettled?(landed)
    }
}

// MARK: - Edge-yielding scroll view

/// The pager's scroll view, with one deviation from stock: its pan REFUSES
/// touches originating in the screen's leading edge strip, so a navigation
/// stack's interactive pop owns that zone outright. The inbox is a tab root
/// today (nothing to pop), but the rule costs nothing and means the container
/// stays correct the day it is pushed — the same guarantee
/// `ProfileGalleryPagerView` makes.
private final class InboxPagerScrollView: UIScrollView {
    /// Matches the system's edge-gesture strip.
    private static let popEdgeZone: CGFloat = 20

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            // Location is in content coordinates; remove the offset to get the
            // viewport-relative x the edge zone is defined in.
            let viewportX = gestureRecognizer.location(in: self).x - contentOffset.x
            if viewportX <= Self.popEdgeZone { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
