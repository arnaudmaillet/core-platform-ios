import MediaCore
import UIKit

/// The pages of a collection post, scrolled horizontally inside a row's
/// preview.
///
/// ## The peek is the affordance
///
/// A page is narrower than the box by `peek`, so the next one is always partly
/// on screen. That sliver is the whole reason the layout is not plain paging:
/// nothing else on a card says "there is more here", and a dots indicator says
/// it only after the viewer has already looked at the bottom edge. The
/// interrupted image says it where the eye already is.
///
/// The last page is the exception and has to be: it lands flush against the
/// box's trailing edge, so what peeks there is the PREVIOUS page on the left.
/// Anything else leaves a strip of empty box at the end of the scroll, which
/// reads as a broken layout rather than as an end.
///
/// ## Not `isPagingEnabled`
///
/// UIKit's paging steps by the scroll view's own width, which is the box — so
/// every stop would be off by `peek` and accumulate. The stride is the page
/// plus its gap, and the snap is done in `scrollViewWillEndDragging` against
/// that stride, with `decelerationRate = .fast` so a flick still feels like
/// paging rather than like a free scroll.
///
/// ## Frames, not constraints
///
/// This lives inside a cell that a collection view recycles and re-lays out on
/// every width change; the package's layout note asks hot cells to place their
/// subviews in `layoutSubviews` from precomputed sizes, and a carousel of image
/// views is exactly that case.
public final class MediaCarouselView: UIView, UIScrollViewDelegate {
    /// Where this carousel is: inside a card, or filling a page.
    ///
    /// ONE carousel with two styles rather than two carousels. The snapping, the
    /// projected-offset flick rule, the page reporting and the current-page
    /// cover are the same problem on both surfaces, and this package has already
    /// paid for twins that drift — the tab-swipe fix went into one of two pagers
    /// and did nothing on the surface it was reported against.
    ///
    /// What genuinely differs is the frame the pages live in:
    ///
    /// * **`.card`** — pages narrower than the box, so the next one peeks. The
    ///   peek is the affordance there: nothing else on a card says the post has
    ///   more than one photograph.
    /// * **`.page`** — full-bleed, edge to edge, no peek and no gutter. A peek
    ///   would run a stripe of another photograph down the side of a screen that
    ///   IS the photograph, and the indicator over the comment band already says
    ///   what the peek was there to say.
    public enum Style: Equatable, Sendable {
        case card
        case page
    }

    /// The gutter between two pages, showing the card's own fill — which is
    /// what keeps the peeking sliver from reading as part of the current photo.
    public static let gap: CGFloat = 6

    /// How much of the neighbour is on screen at rest, and it is DERIVED rather
    /// than chosen: twice the page's corner radius.
    ///
    /// At that width the sliver's rounding exactly consumes it. A page is
    /// rounded at `mediaCornerRadius`, so a visible strip of `2 × radius` has no
    /// straight top or bottom edge at all — the two quarter-circles meet, and
    /// what shows is the leading half of a vertical capsule rather than a slab
    /// with slightly soft corners. One point narrower and the curve is cut
    /// mid-arc; one point wider and a flat segment appears between the ends.
    public static var neighbourWidth: CGFloat { PostGridListRowCell.mediaCornerRadius * 2 }

    /// How far the next page's leading edge sits inside the box. The gutter
    /// falls INSIDE this, which is the arithmetic that was wrong first time:
    /// with `peek` measured to the page's edge, the gap ate into the sliver and
    /// what showed was `peek - gap`.
    public static var peek: CGFloat { neighbourWidth + gap }

    /// A page was tapped.
    ///
    /// ⚠️ This exists because a nested scroll view SWALLOWS a collection view's
    /// selection. `UICollectionView` drives selection from touches on its own
    /// scroll machinery, and a scroll view in the content path consumes them —
    /// so once a card's media became a carousel, tapping the photograph did
    /// nothing at all, which is the one thing a post card must always do.
    ///
    /// A tap recognizer here, forwarded by the cell to whatever opens the post,
    /// rather than a hole in `hitTest`: the pages still have to receive the pan.
    public var onTapped: (() -> Void)?

