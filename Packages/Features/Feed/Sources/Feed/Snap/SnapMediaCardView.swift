import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The post's media surface: an image view for photos and a
/// `VideoRenderView` for videos, hosted full-bleed as one standalone piece.
/// Playback is never re-hosted here — its clock and ownership are the
/// caller's, driven into `renderView`.
///
/// The surfaces are FULL-BLEED IN BOTH STATES, at identity, with square
/// corners. Engaging the comments layers a readability treatment and the
/// stream OVER this view; it does not move, scale, crop, round, or stop.
/// (A slight scale-down and a screen-concentric corner rounding rode the
/// engagement for a while, meant to read as the post stepping back. At a
/// 6pt pullback it read as a phantom layer sliding under the content
/// instead, so the engagement now touches this view's geometry not at all.)
///
/// (It used to dock into an 88pt tile — a uniform
/// transform plus an animated center-crop mask, plus its own glass card.
/// That machinery is gone with the tile, and so is the doctrine it forced:
/// while the engagement owned the media's transform, every path that reset
/// that transform had to branch on `isCommentsEngaged`, and the ones that
/// forgot produced a frozen full-bleed center crop that nothing could heal.
/// Identity throughout means there is no state to strand.)
///
/// The card owns the surfaces' MOTION (the Ken Burns drift); the cell
/// orchestrates WHEN — playback activation, the drift's active/engaged
/// gating — since those are lifecycle decisions the surface can't see.
/// Text-only posts leave both surfaces hidden.
final class SnapMediaCardView: UIView {
    /// The photo surface (also the Ken Burns drift target). Exposed so the
    /// cell can load an image into it; the card owns its transform.
    let imageView = UIImageView()
    /// The video playback surface — the caller drives its external
    /// `VideoPlaybackController` into this (playback ownership stays out
    /// of the card by construction).
    private(set) var renderView: VideoRenderView = {
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "feed"
        #endif
        return view
    }()

