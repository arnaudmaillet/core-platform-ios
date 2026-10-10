import DesignSystem
import MediaCore
import MediaPlayback
import UIKit

/// The pages of a collection post, scrolled horizontally inside a row's
/// preview.
///
/// ## A card shows a strip, not a page
///
/// On a card the pages are a STRIP of portrait items, several on screen at
/// once — two whole and a third cropped by the box's edge, the way For You's
/// Following row shows its cards (2026-10-02, asked for: "shorter, more
/// items visible"). The crop is the affordance now: nothing else on a card
/// says "there is more here", and an item cut by the edge says it where the
/// eye already is. The strip is also what keeps a collection's card short:
/// its height is an item's (3:4), not the post's own shape across the whole
/// box. It REPLACES the earlier rule — one page nearly the box's width with
/// a `2 × radius` sliver of the next showing as a vertical pill — which made
/// every collection the tallest card on the screen.
///
/// The strip rests on an ITEM'S EDGE, the gesture picking the edge
/// (`RowEdgeSnap`, the rows' rule): forward lands an item flush with the
/// box's right edge, back one flush with its left; the start is the first
/// item flush left and the end the last flush right, so the scroll never
/// ends on a strip of empty box.
///
/// The "current page" — the one that plays, that a hero flies, that the dots
/// show — is the most visible item, and among equally visible ones the one
/// the offset's progress through the run points at (`focusPage(atOffset:)`),
/// so the first rest is the first page and the last rest the last page. A tap or a
/// host's `setPage` names it outright.
///
/// ## Not `isPagingEnabled`
///
/// UIKit's paging steps by the scroll view's own width, which is the box — so
/// every stop would be off by whatever of a neighbour shows. The snap is done
/// in `scrollViewWillEndDragging`, with `decelerationRate = .fast` so a flick
/// still feels decided rather than like a free scroll.
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
    /// * **`.card`** — a strip of portrait items, several on screen, the one
    ///   cut by the box's edge saying there is more (see the type note).
    /// * **`.page`** — full-bleed, edge to edge, one page at a time, no gutter.
    ///   A neighbour would run a stripe of another photograph down the side of
    ///   a screen that IS the photograph, and the indicator over the comment
    ///   band already says the post has more.
    public enum Style: Equatable, Sendable {
        case card
        case page
    }

    /// The gutter between two items of a card's strip, showing the card's own
    /// fill — which is what keeps two pictures from reading as one.
    public static let gap: CGFloat = 6

    /// Items per box width on a card: two whole and a third cropped by the
    /// box's right edge — the Following row's count (`ForYouRailsView
    /// .Metrics.cardsPerWidth`), so the two strips on For You read as one
    /// family.
    public static let cardPagesPerBox: CGFloat = 2.3

    /// An item's height over its width on a card: 3:4 portrait, the Following
    /// row's card shape. Every item of a strip shares it — a strip of mixed
    /// heights has no single box to live in — and each picture FILLS its item.
    public static let cardPageAspect: CGFloat = 4.0 / 3.0

    /// How many items a card's box shows at rest for a collection of
    /// `pageCount`: `cardPagesPerBox`, or exactly all of them when there are
    /// fewer — two pages share the box half and half rather than leaving a
    /// third of it empty after the second.
    public static func cardPagesVisible(pageCount: Int) -> CGFloat {
        min(cardPagesPerBox, CGFloat(max(pageCount, 1)))
    }

    /// The width of one item of a card's strip in a box `boxWidth` wide.
    ///
    /// The whole items and the gaps after them, then the fraction of one more:
    /// `2 × w + 2 × gap + 0.3 × w = box`. With exactly as many items as fit,
    /// there is no gap after the last. Whole points, so every item's edges —
    /// and every offset a snap computes from them — fall on the pixel grid.
    public static func cardPageWidth(forBoxWidth boxWidth: CGFloat, pageCount: Int) -> CGFloat {
        let visible = cardPagesVisible(pageCount: pageCount)
        let whole = visible.rounded(.down)
        let gaps = visible == whole ? whole - 1 : whole
        return max(1, ((boxWidth - gaps * gap) / visible).rounded(.down))
    }

    /// How tall a card's box is for a collection of `pageCount` in a box
    /// `boxWidth` wide: one item's height. A pure function of the two, like
    /// `PostGridListRowCell.mediaHeight(forCardWidth:aspectRatio:)`, so the
    /// row's height never waits on a picture.
    public static func cardHeight(forBoxWidth boxWidth: CGFloat, pageCount: Int) -> CGFloat {
        guard boxWidth > 0 else { return 0 }
        return (cardPageWidth(forBoxWidth: boxWidth, pageCount: pageCount) * cardPageAspect).rounded()
    }

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
    /// Freezes the pages under the finger, for the length of a dismissal.
    ///
    /// ⚠️ A DISMISS GRAB AND THIS CAROUSEL WANT THE SAME DRAG. The grab is
    /// horizontal and so is this, and this scroll view is directly under the
    /// finger on any post whose media has more than one page — so a drag that
    /// begins a dismissal also pages the media, and the two share a gesture
    /// neither can finish. Filmed as the close tearing in half: the page frozen
    /// part-way across with the grid showing beside it, the percent driver
    /// having stopped receiving a gesture the scroll view had taken over.
    ///
    /// Deceleration is stopped as well as scrolling disabled: a carousel already
    /// gliding when the dismissal stages would otherwise coast through it and
    /// change the page under a flight that has already read which one it is.
    public func setScrollEnabled(_ enabled: Bool) {
        guard scrollView.isScrollEnabled != enabled else { return }
        if !enabled, scrollView.isDecelerating || scrollView.isDragging {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        scrollView.isScrollEnabled = enabled
    }

    /// Whether the carousel can still travel `delta` pages — see the note
    /// above `setScrollEnabled`, which is this method's.
    ///
    /// ⚠️ ON A CARD, FROM THE OFFSET — clamped to the run, which keeps the
    /// rubber-band answer above. Several items are on screen there and the
    /// current one may be any of them (a tap names it), so "is there a page
    /// past the current one" is not "can the strip move": a strip at its start
    /// with its second item current has nowhere to go back to, and a drag
    /// claimed for it would only rubber-band.
    public func hasTravel(towardsPageDelta delta: Int) -> Bool {
        guard delta != 0 else { return pageViews.count > 1 }
        if style == .card {
            guard pageViews.count > 1 else { return false }
            let range = offsetRange
            let offset = RowEdgeSnap.clamp(scrollView.contentOffset.x, to: range)
            return delta < 0
                ? offset > range.lowerBound + RowEdgeSnap.slack
                : offset < range.upperBound - RowEdgeSnap.slack
        }
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

    /// How a page frames its picture, given the picture's shape — nil, which
    /// is every `.card` carousel, fills every page exactly as carousels always
    /// have.
    ///
    /// ⚠️ PER PAGE, because a collection's pages need not agree about their
    /// shape: a 9:16 clip beside a 4:3 photograph fills on one page and fits on
    /// the next. Each page decides on the best shape it has — see
    /// `CarouselPageView.framingAspect` — and fills when it has none. Applied
    /// to the pages already built and to every page built after, so a host may
    /// set it at any time.
    public var pageFraming: ((CGSize) -> MediaFraming)? {
        didSet { pageViews.indices.forEach(applyFraming(onPage:)) }
    }

    /// The shape each page DECLARES, in page order, as the host knows it — nil
    /// entries for pages nobody vouches for.
    ///
    /// ⚠️ THE HOST'S, not `MediaPage.aspectRatio`: a head page's is the
    /// historical default of 1 whatever the picture is (see
    /// `FeedItemDisplayModel.headAspectRatio`), and a guessed square would
    /// frame a portrait clip as a square until its first frame.
    public func setDeclaredAspects(_ aspects: [CGSize?]) {
        for (index, view) in pageViews.enumerated() {
            view.declaredAspect = aspects.indices.contains(index) ? aspects[index] : nil
            applyFraming(onPage: index)
        }
    }

    /// Re-decides every page's framing — for a host that knows something a
    /// page cannot see for itself arrived (a clip's first frame, which is when
    /// its natural size is known).
    public func refreshFraming() {
        pageViews.indices.forEach(applyFraming(onPage:))
    }

    /// The framing the CURRENT page draws with — what a hero flying from or
    /// to this page must compose.
    public var currentPageFraming: MediaFraming {
        pageViews.indices.contains(currentPage) ? pageViews[currentPage].framing : .fill
    }

    /// The shape the current page's framing was decided on, nil when it had
    /// none (and so fills).
    public var currentPageAspect: CGSize? {
        pageViews.indices.contains(currentPage) ? pageViews[currentPage].framingAspect : nil
    }

    /// The backdrop the current page is drawing around its fitted picture, nil
    /// when it draws none (it fills, fits on black, or has no picture yet).
    public var currentPageBackdrop: UIImage? {
        pageViews.indices.contains(currentPage) ? pageViews[currentPage].backdropImage : nil
    }

    #if DEBUG
    /// Hands a page its picture the way the pipeline would, for a spec with no
    /// network — the same framing path the download takes.
    func debugSetCover(_ image: UIImage, onPage index: Int) {
        guard pageViews.indices.contains(index) else { return }
        pageViews[index].cover.image = image
        applyFraming(onPage: index)
    }
    #endif

    /// Re-decides one page's framing from what it has now.
    private func applyFraming(onPage index: Int) {
        guard pageViews.indices.contains(index) else { return }
        pageViews[index].applyFraming(rule: pageFraming)
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
    /// the PAGE, not the box: the box holds other items of the strip, so
    /// flying it would carry several images.
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
    /// The page loads still in flight, by page. An entry leaves when its load
    /// lands, so whatever is left here when the work is cancelled is exactly
    /// the pages that never got their picture (#779).
    private var loadTasks: [Int: Task<Void, Never>] = [:]
    private var pages: [GalleryPost.MediaPage] = []
    private var imagePipeline: ImagePipeline?
    /// Which pages have been asked for. A SET rather than a count, because the
    /// window moves in both directions and a page must never be fetched twice.
    ///
    /// ⚠️ A page whose load is CANCELLED leaves this set (`cancelPendingWork`),
    /// and so does one whose fetch FAILED.
    /// It used to stay: the page counted as fetched, the window skipped it, and
    /// a row recycled mid-load and dequeued again for the same post kept an
    /// empty fill for good (#779). Readable inside the package for that test.
    private(set) var loadedPages: Set<Int> = []
    private let style: Style

    public init(style: Style = .card, frame: CGRect = .zero) {
        self.style = style
        super.init(frame: frame)
        scrollView.carousel = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        // See the type note: paging by the box's width would be off by
        // whatever of a neighbour shows.
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
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
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
            // ground the strip rests on are the CARD, not a darker well. It is
            // what makes the items read as pictures lying on the card rather
            // than as frames cut into a panel.
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
        //
        // ⚠️ But it still asks for the window: a page whose load was cancelled
        // since (the row recycled, the card hidden) is no longer counted as
        // loaded, and this is the next time it is shown (#779). Pages that
        // already have their picture are skipped, so this costs nothing.
        guard pages != self.pages else {
            loadPagesAroundCurrent()
            return
        }
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
        pageViews.indices.forEach(applyFraming(onPage:))
        currentPage = 0
        focusFollowsOffset = true
        cardDrag = nil
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
    /// One neighbour each side, not two: the edge already shows part of the
    /// next page, so it must be loaded before it is looked at, and beyond that
    /// a page cannot be reached without a drag that gives the fetch its own
    /// time.
    ///
    /// ⚠️ ON A CARD, EVERY ITEM IN THE BOX AND ONE EACH SIDE OF IT. Several
    /// items are on screen there, and the current one need not be the first
    /// of them — a window around it alone left the cropped item at the edge
    /// an empty fill.
    private func loadPagesAroundCurrent() {
        guard let imagePipeline else { return }
        var window = Set((currentPage - 1)...(currentPage + 1))
        if style == .card, let shown = pagesInBox() {
            window.formUnion((shown.lowerBound - 1)...(shown.upperBound + 1))
        }
        for index in window.sorted() where pages.indices.contains(index) {
            guard !loadedPages.contains(index), let url = pages[index].thumbnailURL else { continue }
            loadedPages.insert(index)
            if let cached = imagePipeline.cachedImage(for: url) {
                pageViews[index].cover.image = cached
                // The picture's own pixels now decide its framing.
                applyFraming(onPage: index)
                continue
            }
            loadTasks[index] = Task { [weak self] in
                let image = try? await imagePipeline.image(for: url)
                // A cancelled load returns without touching `loadTasks`: the
                // cancel already retired its entry, and the slot may belong to
                // a newer load of the same page by now.
                guard !Task.isCancelled, let self else { return }
                self.loadTasks[index] = nil
                // ⚠️ A FAILED fetch is not a loaded page either: kept in the
                // set, it was never asked for again and stayed an empty fill.
                // Out of it, the next window that shows it retries.
                guard let image else {
                    self.loadedPages.remove(index)
                    return
                }
                guard self.pageViews.indices.contains(index) else { return }
                let page = self.pageViews[index]
                // The whole page dissolves, not only its cover: a fitted page
                // gains its backdrop in the same beat as its picture, and a
                // backdrop that cut in under a fading picture would flash.
                UIView.transition(
                    with: page.pictureLayers, duration: 0.25,
                    options: [.transitionCrossDissolve, .allowUserInteraction]
                ) {
                    page.cover.image = image
                    self.applyFraming(onPage: index)
                }
            }
        }
    }

    /// ⚠️ ON A CARD, THE TAPPED ITEM BECOMES THE CURRENT ONE FIRST.
    ///
    /// Several items are on screen, and whatever opens the post reads the
    /// current page (`PostGridListRowCell.currentMediaPage`) to open on it and
    /// flies the current page's rect (`currentPageRect`). Opening on "the
    /// current one" while the viewer pressed its neighbour would fly the wrong
    /// picture. An item the box crops first slides whole into the box — the
    /// rest a swipe would give it (`tapBringInDuration`) — so the flight
    /// departs from a whole picture rather than from a rect half outside it.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !isBringingIn else { return }
        if style == .card, let index = page(at: recognizer.location(in: scrollView)) {
            layoutIfNeeded()
            let target = offset(revealing: index)
            if abs(target - scrollView.contentOffset.x) > RowEdgeSnap.slack, Self.tapBringInDuration > 0 {
                bringIn(index, to: target)
                return
            }
            focus(on: index, animated: false)
        }
        onTapped?()
    }

    /// How long a cropped item takes to come whole before its post opens.
    ///
    /// ⚠️ SHORT AND ANIMATED, not a jump: snapped in place, the rest of the
    /// strip teleported by most of an item in the frame the flight took off,
    /// under a screen still visible around the flight. A tenth and a half is
    /// long enough to read as the strip sliding and short enough not to read
    /// as a wait — filmed against the jump on the simulator (2026-10-02), and
    /// the slide is the one that does not look like a glitch.
    static let tapBringInDuration: TimeInterval = 0.15

    /// True while a tapped item slides in, so a second tap cannot open the
    /// post twice.
    private var isBringingIn = false

    /// Slides a tapped cropped item whole into the box, then opens the post —
    /// the flight departs from where the item ARRIVED.
    private func bringIn(_ index: Int, to target: CGFloat) {
        isBringingIn = true
        focusFollowsOffset = false
        setCurrentPage(index)
        UIView.animate(
            withDuration: Self.tapBringInDuration, delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.scrollView.contentOffset.x = target
        } completion: { [weak self] _ in
            guard let self else { return }
            self.isBringingIn = false
            // The model value is already the target; reconciled once, so
            // marks and loads answer for where the strip came to rest.
            self.scrollViewDidScroll(self.scrollView)
            self.onTapped?()
        }
    }

    /// The item under a point of the scroll view's content, the gutter
    /// counting for the nearer item — nil when there are no items.
    func page(at point: CGPoint) -> Int? {
        guard !pageViews.isEmpty else { return nil }
        return pageViews.indices.min { lhs, rhs in
            distance(from: point.x, to: pageViews[lhs].frame) < distance(from: point.x, to: pageViews[rhs].frame)
        }
    }

    private func distance(from x: CGFloat, to frame: CGRect) -> CGFloat {
        x < frame.minX ? frame.minX - x : (x > frame.maxX ? x - frame.maxX : 0)
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
    /// neighbours with it, and the strip came back in a single frame at the
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

    /// Cancels the page loads still in flight, and forgets that those pages
    /// were asked for, so the next configure or scroll that shows them asks
    /// again (#779). Pages that already landed keep their picture.
    public func cancelPendingWork() {
        for (index, task) in loadTasks {
            task.cancel()
            loadedPages.remove(index)
        }
        loadTasks.removeAll()
    }

    // MARK: - Layout

    /// The stride between two page origins: the page plus its gutter.
    private var stride: CGFloat { pageWidth + gutter }
    /// A card's item (`cardPageWidth`), or the whole box on a page.
    private var pageWidth: CGFloat {
        switch style {
        case .card: Self.cardPageWidth(forBoxWidth: bounds.width, pageCount: pageViews.count)
        case .page: max(bounds.width, 1)
        }
    }
    /// Zero on a page: full-bleed media has no neighbour to show and no ground
    /// to show it on.
    private var gutter: CGFloat { style == .card ? Self.gap : 0 }

    /// Every offset the strip can rest at: from the first item flush left to
    /// the last one flush right.
    private var offsetRange: ClosedRange<CGFloat> {
        0...max(scrollView.contentSize.width - bounds.width, 0)
    }

    /// Each item's horizontal extent in content space, in page order — what
    /// the snap's anchors are read from.
    private var itemExtents: [ClosedRange<CGFloat>] {
        pageViews.map { $0.frame.minX...$0.frame.maxX }
    }

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
        // of all but the last plus one full PAGE — never a trailing gutter or
        // a box's worth of emptiness after the final photo.
        let content = CGFloat(pageViews.count - 1) * stride + pageWidth
        scrollView.contentSize = CGSize(width: content, height: bounds.height)
    }

    /// Where page `index` rests, clamped so the last one lands flush.
    /// The resting offset of a page, so a test can state its expectation in
    /// pages rather than in arithmetic it would have to duplicate.
    func debugOffset(forPage index: Int) -> CGFloat { offset(forPage: index) }

    /// A `.page` carousel's resting offset for `index`: its page's origin,
    /// clamped so the last one lands flush. A card has no single answer — see
    /// `offset(revealing:)`.
    private func offset(forPage index: Int) -> CGFloat {
        min(CGFloat(index) * stride, offsetRange.upperBound)
    }

    /// The nearest offset at which item `index` of a card's strip is WHOLE in
    /// the box: the current one when it already is, else the rest that brings
    /// it in from the side it is cut on — its trailing edge on the right edge
    /// when it lies right, its leading edge on the left when it lies left.
    /// The same two rests a swipe gives (`RowEdgeSnap`), so a strip moved by
    /// a host or a tap stands where a finger could have left it.
    func offset(revealing index: Int) -> CGFloat {
        let current = RowEdgeSnap.clamp(scrollView.contentOffset.x, to: offsetRange)
        guard pageViews.indices.contains(index) else { return current }
        let frame = pageViews[index].frame
        if frame.minX < current - RowEdgeSnap.slack {
            return RowEdgeSnap.clamp(frame.minX, to: offsetRange)
        }
        if frame.maxX > current + bounds.width + RowEdgeSnap.slack {
            return RowEdgeSnap.clamp(frame.maxX - bounds.width, to: offsetRange)
        }
        return current
    }

    /// The box's position in pages, fractionally — clamped to the run, because
    /// a rubber-banded overscroll is not a page and a strip drawn from it would
    /// stretch off its own end.
    ///
    /// On a card, the offset's PROGRESS through the run spread over the pages:
    /// zero at the first rest, the last page at the last — a strip ends with
    /// several items on screen, and a stride-based position would never reach
    /// the end of the run.
    public var scrollPosition: CGFloat {
        guard stride > 0, pageViews.count > 1 else { return 0 }
        if style == .card { return progress(atOffset: scrollView.contentOffset.x) }
        let raw = scrollView.contentOffset.x / stride
        return min(max(raw, 0), CGFloat(pageViews.count - 1))
    }

    /// `scrollPosition` for a card at a given offset.
    private func progress(atOffset offset: CGFloat) -> CGFloat {
        let range = offsetRange
        guard pageViews.count > 1, range.upperBound > 0 else { return 0 }
        let clamped = RowEdgeSnap.clamp(offset, to: range)
        return clamped / range.upperBound * CGFloat(pageViews.count - 1)
    }

    /// The card's current page at a given offset: the MOST VISIBLE item, and
    /// among items equally visible (at rest, every whole one) the one nearest
    /// the offset's progress through the run.
    ///
    /// Both halves are needed. Most-visible alone cannot tell two whole items
    /// apart, and picking the first of them would make the last page
    /// unreachable — at the end of the run the last two are both whole. The
    /// progress alone can name an item already half out of the box mid-run,
    /// which would play, and fly, a cropped picture.
    ///
    /// Clamped to the run, so a rubber-band answers for the end it is pulling.
    func focusPage(atOffset offset: CGFloat) -> Int {
        guard pageViews.count > 1 else { return 0 }
        let clamped = RowEdgeSnap.clamp(offset, to: offsetRange)
        let box = clamped...(clamped + bounds.width)
        let shown: [CGFloat] = pageViews.map { view in
            let frame = view.frame
            guard frame.width > 0 else { return 0 }
            let overlap = min(frame.maxX, box.upperBound) - max(frame.minX, box.lowerBound)
            return max(overlap, 0) / frame.width
        }
        let best = shown.max() ?? 0
        let progress = progress(atOffset: clamped)
        // A hundredth of an item of tolerance: "whole" is whole within a
        // fraction of a point, whatever the rounding of the item's width.
        return shown.indices
            .filter { shown[$0] >= best - 0.01 }
            .min { abs(CGFloat($0) - progress) < abs(CGFloat($1) - progress) } ?? 0
    }

    /// The items a card's box shows any part of, at the current offset.
    private func pagesInBox() -> ClosedRange<Int>? {
        let offset = scrollView.contentOffset.x
        let box = offset...(offset + bounds.width)
        let shown = pageViews.indices.filter { index in
            let frame = pageViews[index].frame
            return frame.maxX > box.lowerBound && frame.minX < box.upperBound
        }
        guard let first = shown.first, let last = shown.last else { return nil }
        return first...last
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

    /// A card's drag in progress: where it began and which way it last moved
    /// — what its release is read by (`RowEdgeSnap.steppedTarget`).
    private var cardDrag: RowEdgeDragTracker?

    /// Whether a card's current page follows the offset. True while the
    /// viewer moves the strip; false once a tap or a host has NAMED the page
    /// (`focus(on:animated:)`), so a strip that stays still keeps the page it
    /// was given rather than re-deciding it on the next layout tick — and an
    /// animated move to a named page does not wander through the pages it
    /// passes.
    private var focusFollowsOffset = true

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragAnchorPage = page(nearest: scrollView.contentOffset.x)
        if style == .card {
            cardDrag = RowEdgeDragTracker(offset: scrollView.contentOffset.x)
            focusFollowsOffset = true
        }
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        if style == .card {
            snapCard(scrollView, velocity: velocity.x, targetContentOffset: targetContentOffset)
            return
        }
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

    /// A card's strip comes to rest on an item's edge, the side picked by the
    /// gesture's direction, ONE ITEM PER GESTURE — `RowEdgeSnap.steppedTarget`.
    ///
    /// ⚠️ A RELEASE WITH NO SPEED IS ANIMATED BY HAND, as the rows do. Handed
    /// a new target with a zero velocity, UIScrollView jumps to it rather than
    /// gliding, so a slow drag lifted from a standstill would teleport the
    /// strip. There the strip is told to stay where it is and is then
    /// animated to the snap.
    private func snapCard(
        _ scrollView: UIScrollView, velocity: CGFloat,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let live = scrollView.contentOffset.x
        let drag = cardDrag
        cardDrag = nil
        let direction = RowEdgeSnap.direction(velocity: velocity, lastMovement: drag?.lastMovement)
        let target = RowEdgeSnap.steppedTarget(
            live: live,
            start: drag?.start ?? live,
            direction: direction,
            items: itemExtents,
            viewport: bounds.width,
            margin: 0,
            offsets: offsetRange
        )
        #if DEBUG
        if CarouselPlaybackAudit.isEnabled {
            CarouselPlaybackAudit.trace(
                String(format: "card snap start=%.1f live=%.1f -> %.1f v=%.2f",
                       drag?.start ?? live, live, target, velocity)
            )
        }
        #endif
        guard abs(velocity) < RowEdgeSnap.flickVelocity, offsetRange.contains(live),
              scrollView === self.scrollView else {
            // Moving — or pulled past an end, where UIKit's own spring back is
            // the motion wanted: the deceleration is bent onto the snap.
            targetContentOffset.pointee.x = target
            return
        }
        targetContentOffset.pointee.x = live
        guard target != live else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.scrollView.isTracking else { return }
            self.scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: true)
        }
    }

    /// Names a card's current page and brings it whole into the box —
    /// `offset(revealing:)`, which leaves a strip that already shows it whole
    /// exactly where it is.
    private func focus(on index: Int, animated: Bool) {
        guard pageViews.indices.contains(index) else { return }
        layoutIfNeeded()
        focusFollowsOffset = false
        let target = offset(revealing: index)
        if abs(target - scrollView.contentOffset.x) > RowEdgeSnap.slack {
            scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: animated)
        }
        if !animated { scrollViewDidScroll(scrollView) }
        setCurrentPage(index)
    }

    /// Moves to a page. Returns false when there is no such page — the answer a
    /// caller must not mistake for success.
    ///
    /// Public because the page indicator drives it: the dots are a CONTROL, not
    /// a readout, and a control that reported a page it could not reach would be
    /// worse than no control at all.
    ///
    /// On a card the page is NAMED rather than scrolled to: it becomes the
    /// current one, and the strip moves only as far as it takes to show it
    /// whole — not at all when it already is. A post opened on the second of
    /// two whole items, and closed on it, comes home to the strip exactly as
    /// it was left.
    @discardableResult
    public func setPage(_ index: Int, animated: Bool = true) -> Bool {
        guard pageViews.indices.contains(index) else { return false }
        if style == .card {
            focus(on: index, animated: animated)
            return true
        }
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
    ///
    /// A card's page follows it, as it would under a finger.
    func debugScroll(toOffsetX x: CGFloat) {
        focusFollowsOffset = true
        scrollView.contentOffset.x = x
        scrollViewDidScroll(scrollView)
    }

    /// Presses the card's item `index` the way a tap would, minus the touch.
    func debugTap(onPage index: Int) {
        guard pageViews.indices.contains(index) else { return }
        if style == .card { focus(on: index, animated: false) }
        onTapped?()
    }

    /// Every rest a card's strip can snap to — leading anchors, then trailing
    /// ones — so a test can name a rest without redoing the arithmetic.
    func debugAnchors() -> (leading: [CGFloat], trailing: [CGFloat]) {
        (
            RowEdgeSnap.leadingAnchors(items: itemExtents, margin: 0, offsets: offsetRange),
            RowEdgeSnap.trailingAnchors(
                items: itemExtents, viewport: bounds.width, margin: 0, offsets: offsetRange
            )
        )
    }

    /// The live offset, for a spec asserting where a move left the strip.
    var debugContentOffsetX: CGFloat { scrollView.contentOffset.x }
    #endif

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if style == .card, scrollView.isDragging {
            cardDrag?.track(scrollView.contentOffset.x)
        }
        // Before the page-change guard below: a mark's page can leave the box
        // without the RESOLVED page changing again (the drag that carries it
        // out is the same one that already changed it).
        retirePausedMarksOffScreen()
        onScrollPosition?(scrollPosition)
        if style == .card {
            // Items come into the box without the current page changing: the
            // one arriving at the edge must be fetched as it arrives.
            loadPagesAroundCurrent()
            guard focusFollowsOffset else { return }
            setCurrentPage(focusPage(atOffset: scrollView.contentOffset.x))
            return
        }
        setCurrentPage(page(nearest: scrollView.contentOffset.x))
    }

    /// Makes `page` the current one, and tells everyone who acts on it.
    private func setCurrentPage(_ page: Int) {
        guard page != currentPage else { return }
        currentPage = page
        applyPageConcealment()
        loadPagesAroundCurrent()
        onPageChanged?(page)
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
    /// `HorizontalPagerScrollView`'s own zone, which yields the same strip to
    /// the same gesture — and the snap feed's gate, which PERMITS the dismissal
    /// there.
    ///
    /// ⚠️ It said "matched" over a literal 20 while the gate read 28: a drag
    /// born 20–28pt in was the dismissal's by the gate and the carousel's by
    /// this, both recognizers ran, and the window left with the carousel
    /// half-paged under it. One definition, `PagedScreenDismissalPolicy.edgeZone`.
    private static var backEdgeZone: CGFloat { PagedScreenDismissalPolicy.edgeZone }

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

    /// The page's still layers — backdrop, then cover — in one container, so
    /// the arrival of a picture dissolves both as one (`MediaCarouselView
    /// .loadPagesAroundCurrent`) and nothing hosted above them is caught in
    /// the transition.
    let pictureLayers = UIView()
    /// The blurred copy of the picture a `.fitBlurred` page draws around it.
    /// Hidden for every other framing, and on every `.card` carousel.
    private let backdrop = UIImageView()

    /// How this page draws its picture. `.fill` until a host asks otherwise.
    private(set) var framing: MediaFraming = .fill
    /// The shape the host declares for this page (`MediaCarouselView
    /// .setDeclaredAspects`), nil when nobody vouches for one.
    var declaredAspect: CGSize?

    /// The shape this page frames by: what is DRAWN when it can say, else
    /// what was declared, else nothing (and the page fills).
    ///
    /// ⚠️ A CLIP'S COVER IS NOT ITS SHAPE. On a playable page the cover is the
    /// clip's poster, a thumbnail, and thumbnails are routinely cropped — the
    /// mock corpus serves 168×168 squares for 9:16 clips, which framed a
    /// portrait clip as a blurred square. A clip page trusts only its surface's
    /// natural size and the declared shape; a photo page's cover IS the photo.
    var framingAspect: CGSize? {
        func valid(_ size: CGSize?) -> CGSize? {
            guard let size, size.width > 0, size.height > 0 else { return nil }
            return size
        }
        if isPlayable {
            return valid((hostedSurface as? VideoRenderView)?.nativeVideoSize) ?? declaredAspect
        }
        return valid(cover.image?.size) ?? declaredAspect
    }
    /// The backdrop being drawn, nil when there is none.
    var backdropImage: UIImage? { backdrop.isHidden ? nil : backdrop.image }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        pictureLayers.isUserInteractionEnabled = false
        addSubview(pictureLayers)
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        backdrop.isHidden = true
        pictureLayers.addSubview(backdrop)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        pictureLayers.addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Decides and draws this page's framing from `framingAspect` — `.fill`
    /// without one, and always with a nil rule, which is what a page did
    /// before framing existed.
    func applyFraming(rule: ((CGSize) -> MediaFraming)?) {
        framing = rule.flatMap { rule in framingAspect.map(rule) } ?? .fill
        layoutCover()
        if framing == .fitBlurred, let image = cover.image {
            backdrop.image = MediaBackdrop.blurred(image)
            backdrop.isHidden = false
        } else {
            backdrop.image = nil
            backdrop.isHidden = true
        }
        // The page's surface draws the way the page does. A surface handed
        // back to a GRID leaves at fill (`SnapFeedCell.donateLiveRenderView`).
        if let surface = hostedSurface as? VideoRenderView {
            applyFraming(toSurface: surface)
        }
    }

    /// The surface whose opaque ground this page switched off, if any.
    private weak var groundClearedSurface: VideoRenderView?

    /// Gravity, and the ground under a fitted clip: a surface paints an
    /// opaque black ground (`VideoRenderView.paintsOpaqueGround`) that would
    /// cover this page's backdrop in the bands. Switched back on only on a
    /// surface this page switched off — `SnapMediaCardView.applyGround` states
    /// the same rule for a single picture.
    private func applyFraming(toSurface surface: VideoRenderView) {
        surface.videoGravity = framing.videoGravity
        // Its poster framed to the clip's rect, as this page's cover is.
        surface.posterAspect = framing.fits ? framingAspect : nil
        if framing.fits {
            surface.paintsOpaqueGround = false
            groundClearedSurface = surface
        } else if groundClearedSurface === surface {
            surface.paintsOpaqueGround = true
            groundClearedSurface = nil
        }
    }

    /// The cover's place: the whole page when it fills; when it fits, the
    /// rect of the picture's shape inside the page, FILLED.
    ///
    /// ⚠️ FILLED, not fitted on its own shape, because on a clip page the
    /// cover is the POSTER and a poster may be a cropped thumbnail — fitted on
    /// its own square it sat inset inside the clip's rect and the clip then
    /// jumped out to its real size on its first frame. For a photo the rect IS
    /// the cover's own shape (`framingAspect`), so filling it is the fit.
    private func layoutCover() {
        let area = pictureLayers.bounds
        if framing.fits, let aspect = framingAspect, area.width > 0, area.height > 0 {
            cover.frame = MediaFraming.fittedRect(aspect: aspect, in: area)
            cover.contentMode = .scaleAspectFill
        } else {
            cover.frame = area
            cover.contentMode = framing.contentMode
        }
    }

    /// Frames, not constraints — the carousel lays its pages out by frame on
    /// every width change, and a page that mixed the two would fight it.
    override func layoutSubviews() {
        super.layoutSubviews()
        pictureLayers.frame = bounds
        backdrop.frame = pictureLayers.bounds
        layoutCover()
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
        // Whatever surface arrives — minted by the host, adopted from a flight,
        // reclaimed from a cancelled grab — draws the way this page draws.
        if let video = surface as? VideoRenderView { applyFraming(toSurface: video) }
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
        // It leaves as it came: whoever hosts it next — another page, a
        // flight, a grid — decides its ground for itself.
        if let video = surface as? VideoRenderView, groundClearedSurface === video {
            video.paintsOpaqueGround = true
            video.posterAspect = nil
            groundClearedSurface = nil
        }
        return surface
    }
}