    /// Fired whenever the page under the box changes, so the host can move an
    /// indicator that lives OUTSIDE this view — see `PostGridListRowCell`, where
    /// the chips and the indicator belong to the preview rather than to its
    /// contents and must not travel with them.
    public var onPageChanged: ((Int) -> Void)?

    /// The page the box is showing, resolved from the offset rather than
    /// tracked, so a mid-flick read is never stale.
    public private(set) var currentPage = 0

    /// The image the CURRENT page is showing — what a hero flight departs with.
    /// A carousel's cover is not the post's first attachment once the viewer
    /// has moved.
    public var renderedCover: UIImage? {
        pageViews.indices.contains(currentPage) ? pageViews[currentPage].image : nil
    }

    /// The current page's rect in a given view's space. The flight departs from
    /// the PAGE, not the box: the box is wider by `peek` and holds a slice of a
    /// different photo, so flying it would carry two images.
    public func currentPageRect(in view: UIView) -> CGRect? {
        guard pageViews.indices.contains(currentPage) else { return nil }
        return pageViews[currentPage].convert(pageViews[currentPage].bounds, to: view)
    }

    private let scrollView = EdgeYieldingScrollView()
    private var pageViews: [UIImageView] = []
    private var loadTasks: [Task<Void, Never>] = []
    private var pages: [GalleryPost.MediaPage] = []
    private var imagePipeline: ImagePipeline?
    /// Which pages have been asked for. A SET rather than a count, because the
    /// window moves in both directions and a page must never be fetched twice.
    private var loadedPages: Set<Int> = []
    private let style: Style