    init() {
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: self)
        renderView.pin(to: self)
        // Last, so it starts above both pictures — and hidden, so it costs a
        // laid-out view and nothing else until a viewer stops something.
        singleMark.pin(to: self)
    }

    /// Re-installs the video surface after a hero flight borrowed it.
    ///
    /// Removing the view drops its pinning constraints with it, so the restore
    /// has to re-pin rather than just re-add. Ordering matters as much: it goes
    /// back above the photo surface, where it started.
    func restoreRenderView(_ view: VideoRenderView) {
        // ⚠️ A COLLECTION's surface belongs to a PAGE, and this is the landing
        // path — the point where a flight hands its live layer back. Re-pinning
        // it to the card would put a full-bleed video over the carousel, which
        // is right for a single attachment and wrong for every page of a
        // collection but the one being watched.
        if showsCollection {
            if view !== renderView {
                renderView.detachForReplacement()
                renderView.removeFromSuperview()
                renderView = view
            }
            view.transform = .identity
            // ⚠️ The adopted view IS this page's surface from here on.
            //
            // Without this the page kept pointing at the surface the landing
            // just replaced, so the next page change hosted a dead view and
            // re-minted one for the page the viewer was already watching — two
            // surfaces for one clip, and the live layer among the discarded.
            pageSurfaces[currentPage] = view
            hostRenderViewOnCurrentPage()
            hostRetainedSurfaces()
            return
        }
        guard view.superview !== self else { return }
        // A LANDING hands over the other side's surface, not the one this card
        // started with — the view travels tile -> flight card -> page (and back
        // on a dismissal) so the layer is never re-created. Adopt it as this
        // card's own and drop the surface it replaces.
        if view !== renderView {
            renderView.detachForReplacement()
            renderView.removeFromSuperview()
            renderView = view
        }
        view.transform = .identity
        // Installed by FRAME, not by constraints, and that is the whole fix for
        // the landing flash. `pin(to:)` sets
        // `translatesAutoresizingMaskIntoConstraints = false`, which discards
        // the view's concrete frame until the next layout pass; the transient
        // bounds reset `AVPlayerLayer.isReadyForDisplay` to false for ~170ms,
        // measured, exactly on the completion frame. The takeoff path installs
        // by frame and never resets — this now matches it.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(view, aboveSubview: imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card is HIT-TRANSPARENT except where its surfaces actually are.
    /// It hosts the surfaces full-bleed, so without this its own frame
    /// would eat every touch on the cell. Returning nil for a self-hit
    /// makes only the surfaces hittable. (Still load-bearing after the
    /// dock's removal, for a new reason: the card now sits BENEATH the
    /// engaged stream rather than above it, and a full-bleed view that
    /// answers every point would still claim the background taps the
    /// chrome's own canvas rule is there to release.)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: - Content

    /// Selects the surface for the post's kind and clears any prior frame.
    func configure(kind: MediaKind) {
        imageView.isHidden = kind != .image
        renderView.isHidden = kind != .video
        imageView.image = nil
        imageView.transform = .identity
        renderView.setPoster(nil)
        logMediaState("configure(kind: \(kind))")
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        logMediaState(image == nil ? "setImage(nil)" : "setImage(image)")
    }

    // MARK: - The wait

    /// Says the page is waiting for its media.
    ///
    /// A thumbnail that is still loading and a thumbnail that IS the post look
    /// exactly alike, and a clip's poster looks like a photograph — so a page
    /// mid-fetch was indistinguishable from a page that had arrived. This is
    /// the difference, and it sits over the media area rather than over the
    /// chrome: it belongs to the picture that is missing.
    private lazy var spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        // ⚠️ WHITE, not `.label`. The ground here is the post's photograph or
        // black — never the page's theme — so a semantic colour would resolve
        // against a background this view does not have. White is what every
        // other overlay on this surface uses, for the same reason.
        view.color = .white
        view.hidesWhenStopped = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: 24),
            view.heightAnchor.constraint(equalToConstant: 24)
        ])
        return view
    }()

    /// Whether the spinner is up. Built lazily, so asking before anything ever
    /// waited must not create it.
    private var isSpinning = false

    /// Which PAGE of a collection is announcing a wait, when one is.
    ///
    /// ⚠️ THE WAIT BELONGS TO A MEDIA, NOT TO THE POST — the same rule the
    /// stopped mark already follows, and the play/pause glyph with it. Centred
    /// on the card, the spinner stayed put while the pictures moved under it:
    /// swiping off a page that was still loading left its announcement hanging
    /// over the picture that had already arrived, which says the opposite of
    /// the truth on both pages at once. On the page, it scrolls away with the
    /// media it is about.
    ///
    /// A single photograph or clip has no pages to belong to, so that case
    /// keeps the card's own spinner and `isSpinning` answers for it.
    private var loadingPage: Int?

    func setLoading(_ loading: Bool) {
        if showsCollection {
            setCollectionLoading(loading)
            return
        }
        guard loading != isSpinning else { return }
        isSpinning = loading
        if loading {
            // ⚠️ ABOVE EVERYTHING, and re-stated on every show: the carousel is
            // inserted over `imageView` after this view is built, so a spinner
            // added once would sit UNDER a collection's pages.
            bringSubviewToFront(spinner)
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        logMediaState(loading ? "setLoading(true)" : "setLoading(false)")
    }

    /// The wait on a collection, which is a wait on ONE of its pages.
    ///
    /// ⚠️ THE OLD PAGE'S SPINNER COMES DOWN when the wait moves. The host
    /// decides this for the page in front of the viewer and for no other, so a
    /// spinner left on a page nobody is deciding for is bookkeeping that
    /// outlives its subject — the fault `retirePausedMarksOffScreen` is written
    /// against, one file over. Riding out of the box is right; staying lit out
    /// there is not.
    private func setCollectionLoading(_ loading: Bool) {
        let page = currentPage
        guard loadingPage != (loading ? page : nil) else { return }
        if let previous = loadingPage, previous != page || !loading {
            carousel?.setLoading(false, onPage: previous)
        }
        loadingPage = loading ? page : nil
        if loading { carousel?.setLoading(true, onPage: page) }
        logMediaState(loading ? "setLoading(true, page: \(page))" : "setLoading(false)")
    }

    /// Read by `SnapMediaLoaderSpecTests`.
    var isShowingLoader: Bool { showsCollection ? loadingPage != nil : isSpinning }

    #if DEBUG
    /// WHERE the wait is drawn — the view itself, so a spec can prove it rides
    /// its page rather than the card.
    func visibleLoader(onPage page: Int) -> UIView? {
        showsCollection
            ? carousel?.visibleLoader(onPage: page)
            : (isSpinning ? spinner : nil)
    }
    #endif

    // MARK: - Collections

    /// Fired continuously as a collection scrolls, in fractional pages — what
    /// the page strip draws from. See `MediaCarouselView.onScrollPosition`.
    var onScrollPosition: ((CGFloat) -> Void)?

    /// Fired as the viewer pages a collection, so the chrome can move its
    /// indicator. The card knows where the pages are; it does not know where the
    /// indicator lives.
    var onPageChanged: ((Int) -> Void)?

    /// Shows a collection's pages instead of the single photo surface.
    ///
    /// `.page` style: full-bleed, no peek. The card's carousel peeks because
    /// nothing else on a card says a post has more than one photograph; here the
    /// screen IS the photograph, a stripe of the next one down the side would be
    /// a defect, and the indicator over the comment band carries the message.
    ///
    /// The photo surface is hidden rather than removed. It is the Ken Burns
    /// drift target and the hero landing's surface, and both of those reach for
    /// it by identity — a collection is a different presentation of the media,
    /// not a different card.
    func showCollection(_ pages: [GalleryPost.MediaPage], imagePipeline: ImagePipeline) {
        let carousel = carousel ?? makeCarousel()
        carousel.isHidden = false
        carousel.configure(with: pages, imagePipeline: imagePipeline)
        // A recycled carousel keeps whatever the last post left lit, and these
        // are different pictures entirely.
        carousel.clearLoaders()
        loadingPage = nil
        imageView.isHidden = true
        renderView.isHidden = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-carousel-audit") {
            print("[audit] hide by showCollection")
        }
        #endif
    }

    /// Back to a single surface. Called for every non-collection post, because a
    /// recycled cell keeps whatever the last one built.
    func hideCollection() {
        carousel?.isHidden = true
        carousel?.cancelPendingWork()
        // The wait belonged to a page, and there are no pages now.
        carousel?.clearLoaders()
        loadingPage = nil
        // Every page's claim on a surface ends with the collection. The players
        // behind them are the caller's to stop — see the call site, which
        // releases and stops before asking for this.
        pageSurfaces.removeAll()
        // ⚠️ And the card takes its own surface back.
        //
        // After a collection, `renderView` is whichever page the viewer stopped
        // on, hanging inside a carousel that is now hidden. A single-attachment
        // post rebound into this cell would draw into a view nobody can see —
        // the surface is pinned to the card at `init` and only a hero landing
        // ever re-pins it, so nothing else would have put it back.
        if renderView.superview !== self {
            renderView.removeFromSuperview()
            renderView.pin(to: self)
        }
    }

    /// The stopped mark for a SINGLE attachment — one picture, one mark.
    ///
    /// A collection's marks live on its pages (`MediaCarouselView`), because
    /// there the mark has to travel with the picture it belongs to. Here the
    /// picture is the card, so the card holds it.
    /// ⚠️ Built with the card, not on first use. A mark minted at the moment
    /// of the tap has no frame until the next layout pass, so it crossfades in
    /// at zero size and jumps — a first-appearance-only defect, which is the
    /// kind a spec catches once and a viewer meets every time.
    private let singleMark = PausedClipMarkView()

    /// Shows or hides the mark on the picture the viewer is looking at.
    func setPausedMark(_ visible: Bool) {
        if showsCollection {
            carousel?.setPausedMark(visible, onPage: currentPage)
        } else {
            if visible { bringSubviewToFront(singleMark) }
            singleMark.setVisible(visible)
        }
    }

    /// Whether the picture in front of the viewer wears the mark.
    var showsPausedMark: Bool { visiblePausedMark != nil }

    /// The mark being drawn on the current picture, if any.
    var visiblePausedMark: UIView? {
        showsCollection
            ? carousel?.visiblePausedMark(onPage: currentPage)
            : (singleMark.isShowing ? singleMark : nil)
    }

    /// The mark a given PAGE is wearing, whether or not the viewer is on it —
    /// the question a spec asks to prove the mark stayed with its page.
    func visiblePausedMark(onPage page: Int) -> UIView? {
        showsCollection ? carousel?.visiblePausedMark(onPage: page) : visiblePausedMark
    }

    /// Takes every mark down — the post's pictures are all playing, or the card
    /// is being handed a different post entirely.
    func clearPausedMarks() {
        singleMark.setVisible(false, animated: false)
        for page in 0..<max(0, pageCount) {
            carousel?.setPausedMark(false, onPage: page)
        }
    }

    /// Which page a collection is showing, for a hero flight and for the chrome
    /// to re-assert after a rebind.
    var currentPage: Int { carousel?.currentPage ?? 0 }

    /// Whether a collection is what this card is drawing.
    var showsCollection: Bool { !(carousel?.isHidden ?? true) }

    /// The picture the current page is showing — a page's cover, which for a
    /// clip is its poster.
    ///
    /// Handed to the playback surface before a play so the surface has
    /// something to show while the stream buffers. See the caller: an EMPTY
    /// poster is what makes `play` hide the surface on its way through.
    var currentPageCover: UIImage? { carousel?.renderedCover }

    /// The still this card is drawing, WHICHEVER layout it is in.
    ///
    /// Deliberately not folded into `currentPageCover` above, whose nil for a
    /// single-media post is load-bearing: its caller hands the result to a
    /// playback surface as a poster, and an empty poster is what makes `play`
    /// hide the surface on its way through. This is the other question — "what
    /// picture is on screen" — asked by a presenter's flight home, which has to
    /// dissolve that picture away when it is landing somewhere else.
    ///
    /// ⚠️ A VIDEO PAGE ANSWERS THIS, and the reason it once did not was never
    /// about video.
    ///
    /// `configure(kind:)` empties this image view for `.video` and routes the
    /// poster to the surface instead, so the single-attachment branch below
    /// returned nil — not because a player's frames are unreachable, but
    /// because the picture had moved to the one place this was not looking.
    /// A video page inside a CAROUSEL never had the gap, which is what gave it
    /// away.
    ///
    /// So the surface is asked too: `currentStill` is the decoded frame it is
    /// showing, or the poster it is showing before one arrives. A page that
    /// dismisses toward a marker now carries the picture the viewer was
    /// actually looking at, instead of leaving the window to clip the live page.
    ///
    /// Still nil for a TEXT page, which has no picture of any kind — that nil
    /// is meaningful and every caller is written around it.
    var renderedStill: UIImage? {
        if showsCollection { return carousel?.renderedCover }
        return imageView.image ?? renderView.currentStill
    }

    /// The stream the current PAGE carries, nil when it is a still or when this
    /// card is not drawing a collection at all.
    var currentPageVideoURL: URL? {
        showsCollection ? carousel?.currentPageVideoURL : nil
    }

    /// How many pages the collection has.
    var pageCount: Int { showsCollection ? (carousel?.pageCount ?? 0) : 0 }

    /// Readies a surface for a page the viewer is not on: minted, given THAT
    /// page's cover to show while the stream fills, and hung on the page.
    ///
    /// The poster is the load-bearing part. A surface hosted with none is a
    /// black rectangle over the photograph until the first frame lands, which
    /// is a worse defect than the delay this exists to remove.
    func prepareSurface(forPage page: Int) -> VideoRenderView {
        let view = surface(forPage: page)
        view.setPoster(carousel?.cover(onPage: page))
        view.translatesAutoresizingMaskIntoConstraints = true
        view.isHidden = false
        carousel?.host(view, onPage: page)
        return view
    }

    /// The pages carrying a stream — the retention window's domain.
    var videoPageIndices: [Int] {
        showsCollection ? (carousel?.videoPageIndices ?? []) : []
    }

    /// The stream on a given page, for a caller reconciling a retained clip
    /// against what its surface is actually holding.
    func videoURL(onPage page: Int) -> URL? { carousel?.videoURL(onPage: page) }

    /// Moves the playback surface onto the page the viewer is looking at.
    ///
    /// ⚠️ `renderView` is THE WATCHED PAGE'S surface, and everything that makes
    /// a hero flight carry live video works by identity on it: the flight
    /// attaches a sibling alongside it, a dismissal donates it, a landing adopts
    /// it, a cancelled grab reclaims it. That is why the retained neighbours are
    /// separate objects that never fly — the flying one is only ever the one
    /// under the viewer, and it is re-pointed between page changes rather than
    /// re-parented from page to page.
    func hostRenderViewOnCurrentPage() {
        guard let carousel, !carousel.isHidden else { return }
        renderView = surface(forPage: currentPage)
        renderView.translatesAutoresizingMaskIntoConstraints = true
        renderView.isHidden = false
        carousel.host(renderView, onPage: currentPage)
    }

    // MARK: - Retained clips

    /// A surface for every clip this card is keeping warm, keyed by page.
    ///
    /// ⚠️ ONE PER PAGE, and that is the whole of the frozen-frame behaviour. A
    /// single surface walked from page to page means the page it leaves falls
    /// back to its poster — the cut reported as "the thumbnail comes back". A
    /// page that keeps its own surface keeps its last decoded frame and its
    /// playhead, so coming back is free and looks like nothing happened.
    ///
    /// Bounded by `CarouselRetentionWindow`, never by the size of the gallery.
    private var pageSurfaces: [Int: VideoRenderView] = [:]

    /// The surface for a page, minted on first use.
    func surface(forPage page: Int) -> VideoRenderView {
        if let existing = pageSurfaces[page] { return existing }
        // The first page to ask inherits the card's OWN surface rather than
        // minting a second one: a single-attachment post and a collection whose
        // page is a clip are the same picture, and a landing that adopted the
        // card's view before the carousel existed must still find it.
        //
        // The condition is "is the card's surface still unclaimed", not "is
        // this page zero" — after the window drops a page and the viewer
        // returns to it, page identity says nothing about who holds what.
        let claimed = pageSurfaces.values.contains { $0 === renderView }
        let view = claimed ? VideoRenderView() : renderView
        #if DEBUG
        view.debugLabel = "feed-p\(page)"
        #endif
        pageSurfaces[page] = view
        return view
    }

    /// The pages currently holding a surface.
    var surfacedPages: [Int] { pageSurfaces.keys.sorted() }

    /// Keeps the named pages' surfaces and gives up every other, reporting the
    /// ones dropped so the caller can end their playback.
    ///
    /// ⚠️ The card does not stop players — it does not own the pool. It reports
    /// what it let go of and the cell ends those, which is the same division
    /// that keeps playback ownership out of this file by construction.
    /// - Parameter sparing: a surface to keep whatever the window says, or nil.
    ///
    ///   ⚠️ EXPLICIT, because as an implicit rule it was an off-by-one. This
    ///   used to spare `renderView` unconditionally — but the window is applied
    ///   before `renderView` is re-pointed, so what it actually spared was the
    ///   page the viewer had just LEFT. One clip beyond the budget survived
    ///   every page change, and the bound the whole design rests on was not a
    ///   bound. Caught by restoring the regression, not by reading the code:
    ///   the falsifying run reported two players where the disabled window
    ///   should have allowed one.
    @discardableResult
    func retainSurfaces(onPages pages: [Int],
                        sparing: VideoRenderView? = nil) -> [VideoRenderView] {
        let kept = Set(pages)
        var dropped: [VideoRenderView] = []
        for (page, view) in pageSurfaces where !kept.contains(page) {
            guard view !== sparing else { continue }
            carousel?.evictSurface(onPage: page)
            view.removeFromSuperview()
            pageSurfaces[page] = nil
            dropped.append(view)
        }
        return dropped
    }

    /// Hangs every retained clip on its own page, so a neighbour holds its
    /// frozen frame instead of its poster while the viewer is elsewhere.
    func hostRetainedSurfaces() {
        guard let carousel, !carousel.isHidden else { return }
        for (page, view) in pageSurfaces {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.isHidden = false
            carousel.host(view, onPage: page)
        }
    }

    /// Gives up every retained surface but the watched one — a full teardown,
    /// for reuse and for the end of playback.
    ///
    /// ⚠️ The watched one is SPARED here on purpose. It is the surface a
    /// single-attachment post draws on, pinned to the card since `init`; taking
    /// it away would leave the next video post with nowhere to draw, and only
    /// a landing ever puts it back. Its player is stopped by the caller, which
    /// is the part that actually has to happen.
    @discardableResult
    func releaseRetainedSurfaces() -> [VideoRenderView] {
        retainSurfaces(onPages: [], sparing: renderView)
    }

    /// Whether the surface is already hanging in the page being looked at.
    var hostsRenderViewOnCurrentPage: Bool {
        carousel?.hostsSurfaceOnCurrentPage(renderView) ?? false
    }

    /// Takes the surface off whatever page holds it and hides it.
    ///
    /// ⚠️ Used when playback genuinely ENDS, not when the viewer pages away — a
    /// clip left on its own page keeps its last frame, and taking the surface
    /// off puts the page's thumbnail back.
    func releaseRenderViewFromPages() {
        carousel?.evictHostedSurface()
        renderView.isHidden = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-carousel-audit") {
            print("[audit] hide by releaseRenderViewFromPages")
        }
        #endif
    }

    /// Moves to a page, when the indicator asks. A no-op for a post with no
    /// collection, which is the honest answer rather than a crash.
    func setPage(_ index: Int, animated: Bool = true) {
        #if DEBUG
        debugPageRequests.append((page: index, animated: animated))
        #endif
        carousel?.setPage(index, animated: animated)
    }

    #if DEBUG
    /// The last page instruction and how it was to be MADE.
    ///
    /// ⚠️ The decision, not the motion, and the difference is not a shortcut: a
    /// scroll view with no window applies an animated offset immediately, so a
    /// spec that watched the pages would find a turn and a jump identical and
    /// pass whichever rule it was given. What is worth pinning here is the
    /// choice the cell makes; the easing is UIKit's.
    private(set) var debugPageRequests: [(page: Int, animated: Bool)] = []

    func debugClearPageRequests() { debugPageRequests = [] }
    #endif

    private func makeCarousel() -> MediaCarouselView {
        let view = MediaCarouselView(style: .page)
        view.onPageChanged = { [weak self] page in self?.onPageChanged?(page) }
        view.onScrollPosition = { [weak self] position in self?.onScrollPosition?(position) }
        // Below nothing — it is the media, and everything else on the page is
        // layered over the card by the cell.
        insertSubview(view, aboveSubview: imageView)
        view.pin(to: self)
        carousel = view
        return view
    }

    private var carousel: MediaCarouselView?

    func setPoster(_ image: UIImage?) {
        renderView.setPoster(image)
        logMediaState(image == nil ? "setPoster(nil)" : "setPoster(image)")
    }

    /// Traces every mutation of the media area under `-media-log`.
    ///
    /// A black media area is always some combination of: the image view empty
    /// or hidden, the render surface hidden, its poster cleared, its layer
    /// flushed. Reasoning about which from the code has now been wrong three
    /// times in a row on this issue, so this prints the whole state on every
    /// change and lets the sequence say what happened. The gap to look for is a
    /// long interval between a clearing call and the call that refills it.
    private func logMediaState(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-media-log") else { return }
        print(String(format: "[media] %.3f %-22@ image=%@ imageHidden=%@ | render %@",
                     CACurrentMediaTime(), event,
                     imageView.image == nil ? "nil" : "set",
                     imageView.isHidden ? "Y" : "N",
                     renderView.debugSurfaceState))
        #endif
    }
    /// Whether the photo surface has something on screen — the landing
    /// trace's readiness signal for an image page.
    /// Whether the media area has real pixels on screen — the signal the hero
    /// landing waits on before revealing the page and unmounting the flight
    /// card.
    ///
    /// ⚠️ A COLLECTION answers from the carousel, and forgetting that is the
    /// most expensive line of the whole feature.
    ///
    /// `showCollection` hides `imageView` and never fills it, so the original
    /// `image != nil && !isHidden` was permanently FALSE for every collection.
    /// The landing has a timeout behind that check, so it fired instead: the
    /// flight card stayed on screen for about three seconds, and the page —
    /// with its comment ticker and its page indicator — appeared only when the
    /// wait gave up. Measured headless at 3.2s, and reported as "a huge delay
    /// before the post is fully operational, the comments and the indicator
    /// arrive well after".
    ///
    /// Nothing was late. Everything was built on time behind a view held at
    /// alpha zero, which is why the two arrived together and why the chip's own
    /// log showed it configured, unhidden and materialized 1.5s BEFORE the page
    /// was visible. A readiness signal that a new presentation silently fails
    /// does not report a problem; it waits.
    var isImageReady: Bool {
        if let carousel, !carousel.isHidden { return carousel.renderedCover != nil }
        return imageView.image != nil && !imageView.isHidden
    }

    // MARK: - No transform. Ever.
    //
    // THE MEDIA IS STATIC, at `.identity`, for the whole life of the cell.
    // A Ken Burns drift used to live here — an 8s linear zoom to 1.12× on
    // the photo, started on activation — and it was the last thing scaling
    // this surface. It came from Phase 1, as visible proof that the
    // activation seam fired at all, back when video could not yet play; the
    // player has made that point for a long time now.
    //
    // What it cost was the engagement's transition. The comments have to
    // read over a STILL background, so engaging had to stop the drift — a
    // snap back from wherever the zoom had reached — and disengaging
    // restarted it, which began an 8s zoom inside the transition's own
    // animation block. From the reader's side that is the media scaling as
    // the comments open and close: not a designed motion, a side effect of
    // one state having to undo another's transform.
    //
    // Nothing sets a transform on these surfaces now, so there is no state
    // to reset, nothing to gate on `isCommentsEngaged`, and no path that
    // can strand a scale. The two `.identity` assignments at build time are
    // the whole story.
}
