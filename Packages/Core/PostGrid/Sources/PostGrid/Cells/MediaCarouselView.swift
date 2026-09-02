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
public final class MediaCarouselView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
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

    /// The recognizer behind `onTapped`, kept so the delegate below can tell it
    /// apart from the scroll view's own.
    private weak var tapRecognizer: UITapGestureRecognizer?

    /// Where the box is BETWEEN pages, as a fraction: 2.37 is "a third of the
    /// way from page two to page three".
    ///
    /// ⚠️ The continuous twin of `onPageChanged`, and both are needed. A page
    /// number is what a host acts on — load these, play that one — and a
    /// fraction is what a host DRAWS from: the strip under the post's caption
    /// reflows across the whole gesture, so a signal that only speaks at the
    /// crossing would leave it still until the page had already changed.
    public var onScrollPosition: ((CGFloat) -> Void)?


    /// Fired whenever the page under the box changes, so the host can move an
    /// indicator that lives OUTSIDE this view — see `PostGridListRowCell`, where
    /// the chips and the indicator belong to the preview rather than to its
    /// contents and must not travel with them.
    public var onPageChanged: ((Int) -> Void)?

    /// The page the box is showing, resolved from the offset rather than
    /// tracked, so a mid-flick read is never stale.
    public private(set) var currentPage = 0

    /// Whether the carousel can still travel `delta` pages — the question that
    /// decides whether a horizontal drag over it is the carousel's own or the
    /// surrounding surface's.
    ///
    /// ⚠️ THE DELTA IS IN PAGES, WHICH RUN THE OPPOSITE WAY TO THE FINGER. A
    /// rightward drag uncovers the page BEFORE this one and asks for `-1`; a
    /// leftward drag asks for `+1`. Stated as a delta rather than as two
    /// booleans because the callers are gesture gates that already hold a
    /// velocity, and the sign is the whole of what they know.
    ///
    /// Resolved from `currentPage`, never from `contentOffset`, and the
    /// difference is not cosmetic: `currentPage` is itself derived from the
    /// offset on every scroll tick and clamped to the run, so it keeps
    /// answering through a rubber-band. A raw offset does not — an overscroll
    /// past the start is negative and past the end is beyond the maximum, and
    /// both would report travel that does not exist, on exactly the drags this
    /// rule exists to route.
    ///
    /// A delta of zero is "direction unknown", and answers the older, weaker
    /// question: is there anywhere to go at all.
    public func hasTravel(towardsPageDelta delta: Int) -> Bool {
        guard delta != 0 else { return pageViews.count > 1 }
        return pageViews.indices.contains(currentPage + delta)
    }

    /// Whether a drag of `velocity` is one this carousel DECLINES outright.
    ///
    /// The other half of the pass-through rule, and the half that is easy to
    /// miss — the same half the edge strip below already had to be taught.
    /// Telling the screen's dismissal it MAY claim a rightward drag does not
    /// stop the carousel from claiming it too: both recognizers see the touch,
    /// the carousel's is the inner one, and it simply spent the gesture on a
    /// rubber-band. That is the reported symptom — a rightward drag on the first
    /// page of a collection did nothing at all.
    ///
    /// ⚠️ RIGHTWARD ONLY, and the mirror is deliberately NOT written here.
    /// Rightward is the direction that means "back" everywhere in this app: the
    /// system's edge pop, the tab pager's previous page, and the only horizontal
    /// direction the zoom dismissal is armed for (`ZoomDismissAxis.match`
    /// requires `velocity.x > 0`). Leftward means "onward", and on the surfaces a
    /// carousel actually lives on there is nobody to hand it to — the feed is
    /// forward-only and the dismissal is not listening. A drag given up to
    /// nobody would be worse than one that ends against a stop: the end-of-run
    /// rubber-band is at least an answer. Where something IS waiting for it —
    /// the tab pager, which has a next tab — that surface makes the mirror
    /// decision for itself, in `HorizontalPagerScrollView.shouldYield`.
    ///
    /// Predominantly horizontal, which is the MIRROR of the dismissal's own
    /// begin gate, so exactly one of the two claims any given drag — the same
    /// arrangement the feed's forward-only decline makes with the vertical axis.
    ///
    /// Internal so the rule is unit-testable: recognition cannot be driven from
    /// a test, and this is the decision that stands behind it.
    func yieldsRightwardDrag(velocity: CGPoint) -> Bool {
        velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
            && !hasTravel(towardsPageDelta: -1)
    }

    /// The image the CURRENT page is showing — what a hero flight departs with.
    /// A carousel's cover is not the post's first attachment once the viewer
    /// has moved.
    public var renderedCover: UIImage? {
        pageViews.indices.contains(currentPage) ? pageViews[currentPage].cover.image : nil
    }

    /// The CURRENT page's stream, nil when the page the viewer is on is a still.
    ///
    /// ⚠️ Not `GalleryPost.videoURL`, which answers for page one for ever. A
    /// mixed collection changes its answer as the viewer scrolls, and every
    /// caller that decides whether something plays has to ask here.
    public var currentPageVideoURL: URL? {
        pages.indices.contains(currentPage) ? pages[currentPage].videoURL : nil
    }

    /// Puts a playback surface on a given page, sized to it.
    ///
    /// The surfaces belong to the HOST — this only re-parents them, and the
    /// pool never learns that pages exist. What changed when clips began being
    /// kept warm is how many a carousel may hold: **one per page**, not one in
    /// total.
    public func host(_ surface: UIView, onPage index: Int) {
        guard pageViews.indices.contains(index) else { return }
        // ⚠️ Off its OLD page first — but only this surface, never theirs.
        //
        // This loop used to evict every other page unconditionally, which was
        // exactly right while a host owned one surface and walked it from page
        // to page: re-parenting alone leaves the page it came from still
        // believing it holds one. Now that neighbours keep their own clip warm, the
        // same loop would tear down everything the retention window just paid
        // for. So the question narrowed from "is this a different page" to "is
        // this page holding the view I am moving".
        for (position, view) in pageViews.enumerated()
        where position != index && view.hosts(surface) {
            _ = view.evictHostedSurface()
        }
        pageViews[index].host(surface)
    }

    /// Puts a surface on the page being looked at.
    public func host(_ surface: UIView) { host(surface, onPage: currentPage) }

    /// The surface hanging on `index`, if any — how a host finds the view it
    /// left there rather than keeping a second map of its own.
    public func hostedSurface(onPage index: Int) -> UIView? {
        pageViews.indices.contains(index) ? pageViews[index].hostedSurface : nil
    }

    /// Takes the surface off one page and reports it.
    @discardableResult
    public func evictSurface(onPage index: Int) -> UIView? {
        guard pageViews.indices.contains(index) else { return nil }
        return pageViews[index].evictHostedSurface()
    }

    /// Which page is holding `view`, nil when none is.
    public func page(hosting view: UIView) -> Int? {
        pageViews.firstIndex { $0.hosts(view) }
    }

    /// Shows or hides the stopped mark on ONE page.
    ///
    /// Addressed by page rather than "the current one" because the two are not
    /// the same question the moment a swipe is in flight: the viewer stops the
    /// page they are looking at, and by the time anything is reconciled the
    /// page under the finger may already be the next one.
    public func setPausedMark(_ visible: Bool, onPage index: Int) {
        guard pageViews.indices.contains(index) else { return }
        pageViews[index].setPausedMarkVisible(visible)
    }

    /// Takes down the mark on every page that has left the box.
    ///
    /// ⚠️ A mark is a receipt for a picture the viewer is LOOKING AT. Riding
    /// its page out of the screen is right — that is what makes it belong to
    /// the picture — but staying on a page nobody can see is bookkeeping, and
    /// bookkeeping that outlives its subject comes back wrong: the page is
    /// paused now because the carousel pauses what it leaves, not because
    /// anyone chose it, and arriving there again starts it anyway.
    ///
    /// Unanimated on purpose: there is nothing on screen to crossfade.
    private func retirePausedMarksOffScreen() {
        let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
        for page in pageViews where page.visiblePausedMark != nil && !page.frame.intersects(visible) {
            page.setPausedMarkVisible(false, animated: false)
        }
    }

    /// The mark on `index` while it is showing — the view itself, so a caller
    /// can ask where it is drawn rather than trust that it moved.
    public func visiblePausedMark(onPage index: Int) -> UIView? {
        pageViews.indices.contains(index) ? pageViews[index].visiblePausedMark : nil
    }

    /// Shows or hides the wait on ONE page.
    ///
    /// Addressed by page for the reason the mark is: the picture that is
    /// waiting and the picture in front of the viewer are the same question
    /// only while nothing is moving.
    public func setLoading(_ visible: Bool, onPage index: Int) {
        guard pageViews.indices.contains(index) else { return }
        pageViews[index].setLoadingVisible(visible)
    }

    /// Whether `index` is announcing a wait.
    public func isLoading(onPage index: Int) -> Bool {
        pageViews.indices.contains(index) && pageViews[index].visibleLoader != nil
    }

    /// The spinner on `index` while it is up — the view itself, so a spec can
    /// ask where it is drawn rather than trust that it travelled.
    public func visibleLoader(onPage index: Int) -> UIView? {
        pageViews.indices.contains(index) ? pageViews[index].visibleLoader : nil
    }

    /// Takes every wait down — the post is being handed a different one.
    public func clearLoaders() {
        for page in pageViews { page.setLoadingVisible(false) }
    }

    /// How many pages the carousel is showing.
    public var pageCount: Int { pages.count }

    /// The picture a given page is showing.
    ///
    /// ⚠️ Needed by anything that puts a surface on a page the viewer is NOT on.
    /// `renderedCover` answers for the current page, which is the right answer
    /// for a flight and the wrong one for a prewarm: handing a clip on page
    /// three the cover of page one, or none at all, is what makes a freshly
    /// hosted surface draw black over a photograph.
    public func cover(onPage index: Int) -> UIImage? {
        pageViews.indices.contains(index) ? pageViews[index].cover.image : nil
    }

    /// The indices of every page with a stream behind it, in order.
    ///
    /// The retention window's domain: it is chosen among THESE, never among all
    /// pages, so a gallery of twenty photographs and two clips keeps two
    /// players and not a window's worth of nothing.
    public var videoPageIndices: [Int] {
        pages.indices.filter { pages[$0].videoURL != nil }
    }

    /// The stream on a given page.
    public func videoURL(onPage index: Int) -> URL? {
        pages.indices.contains(index) ? pages[index].videoURL : nil
    }

    /// Whether `view` is already hanging in the page being looked at — the
    /// question a host has to ask before re-installing, so a surface that is
    /// where it belongs is never torn out and put back.
    public func hostsSurfaceOnCurrentPage(_ view: UIView) -> Bool {
        pageViews.indices.contains(currentPage) && pageViews[currentPage].hosts(view)
    }

    /// The stream of whichever page is holding `view`, nil when no page is.
    ///
    /// The pool's question — "what is this row still holding a player for" —
    /// which is not "what is the viewer looking at": a paused clip on page two
    /// keeps its player while page three is on screen.
    public func videoURL(ofPageHosting view: UIView) -> URL? {
        for (index, page) in pageViews.enumerated() where page.hosts(view) {
            return pages.indices.contains(index) ? pages[index].videoURL : nil
        }
        return nil
    }

    /// Takes the surface off whatever page is holding it. Called when the
    /// viewer pages onto a still, and when the row stops playing.
    ///
    /// ⚠️ Searches every page rather than trusting `currentPage`: the page
    /// changes BEFORE anyone is told, so by the time a host reacts the surface
    /// is on the page the viewer just left.
    @discardableResult
    public func evictHostedSurface() -> UIView? {
        for view in pageViews {
            if let surface = view.evictHostedSurface() { return surface }
        }
        return nil
    }

    /// The current page's rect in a given view's space. The flight departs from
    /// the PAGE, not the box: the box is wider by `peek` and holds a slice of a
    /// different photo, so flying it would carry two images.
    public func currentPageRect(in view: UIView) -> CGRect? {
        guard pageViews.indices.contains(currentPage) else { return nil }
        return pageViews[currentPage].convert(pageViews[currentPage].bounds, to: view)
    }

    private let scrollView = EdgeYieldingScrollView()
    /// The pages themselves, in order.
    ///
    /// Readable inside the package so a test can ask which PAGE is dimmed.
    /// Concealment applies to the page, and a walk for image views answers for
    /// the layers inside one.
    private(set) var pageViews: [CarouselPageView] = []
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
        scrollView.carousel = self
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
        //
        // ⚠️ `cancelsTouchesInView = false` IS NOT THE WHOLE OF "does not
        // consume". It governs touch delivery to VIEWS; recognition is the
        // other channel, and there a recognizer that wins PREVENTS the ones it
        // does not recognize simultaneously with — including an ancestor's.
        // This tap is nearer the touch than anything the host has, so it wins
        // every time, and on a screen where nobody set `onTapped` it won in
        // order to do nothing at all. That is how the post screen's
        // tap-to-pause came to work on a single clip and never on a gallery:
        // same cell, same recognizer, silently prevented by this one.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tapRecognizer = tap
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
        pageViews = pages.map { page in
            let view = CarouselPageView()
            // ⚠️ A page knows whether it is PLAYABLE, and it is per page.
            //
            // Nothing in `post.v1` says a carousel's attachments agree about
            // their type — each carries its own MIME, and the client hydrates
            // `MediaPage.videoURL` from it one page at a time. A carousel that
            // asked the POST whether it was a video would answer for page one
            // and be wrong about every other page.
            view.isPlayable = page.videoURL != nil
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
                pageViews[index].cover.image = cached
                continue
            }
            loadTasks.append(Task { [weak self] in
                guard let image = try? await imagePipeline.image(for: url),
                      !Task.isCancelled, let self,
                      self.pageViews.indices.contains(index) else { return }
                let view = self.pageViews[index].cover
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

    /// Whether the tap has anybody to report to — the whole of its right to
    /// recognize. A discrete recognizer is asked this before it recognizes, so
    /// a `false` here fails it outright and leaves the touch to whoever else
    /// wants it, which on the post screen is the page's own play/pause.
    ///
    /// Internal so the rule is unit-testable: recognition itself cannot be
    /// driven from a test, and this is the decision that stands behind it.
    func tapHasAListener() -> Bool { onTapped != nil }

    /// ⚠️ In the class body, not an extension: this is an OVERRIDE of `UIView`'s
    /// own hook as well as the delegate callback, and Swift takes overrides
    /// only here. One implementation serves both, which is the point — the two
    /// routes must not be able to answer differently.
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tapRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return tapHasAListener()
    }

    /// How long a press must last before it is a hold rather than a tap.
    /// Matches the post screen's, so the gesture feels the same on both.
    public static let holdToPauseDuration: TimeInterval = 0.2

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
    /// The resting offset of a page, so a test can state its expectation in
    /// pages rather than in arithmetic it would have to duplicate.
    func debugOffset(forPage index: Int) -> CGFloat { offset(forPage: index) }

    private func offset(forPage index: Int) -> CGFloat {
        let maximum = max(scrollView.contentSize.width - bounds.width, 0)
        return min(CGFloat(index) * stride, maximum)
    }

    /// The box's position in pages, fractionally — clamped to the run, because
    /// a rubber-banded overscroll is not a page and a strip drawn from it would
    /// stretch off its own end.
    public var scrollPosition: CGFloat {
        guard stride > 0, pageViews.count > 1 else { return 0 }
        let raw = scrollView.contentOffset.x / stride
        return min(max(raw, 0), CGFloat(pageViews.count - 1))
    }

    private func page(nearest offset: CGFloat) -> Int {
        guard stride > 0 else { return 0 }
        let raw = Int((offset / stride).rounded())
        return min(max(raw, 0), max(pageViews.count - 1, 0))
    }

    // MARK: - Snapping

    /// The page the CURRENT drag started on.
    ///
    /// ⚠️ WHERE THE FINGER WENT DOWN, not where it came up — and the difference
    /// is the whole of "one gesture, one page".
    ///
    /// The clamp below allows one page either side of an anchor, and that
    /// anchor used to be read when the finger LIFTED. By then the drag has
    /// already moved the content: throw across the width of the card and the
    /// content is a page along before the flick is even considered, so the
    /// clamp permits one MORE and the gesture lands two pages away. Measured
    /// with four identical throws — `from=1 -> 2`, `from=2 -> 3`, `from=3 -> 4`,
    /// then `from=5`, a page nobody stopped on.
    ///
    /// Reported as "if I slide hard I scroll several photos at once", and it is
    /// the same complaint the projected-offset rule was written for, one layer
    /// further in: momentum decides how fast a page arrives, never how many.
    private var dragAnchorPage: Int?

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragAnchorPage = page(nearest: scrollView.contentOffset.x)
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // Snap from the PROJECTED offset, not the current one: a flick that has
        // barely moved the content still means "next page", and reading the
        // live offset here would answer "stay".
        // ⚠️ THE PAGE THE GESTURE STARTED ON is the anchor, and every outcome is
        // measured from it — see `dragAnchorPage` for why it is not read here.
        //
        // The projected offset says where a flick would coast to, which on a
        // hard swipe is three or four pages away. That is a scroll, not paging:
        // the viewer asked for the next photograph and got a blur and a
        // stranger.
        // Falls back to the live offset only if a drag somehow ended without
        // beginning — the honest answer for a gesture nobody saw start.
        let from = dragAnchorPage ?? page(nearest: scrollView.contentOffset.x)
        dragAnchorPage = nil
        var index = page(nearest: targetContentOffset.pointee.x)
        let coasted = index
        // A deliberate flick always advances at least one page, which is what
        // makes a short swipe feel like paging rather than like a nudge that
        // sprang back.
        if abs(velocity.x) > 0.2 {
            index = velocity.x > 0 ? max(index, from + 1) : min(index, from - 1)
        }
        // ⚠️ AND AT MOST ONE, however hard the flick.
        //
        // One gesture, one page. Momentum decides how FAST it gets there, never
        // how far — so a violent swipe and a careful one land on the same
        // photograph, and the viewer can always predict what a swipe will do
        // without calibrating their thumb.
        index = min(max(index, from - 1), from + 1)
        index = min(max(index, 0), max(pageViews.count - 1, 0))
        targetContentOffset.pointee.x = offset(forPage: index)
        #if DEBUG
        if CarouselPlaybackAudit.isEnabled {
            // The whole decision in one line, because "did the clamp run?" is
            // otherwise indistinguishable from "the clamp ran and the gesture
            // genuinely started a page further along" — which is what two
            // swipes in quick succession look like.
            CarouselPlaybackAudit.trace(
                String(format: "snap from=%d coast=%d -> %d v=%.2f",
                       from, coasted, index, velocity.x)
            )
        }
        #endif
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

    /// Scrolls to an arbitrary offset — the fractional positions a real drag
    /// passes through and `setPage` cannot express, which is where "has this
    /// page left the box yet" is actually decided.
    func debugScroll(toOffsetX x: CGFloat) {
        scrollView.contentOffset.x = x
        scrollViewDidScroll(scrollView)
    }
    #endif

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Before the page-change guard below: a mark's page can leave the box
        // without the RESOLVED page changing again (the drag that carries it
        // out is the same one that already changed it).
        retirePausedMarksOffScreen()
        onScrollPosition?(scrollPosition)
        let resolved = page(nearest: scrollView.contentOffset.x)
        guard resolved != currentPage else { return }
        currentPage = resolved
        applyPageConcealment()
        loadPagesAroundCurrent()
        onPageChanged?(resolved)
    }
}