    public init(style: Style = .card, frame: CGRect = .zero) {
        self.style = style
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        // See the type note: paging by the box's width would be off by `peek`.
        scrollView.isPagingEnabled = false
        scrollView.decelerationRate = .fast
        scrollView.delegate = self
        scrollView.clipsToBounds = false
        addSubview(scrollView)
        clipsToBounds = true
        // A tap only fires when no drag happened, so it never competes with the
        // pan — and it does not consume the touch, so anything else listening
        // still hears it.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        // On THIS view, not on the scroll view. `UIScrollView` overrides
        // `gestureRecognizerShouldBegin` for recognizers it does not own, and a
        // tap added there never fired — the card's photograph was untappable
        // and the post would not open. An ancestor recognizer still receives
        // touches that land on the pages.
        addGestureRecognizer(tap)
        switch style {
        case .card:
            // The card's own fill, so the gutter between two pages and the
            // ground the peeking sliver rests on are the CARD, not a darker
            // well. It is what makes the pages read as pills lying on the card
            // rather than as frames cut into a panel.
            backgroundColor = PostGridListRowCell.cardFillColor
        case .page:
            // Nothing shows between full-bleed pages, and whatever the page's
            // own background is has to show through while a photo loads.
            backgroundColor = .clear
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    public func configure(with pages: [GalleryPost.MediaPage], imagePipeline: ImagePipeline) {
        // ⚠️ The SAME pages again is not a reason to rebuild.
        //
        // A snap page configures its cell twice on open — a seeded model, then
        // the hydrated one 140ms later — and both carry the same collection.
        // Rebuilding on the second reset the offset, so a post opened on page
        // three landed on page three and then slid back to page one on its own.
        // It also means any later model refresh cannot yank a viewer's carousel
        // out from under them.
        guard pages != self.pages else { return }
        cancelPendingWork()
        pageViews.forEach { $0.removeFromSuperview() }
        self.pages = pages
        self.imagePipeline = imagePipeline
        loadedPages = []
        pageViews = pages.map { _ in
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            switch self.style {
            case .card:
                view.backgroundColor = .tertiarySystemFill
                // The pages carry the preview's own curve, not a smaller one:
                // each is a preview-sized window onto one photo, and a page
                // rounded less than the box it fills would show the box's
                // corner through it.
                view.layer.cornerRadius = PostGridListRowCell.mediaCornerRadius
                view.layer.cornerCurve = .continuous
            case .page:
                // Square and clear: a full-bleed page has no corners of its own
                // and nothing behind it but the post.
                view.backgroundColor = .clear
            }
            scrollView.addSubview(view)
            return view
        }
        currentPage = 0
        scrollView.setContentOffset(.zero, animated: false)
        setNeedsLayout()
        layoutIfNeeded()
        loadPagesAroundCurrent()
    }

    /// Fetches the current page and its immediate neighbours, and nothing else.
    ///
    /// ⚠️ It used to fetch every page the moment the carousel was configured,
    /// which is the one decision in this view that cost real time. A collection
    /// of four opened four downloads at once, on the card AND again full-screen,
    /// and they competed with the fetches the page actually needed — the comment
    /// stream arrived seconds late and the post read as half-built. Reported as
    /// "a huge delay before the post is fully operational".
    ///
    /// One neighbour each side, not two: the peek already shows part of the next
    /// page, so it must be loaded before it is looked at, and beyond that a page
    /// cannot be reached without a drag that gives the fetch its own time.
    private func loadPagesAroundCurrent() {
        guard let imagePipeline else { return }
        let window = (currentPage - 1)...(currentPage + 1)
        for index in window where pages.indices.contains(index) {
            guard !loadedPages.contains(index), let url = pages[index].thumbnailURL else { continue }
            loadedPages.insert(index)
            if let cached = imagePipeline.cachedImage(for: url) {
                pageViews[index].image = cached
                continue
            }
            loadTasks.append(Task { [weak self] in
                guard let image = try? await imagePipeline.image(for: url),
                      !Task.isCancelled, let self,
                      self.pageViews.indices.contains(index) else { return }
                let view = self.pageViews[index]
                UIView.transition(
                    with: view, duration: 0.25,
                    options: [.transitionCrossDissolve, .allowUserInteraction]
                ) {
                    view.image = image
                }
            })
        }
    }

    @objc private func handleTap() {
        onTapped?()
    }

    // MARK: - Hero concealment

    /// Hides ONLY the page a flight is carrying.
    ///
    /// CONCEAL EXACTLY WHAT THE FLIGHT REPRODUCES — the rule the row cell states
    /// for its preview, one level further in. A flight from a collection carries
    /// the current PAGE (`currentPageRect`, `renderedCover`), so the current page
    /// is what has to disappear. Concealing the whole carousel took the
    /// neighbour's peek with it, and the strip came back in a single frame at the
    /// landing — the same pop the row's own note describes, in miniature.
    ///
    /// Alpha, not `isHidden`: `currentPageRect` is the rect the DISMISSAL flies
    /// home to, and a hidden page still has to be able to say where it is.
    public func setCurrentPageConcealed(_ concealed: Bool) {
        isCurrentPageConcealed = concealed
        applyPageConcealment()
    }

    /// Re-applied whenever the page changes, because the concealed page is
    /// identified by INDEX: a page change while a flight is out would otherwise
    /// leave the wrong one invisible.
    private func applyPageConcealment() {
        for (index, view) in pageViews.enumerated() {
            view.alpha = isCurrentPageConcealed && index == currentPage ? 0 : 1
        }
    }

    private var isCurrentPageConcealed = false

    public func cancelPendingWork() {
        loadTasks.forEach { $0.cancel() }
        loadTasks.removeAll()
    }

    // MARK: - Layout

    /// The stride between two page origins: the page plus its gutter.
    private var stride: CGFloat { pageWidth + gutter }
    private var pageWidth: CGFloat { max(bounds.width - trailingPeek, 1) }
    /// Zero on a page: full-bleed media has no neighbour to show and no ground
    /// to show it on.
    private var trailingPeek: CGFloat { style == .card ? Self.peek : 0 }
    private var gutter: CGFloat { style == .card ? Self.gap : 0 }

    override public func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard !pageViews.isEmpty, bounds.width > 0 else { return }
        for (index, view) in pageViews.enumerated() {
            view.frame = CGRect(
                x: CGFloat(index) * stride, y: 0, width: pageWidth, height: bounds.height
            )
        }
        // The last page ends flush with the box, so the content is the stride
        // of all but the last plus one full PAGE — not one full box. The
        // difference is the strip of emptiness that would otherwise sit after
        // the final photo.
        let content = CGFloat(pageViews.count - 1) * stride + pageWidth
        scrollView.contentSize = CGSize(width: content, height: bounds.height)
    }

    /// Where page `index` rests, clamped so the last one lands flush.
    private func offset(forPage index: Int) -> CGFloat {
        let maximum = max(scrollView.contentSize.width - bounds.width, 0)
        return min(CGFloat(index) * stride, maximum)
    }

    private func page(nearest offset: CGFloat) -> Int {
        guard stride > 0 else { return 0 }
        let raw = Int((offset / stride).rounded())
        return min(max(raw, 0), max(pageViews.count - 1, 0))
    }

    // MARK: - Snapping

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // Snap from the PROJECTED offset, not the current one: a flick that has
        // barely moved the content still means "next page", and reading the
        // live offset here would answer "stay".
        var index = page(nearest: targetContentOffset.pointee.x)
        // A deliberate flick always advances at least one page, which is what
        // makes a short swipe feel like paging rather than like a nudge that
        // sprang back.
        if abs(velocity.x) > 0.2 {
            let from = page(nearest: scrollView.contentOffset.x)
            index = velocity.x > 0 ? max(index, from + 1) : min(index, from - 1)
            index = min(max(index, 0), max(pageViews.count - 1, 0))
        }
        targetContentOffset.pointee.x = offset(forPage: index)
    }

