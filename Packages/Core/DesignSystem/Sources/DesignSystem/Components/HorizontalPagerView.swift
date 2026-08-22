import UIKit

/// A horizontal pager: full-height pages in one paging scroll view, one page
/// per surface. Swiping between them IS the tab change.
///
/// Built for the Messages inbox (All / Requests / Suggestions) and reused by
/// the profile's relationship lists (Followers / Following / Friends). It knows
/// nothing about either — it takes views and reports a fractional position — so
/// it pairs with `PagedTabBar`, which consumes exactly that signal.
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
public final class HorizontalPagerView: UIView {
    /// Fractional page position (e.g. `1.42` — 42% of the way from Requests to
    /// Suggestions), emitted on every scroll tick, drag or animation.
    public var onProgress: ((CGFloat) -> Void)?
    /// A page became active: a settled finger swipe or a finished programmatic
    /// page. Not fired when the index is unchanged.
    public var onSettled: ((Int) -> Void)?

    /// The pan that pages; exposed so the owner can subordinate it to the
    /// navigation stack's interactive pop.
    public var horizontalPan: UIPanGestureRecognizer { scrollView.panGestureRecognizer }

    /// Paging is suspended while the active surface is in multi-selection
    /// editing — swiping a half-made selection off screen has no good outcome.
    public var isPagingEnabled: Bool {
        get { scrollView.isScrollEnabled }
        set { scrollView.isScrollEnabled = newValue }
    }

    /// The paging scroll view as a plain `UIScrollView`. Tests drive
    /// fractional offsets through it, which is the only way to exercise the
    /// continuous progress signal without a real gesture.
    public var pagingScrollView: UIScrollView { scrollView }

    /// The page the pager is on (or animating to). Offset math reads this.
    public private(set) var activeIndex: Int
    /// The last index handed to `onSettled`. Tracked separately from
    /// `activeIndex` because a tap sets the TARGET immediately and only
    /// arrives a beat later — comparing the landing against `activeIndex`
    /// alone would make every tap-driven page change look like a no-op, and
    /// the destination surface would never be woken or publish its chrome.
    private var reportedIndex: Int
    private let scrollView = HorizontalPagerScrollView()
    private let pages: [UIView]
    private var lastLayoutWidth: CGFloat = 0