/// The carousel's scroll view, which refuses touches it has nothing to spend:
/// those that start in the screen's leading-edge strip, and those that pull
/// rightward when there is no page to the left.
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
/// ⚠️ The SAME missing half, a second time, is what
/// `MediaCarouselView.yieldsRightwardDrag` is here for. The snap feed's gate had
/// been answering "permitted" on the first page since the day it was written,
/// and the drag still died in this scroll view's rubber-band.
///
/// Window coordinates for the strip, not the view's: it is a property of the
/// SCREEN, and a carousel inside a card sits nowhere near it — which is exactly
/// what should keep that rule from firing there.
private final class EdgeYieldingScrollView: UIScrollView {
    /// Matched to `HorizontalPagerScrollView`'s own zone, which yields the same
    /// strip to the same gesture.
    private static let backEdgeZone: CGFloat = 20

    /// The carousel this box scrolls, so the pan can ask what it has left to
    /// travel. Weak, and set at construction — the scroll view is a subview and
    /// never outlives its owner.
    weak var carousel: MediaCarouselView?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === panGestureRecognizer {
            if let window {
                // The gesture's ORIGIN, not where the finger is now: a pan is
                // only asked once it has travelled its slop, so reading the live
                // location puts a drag that started on the edge tens of points
                // inside it.
                let x = pan.location(in: window).x - pan.translation(in: window).x
                if x - window.bounds.minX <= Self.backEdgeZone { return false }
            }
            // Velocity, not translation: this is asked once, at the moment the
            // pan has earned its slop, and the direction the hand is travelling
            // then is what the gesture means.
            if carousel?.yieldsRightwardDrag(velocity: pan.velocity(in: self)) == true {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// One page of a carousel: a cover, and room for a playback surface over it.
///
/// A page used to BE its `UIImageView`, which was right while a collection was
/// photographs. It cannot be once the pages disagree about their type: a video
/// page has two layers where a still has one.
///
/// ⚠️ NO PLAY BADGE, deliberately — see `isPlayable`.
final class CarouselPageView: UIView {
    let cover = UIImageView()

    /// Whether this page has a stream behind it.
    ///
    /// ⚠️ NOTHING IS DRAWN FOR IT ANY MORE, and that is the point: a clip on
    /// this card STARTS BY ITSELF, so the picture moving is what says "video",
    /// and it says it better than a glyph can. A badge over a playing clip is a
    /// label on the thing it describes; a badge over one that has not started
    /// yet is an invitation to press something that is not a button.
    ///
    /// Kept as a flag because the carousel still reasons about which pages can
    /// play — the badge was a rendering of this answer, never the answer.
    var isPlayable = false

    /// The host's playback surface while this page is holding it.
    private weak var surface: UIView?

    /// The mark this page wears while the viewer has its clip stopped.
    ///
    /// ⚠️ ON THE PAGE, so it travels with it. The mark used to be centred on
    /// the SCREEN, one per post — which is a lie the moment a post has more
    /// than one picture: swiping left carried a stopped page's mark onto the
    /// page arriving, over a clip that was playing. A page is what scrolls, so
    /// a page is what carries the answer.
    ///
    /// Minted on first use: most pages never wear one.
    private var pausedMark: PausedClipMarkView?

    /// The wait, ON THE PAGE, for the reason the mark is on it.
    ///
    /// A spinner centred on the POST says "something here is loading" and then
    /// points at the wrong picture the moment a swipe carries an arrived one in
    /// front of it — the page that is actually waiting has scrolled away and
    /// left its announcement behind. What is waiting is a MEDIA, so the media's
    /// page is what carries the answer, exactly as it carries its stopped mark.
    ///
    /// Minted on first use: most pages never wait long enough to show one.
    private var loader: UIActivityIndicatorView?

    /// The surface this page is REALLY holding — both halves again, for the
    /// same reason `hosts(_:)` asks both: a weak reference outlives the view
    /// being taken away by a flight, and a page that answered from the
    /// reference alone would hand back a view hanging nowhere.
    var hostedSurface: UIView? {
        guard let surface, surface.superview === self else { return nil }
        return surface
    }

    /// Whether this page is REALLY holding `view` — both halves, for the reason
    /// `host` states: a weak reference outlives the view being taken away.
    func hosts(_ view: UIView) -> Bool { surface === view && view.superview === self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Frames, not constraints — the carousel lays its pages out by frame on
    /// every width change, and a page that mixed the two would fight it.
    override func layoutSubviews() {
        super.layoutSubviews()
        cover.frame = bounds
        surface?.frame = bounds
        pausedMark?.frame = bounds
        loader?.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Shows or hides this page's stopped mark.
    func setPausedMarkVisible(_ visible: Bool, animated: Bool = true) {
        guard visible || pausedMark != nil else { return }
        let mark = pausedMark ?? {
            let view = PausedClipMarkView()
            view.frame = bounds
            addSubview(view)
            pausedMark = view
            return view
        }()
        // Above the picture, whichever picture this page is showing — a
        // surface hosted after the mark would otherwise cover it.
        bringSubviewToFront(mark)
        mark.setVisible(visible, animated: animated)
    }

    /// The mark itself when it is showing, so a caller can ask WHERE it is
    /// drawn — the whole claim being that it rides this page.
    var visiblePausedMark: UIView? { pausedMark?.isShowing == true ? pausedMark : nil }

    /// Shows or hides this page's wait.
    func setLoadingVisible(_ visible: Bool) {
        guard visible || loader != nil else { return }
        let spinner = loader ?? {
            let view = UIActivityIndicatorView(style: .medium)
            // ⚠️ WHITE, not `.label`: the ground here is a photograph or black,
            // never a theme, so a semantic colour would resolve against a
            // background this view does not have. Same rule as the card's own.
            view.color = .white
            view.hidesWhenStopped = true
            view.sizeToFit()
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
            addSubview(view)
            loader = view
            return view
        }()
        // Above the picture, whichever picture this page is showing — a surface
        // hosted after the spinner would otherwise cover it.
        bringSubviewToFront(spinner)
        if visible { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    /// The spinner while it is up, so a caller can ask WHERE it is drawn rather
    /// than trust that it moved.
    var visibleLoader: UIView? { loader?.isAnimating == true ? loader : nil }

    func host(_ surface: UIView) {
        // ⚠️ IDENTITY IS NOT ENOUGH — ask whether it is actually here.
        //
        // A hero flight takes the surface by `removeFromSuperview`, which the
        // page cannot see: its reference is weak and the flight card retains
        // the view, so the page went on believing it held one. Re-hosting the
        // same object at the landing then hit this guard and returned, the
        // surface was never re-inserted, and the page showed its cover — a
        // living player hanging nowhere. The next flight duly flew a thumbnail.
        //
        // It cleared itself on the following page change, which is why a second
        // attempt always worked and the first never did.
        guard surface !== self.surface || surface.superview !== self else { return }
        self.surface = surface
        // Over the cover: the picture replaces the poster the moment it has a
        // frame of its own, and nothing sits above it — except the stopped
        // mark, which is about the picture and has to stay on top of it.
        addSubview(surface)
        if let pausedMark { bringSubviewToFront(pausedMark) }
        setNeedsLayout()
    }

    /// Gives the surface back and reports it, so a caller can hand it on.
    @discardableResult
    func evictHostedSurface() -> UIView? {
        guard let surface else { return nil }
        surface.removeFromSuperview()
        self.surface = nil
        return surface
    }
}