    /// Moves to a page. Returns false when there is no such page — the answer a
    /// caller must not mistake for success.
    ///
    /// Public because the page indicator drives it: the dots are a CONTROL, not
    /// a readout, and a control that reported a page it could not reach would be
    /// worse than no control at all.
    @discardableResult
    public func setPage(_ index: Int, animated: Bool = true) -> Bool {
        guard pageViews.indices.contains(index) else { return false }
        layoutIfNeeded()
        scrollView.setContentOffset(CGPoint(x: offset(forPage: index), y: 0), animated: animated)
        // A non-animated move reports itself rather than relying on the delegate
        // firing before the caller's next line.
        if !animated { scrollViewDidScroll(scrollView) }
        return true
    }

    #if DEBUG
    /// The simulator injects no touches, so this is how the carousel is reached
    /// in an automated run — and the property most worth checking is invisible
    /// in a still: that the chips and the indicator, which belong to the PREVIEW
    /// rather than to its contents, do not travel with the pages.
    @discardableResult
    public func debugScroll(toPage index: Int, animated: Bool = true) -> Bool {
        setPage(index, animated: animated)
    }
    #endif

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let resolved = page(nearest: scrollView.contentOffset.x)
        guard resolved != currentPage else { return }
        currentPage = resolved
        applyPageConcealment()
        loadPagesAroundCurrent()
        onPageChanged?(resolved)
    }
}

/// The carousel's scroll view, which refuses touches that start in the screen's
/// leading-edge strip.
///
/// Half of a rule, and the half that is easy to miss. Telling the dismissal it
/// MAY claim an edge drag does not stop the carousel from claiming it too: both
/// recognizers see the touch, the carousel's is the inner one, and it simply
/// paged. Measured — an edge drag on page three went back a page instead of
/// dismissing, with the destination's gate already returning "permitted".
///
/// So the tenant yields as well. That strip is the system's back gesture, and a
/// carousel borrowing it would make the one gesture that always means "back"
/// mean something else on the screens hardest to leave.
///
/// Window coordinates, not the view's: the strip is a property of the SCREEN,
/// and a carousel inside a card sits nowhere near it — which is exactly what
/// should keep this rule from firing there.
private final class EdgeYieldingScrollView: UIScrollView {
    /// Matched to `HorizontalPagerScrollView`'s own zone, which yields the same
    /// strip to the same gesture.
    private static let backEdgeZone: CGFloat = 20

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer,
           pan === panGestureRecognizer, let window {
            // The gesture's ORIGIN, not where the finger is now: a pan is only
            // asked once it has travelled its slop, so reading the live location
            // puts a drag that started on the edge tens of points inside it.
            let x = pan.location(in: window).x - pan.translation(in: window).x
            if x - window.bounds.minX <= Self.backEdgeZone { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
