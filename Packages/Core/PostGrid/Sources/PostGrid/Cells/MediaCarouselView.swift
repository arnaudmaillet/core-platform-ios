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

    private let scrollView = UIScrollView()
    private var pageViews: [UIImageView] = []
    private var loadTasks: [Task<Void, Never>] = []

    override public init(frame: CGRect) {
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
        // The card's own fill, so the gutter between two pages and the ground
        // the peeking sliver rests on are the CARD, not a darker well. It is
        // what makes the pages read as pills lying on the card rather than as
        // frames cut into a panel.
        backgroundColor = PostGridListRowCell.cardFillColor
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    public func configure(with pages: [GalleryPost.MediaPage], imagePipeline: ImagePipeline) {
        cancelPendingWork()
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = pages.map { _ in
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.backgroundColor = .tertiarySystemFill
            // The pages carry the preview's own curve, not a smaller one: each
            // is a preview-sized window onto one photo, and a page rounded less
            // than the box it fills would show the box's corner through it.
            view.layer.cornerRadius = PostGridListRowCell.mediaCornerRadius
            view.layer.cornerCurve = .continuous
            scrollView.addSubview(view)
            return view
        }
        currentPage = 0
        scrollView.setContentOffset(.zero, animated: false)
        setNeedsLayout()
        layoutIfNeeded()

        for (index, page) in pages.enumerated() {
            guard let url = page.thumbnailURL else { continue }
            if let cached = imagePipeline.cachedImage(for: url) {
                pageViews[index].image = cached
                continue
            }
            let task = Task { [weak self] in
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
            }
            loadTasks.append(task)
        }
    }

    public func cancelPendingWork() {
        loadTasks.forEach { $0.cancel() }
        loadTasks.removeAll()
    }

    // MARK: - Layout

    /// The stride between two page origins: the page plus its gutter.
    private var stride: CGFloat { pageWidth + Self.gap }
    private var pageWidth: CGFloat { max(bounds.width - Self.peek, 1) }

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
        onPageChanged?(resolved)
    }
}