    public init(pages: [UIView], initialIndex: Int = 0) {
        self.pages = pages
        let start = pages.indices.contains(initialIndex) ? initialIndex : 0
        activeIndex = start
        reportedIndex = start
        super.init(frame: .zero)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
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

    /// Keeps the offset page-aligned through width changes — the first real
    /// layout and rotation — because offsets are in points and `activeIndex` is
    /// not.
    ///
    /// ⚠️ **This is what makes a launch-time route land on the right page.**
    /// `-open-messages requests`, and a push payload opening a category, reach
    /// `setCategory` after the view exists but before it has ever been laid
    /// out. `setActivePage` records the index and returns without scrolling,
    /// since a zero-width pager has no offset to scroll to — so without this
    /// the header's lens sat on Requests while the All list stayed on screen,
    /// and only a manual swipe put the two back in agreement. Same override,
    /// for the same reason, as `ForYouPagerView`.
    override public func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width != lastLayoutWidth, bounds.width > 0 else { return }
        lastLayoutWidth = bounds.width
        reassertActivePage()
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
    public func reassertActivePage() {
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
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Header tap → smooth page. The scroll animation reports progress every
    /// frame, so a tap drives the header through exactly the same path a finger
    /// does; `onSettled` fires on arrival, so lazy surfaces wake the same way
    /// they do after a swipe.
    ///
    /// ⚠️ **`setContentOffset(animated:)`, and it must stay that way** — this is
    /// character-for-character what `ForYouPagerView` does, and the two screens
    /// wear the same `PagedTabBar`. A display-link spring was built here and
    /// removed: it moved the lens just as continuously (34 fractional samples
    /// across the flight, monotonic) but on a different curve to the other
    /// screen's, and one tab bar that eases differently depending on which tab
    /// you are in is worse than either curve on its own. The claim it was built
    /// on — that UIKit's scroll animation does not report intermediate offsets
    /// to `scrollViewDidScroll` — was simply wrong.
    public func setActivePage(_ index: Int, animated: Bool) {
        guard pages.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        guard bounds.width > 0 else { return }
        scrollView.setContentOffset(CGPoint(x: offsetX(for: index), y: 0), animated: animated)
        if !animated {
            onProgress?(CGFloat(index))
            settle()
        }
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

extension HorizontalPagerView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard bounds.width > 0 else { return }
        onProgress?(progress)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    /// A drag released without enough velocity to decelerate still lands on a
    /// page; without this the header would keep the old selection.
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
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

// MARK: - Yielding scroll view

/// A paging scroll view that knows when a horizontal drag is not its own.
///
/// Two rules, both about giving the gesture up:
///
/// 1. **The leading edge strip** belongs to a navigation stack's interactive
///    pop, outright. A tab root has nothing to pop today, but the rule costs
///    nothing and keeps the container correct the day it is pushed — the same
///    guarantee `ProfileGalleryPagerView` makes.
/// 2. **Horizontally scrollable content under the touch** owns the drag.
///
/// ⚠️ PUBLIC because this app has more than one pager, and the second one did
/// not have these rules. The tab-swipe fix was written here first and changed
/// nothing on the surface it was reported against: the Messages inbox uses this
/// pager, For You has its own `ForYouPagerView`, and a post card lives in the
/// latter. Two twins, one defect, one of them fixed — which a real drag on the
/// simulator caught and a unit test on this class had just called green. Sharing
/// the class is what stops it happening a third time.
public final class HorizontalPagerScrollView: UIScrollView {
    /// Matches the system's edge-gesture strip.
    private static let popEdgeZone: CGFloat = 20

    override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           shouldYield(at: gestureRecognizer.location(in: self)) {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// Whether a drag beginning at `point` belongs to something other than this
    /// pager. Split out of the delegate callback so it can be asked directly:
    /// the callback only fires for the scroll view's OWN recognizer, and a test
    /// cannot make a real one report a location.
    ///
    /// - Parameter point: in this scroll view's content coordinates.
    public func shouldYield(at point: CGPoint) -> Bool {
        // Remove the offset to get the viewport-relative x the edge zone is
        // defined in.
        if point.x - contentOffset.x <= Self.popEdgeZone { return true }
        // A horizontal drag that STARTS on horizontally-scrollable content
        // belongs to that content, not to the tab pager.
        //
        // Two `UIScrollView` pans do not recognise simultaneously and UIKit
        // picks no winner by depth, so without this the pager took every drag
        // and a post card's carousel could not be swiped at all — it changed
        // tab instead. Reported exactly that way.
        //
        // The inner view owns the gesture for its whole duration, including past
        // its last page: handing the pager the overflow would mean a drag that
        // starts as a carousel and finishes as a tab change, and a gesture whose
        // meaning depends on how far it got is worse than one that ends against
        // a stop.
        if let hit = hitTest(point, with: nil), Self.scrollsHorizontally(hit, within: self) {
            return true
        }
        return false
    }

    /// Whether `view` sits inside something — other than `container` — that owns
    /// horizontal drags: a scroll view with somewhere to go, or a view that says
    /// so.
    ///
    /// The width test matters: the feed's own vertical collection view is a
    /// scroll view on this path too, and its content is exactly as wide as it
    /// is. Without the test the pager would refuse every drag in the list.
    ///
    /// The declared case covers what the measured one cannot see — a control
    /// that scrubs with a pan recognizer rather than by scrolling, which has no
    /// content size to ask about.
    private static func scrollsHorizontally(_ view: UIView, within container: UIView) -> Bool {
        var node: UIView? = view
        while let current = node, current !== container {
            if current is HorizontalDragOwning { return true }
            if let scrollView = current as? UIScrollView,
               scrollView.contentSize.width > scrollView.bounds.width + 0.5 {
                return true
            }
            node = current.superview
        }
        return false
    }
}

/// A view that handles horizontal drags itself, without being a scroll view.
///
/// `HorizontalPagerScrollView` yields to horizontally scrollable content by
/// MEASURING it — content wider than its frame. A control that scrubs with a
/// pan recognizer has nothing to measure, so it declares instead. Conforming is
/// a statement about gestures only; it adds no requirements.
public protocol HorizontalDragOwning: UIView {}
