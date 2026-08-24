import DesignSystem
import MediaCore
import MediaPlayback
import UIKit

// MARK: - Timeline row

/// One full-width row of the Activity/Short timelines: the caption with
/// reading padding on a soft card, plus — when the post carries media — a
/// rounded full-width preview under the text (play badge for videos). Short
/// pages never have media, so their rows are text + metadata.
///
/// ## Where the metadata sits
///
/// Views, reactions, comments and the post's compact age, and there are two
/// placements because there are two shapes of card:
///
/// * **Text row** — a quiet line closing the card, counters leading and the age
///   trailing, `.secondaryLabel` against the card's own fill.
/// * **Media row** — the same four values ON the preview, as two material chips
///   resting on its bottom edge (counters leading, age trailing). The card then
///   ENDS at the preview, so the line below it is gone rather than duplicated.
///
/// The second is not decoration. A card with a preview closed on a strip of
/// card-coloured furniture below the image, which is the widest thing on the
/// row and the least worth reading; moving it onto the media buys back roughly
/// 28pt per media row and lets the preview finish the card. See
/// `PostMetaPillView` for the ground the pills stand on, and `contentInset` for
/// why the preview's edges fall on the caption's.
public final class PostGridListRowCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    public static let reuseID = "PostGridListRowCell"
    /// The inner preview's rounding — the radius a hero flying from this row
    /// must start at, so the card is the preview's twin rather than its
    /// approximation.
    ///
    /// CONCENTRIC with the card: its radius carried inward by the preview's own
    /// inset, so the two curves stay parallel the whole way round.
    ///
    /// This is the arithmetic `UICornerRadius.containerConcentric` performs,
    /// written out rather than delegated — the hero reads a NUMBER to open a
    /// flight at, and a corner configuration resolved at layout time is not
    /// something a transition can ask for up front.
    ///
    /// Derived, never restated, for the same reason: a literal here would put a
    /// flight's first frame at a curve the row it left has not had for some
    /// time.
    public static var mediaCornerRadius: CGFloat { cardCornerRadius - mediaInset }

    /// Where the page STOPS MATCHING this card, in the card's own space — the
    /// reveal's cut line. Below it the destination is veiled for the length of
    /// a flight, so the window shows no more of itself than the card does.
    ///
    /// ## Two answers, one rule
    ///
    /// The rule is not about truncation, though it was written as if it were.
    /// A card shows a caption and a metric line; the page shows the same
    /// caption, the same metric line, and then its comments and its composer.
    /// The cut is wherever the two part company:
    ///
    /// * **Truncated caption** — they part at the card's fourth line, because
    ///   the page has a fifth. Measured on an iPhone SE, that is 103pt into a
    ///   145pt card, and 154pt of the page below it has no counterpart at all.
    /// * **Whole caption** — the caption matches AND the metric line matches
    ///   (the page's caption row borrows this cell's own constants, so the two
    ///   are the same layout at the same offsets — measured, a 101pt row
    ///   against a 101pt anchor). They part below the card's own bottom, where
    ///   the page keeps going into its comments.
    ///
    /// Answering `nil` for the second case is what this used to do, and it left
    /// a short post's comments on screen for the whole flight only to have them
    /// vanish in the final frame. There is no post for which the page and the
    /// card agree all the way down: the page always has a comment stream.
    ///
    /// MEASURED, never read off a subview's frame — see the note in
    /// `captionEnd` below, and `CaptionTruncationTests`.
    public var revealCut: CGFloat? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // PAGE-relative, not card-relative, and the distinction matters now
        // that a card can carry a band the page has no counterpart for. The
        // veil is hung at `anchor.minY + cut` inside the DESTINATION, whose
        // caption sits at `captionTopInset` from its row's top — so the cut is
        // measured from where the caption starts, never from the card's edge.
        //
        // The whole caption is shown: the difference starts below everything
        // the card has, which is its height less the band above the caption.
        guard showMoreRange != nil else { return bounds.height - revealCaptionTop }
        return captionEnd
    }

    /// How far below this card's top its CAPTION begins.
    ///
    /// Zero without an author band, and the band plus its gap with one. It is
    /// the number a reveal needs in order to depart from the whole card while
    /// still landing its caption on the card's own.
    ///
    /// The first attempt avoided needing it: the flight departed from below the
    /// band instead, which kept the caption at `captionTopInset` inside the
    /// window at both ends and left the registration untouched. The frames
    /// killed it. A window that stops short of the card's top edge leaves the
    /// band outside the transition entirely, so the card gains it in one frame
    /// at the landing — a cut exactly where this transition is supposed to be
    /// seamless. The window has to be the card, and the offset has to be
    /// carried instead of avoided.
    public var revealCaptionTop: CGFloat {
        showsAuthorBand ? PostAuthorBandView.captionOffset : 0
    }

    /// The caption's own height plus the inset above it, in the register the
    /// DESTINATION uses — which is why it does not include the author band.
    ///
    /// MEASURED, never read off the label's frame, and that distinction is the
    /// whole of this property.
    ///
    /// A self-sizing cell gets its height from the collection view's
    /// attributes, but its subtree keeps the geometry of whatever pass last ran
    /// over it. Arm a reveal in that window and they disagree in a way that
    /// looks like nothing is wrong: measured on an iPhone SE, `bounds` was a
    /// correct 343x145 while the card underneath was still 343x88 and the label
    /// inside it 311x30 — for text that measures 86.5. `setNeedsLayout` +
    /// `layoutIfNeeded` did NOT reconcile them.
    ///
    /// The veil built on 46pt instead of 103 cut the page three lines too high,
    /// so the flight carried a greyed slab where the card's own four lines
    /// belonged. So the two inputs here are the ones that are always right:
    /// `bounds`, which comes from the attributes, and the label's own opinion
    /// of its text. `ceil` for the reason `preferredLayoutAttributesFitting`
    /// ceils — half a point short is a clipped descender.
    private var captionEnd: CGFloat? {
        let available = bounds.width - Self.captionInset * 2
        guard available > 0 else { return nil }
        let text = captionLabel.sizeThatFits(
            CGSize(width: available, height: .greatestFiniteMagnitude)
        )
        return Self.captionTopInset + ceil(text.height)
    }

    /// The preview's rect in this cell's own space, or nil for a text-only row    /// The preview's rect in this cell's own space, or nil for a text-only row
    /// (which has no media to fly). A hero source reads this to decide whether
    /// a row can host a flight at all.
    public var mediaHeroRect: CGRect? {
        guard !mediaView.isHidden else { return nil }
        layoutIfNeeded()
        // A collection departs from the PAGE, not the box. The box is wider by
        // the carousel's peek and holds a slice of a second photograph, so a
        // flight that took it would carry two images and land one.
        if let carousel, !carousel.isHidden,
           let page = carousel.currentPageRect(in: self) {
            return page
        }
        return mediaView.frame
    }

    /// The image the preview is currently showing — the exact pixels the
    /// viewer is looking at, so a flight starts from them rather than from a
    /// cache lookup that could miss.
    ///
    /// For a collection that is the page the viewer has scrolled to, not the
    /// post's first attachment: once they have swiped, the first attachment is
    /// no longer what they are looking at.
    public var renderedCover: UIImage? {
        if let carousel, !carousel.isHidden { return carousel.renderedCover }
        return mediaView.image
    }

    /// The preview box — a row's media is one part of its card, so this is the
    /// part visibility is measured against. Falls back to the whole cell only
    /// for a text row, which has no video to measure anyway.
    public var videoMediaRect: CGRect {
        // ⚠️ THE PAGE, not the box, once a collection is showing.
        //
        // The box is wider than a page by `peek` and holds a slice of a
        // different attachment. Measuring it asks "is the viewer looking at
        // this preview" where the question is "at this video" — and on a mixed
        // carousel those differ by a whole page.
        if showsCarousel, let page = carousel?.currentPageRect(in: self) { return page }
        return mediaHeroRect ?? bounds
    }

    /// True while this row is drawing its collection rather than a single
    /// preview. Asked in several places, and each of them was a `!(x?.y ?? true)`
    /// before, which is one negation too many to read at a glance.
    @objc private func handleMediaHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onMediaHoldChanged?(true)
        case .ended, .cancelled, .failed:
            // ⚠️ `.cancelled` is the COMMON case, not an edge one: it fires when
            // a finger rests and then drags to page or to scroll. Treating it as
            // anything but "the hold is over" leaves the clip paused for good
            // after an ordinary swipe.
            onMediaHoldChanged?(false)
        default:
            break
        }
    }

    /// Whether this row is drawing a COLLECTION rather than one attachment.
    ///
    /// Public because the question "is this row on its clip's page" only means
    /// anything for a collection — a single attachment is always on its own —
    /// and the caller that decides whether a row should be advancing has to be
    /// able to tell the two apart. It could not, and every single-video row in
    /// the feed was declared paused as a result.
    public var showsCarousel: Bool { !(carousel?.isHidden ?? true) }

    /// The stream the CURRENT page carries, nil when the page is a still.
    ///
    /// ⚠️ The reason a caller must not use `GalleryPost.videoURL` for this: that
    /// answers for page one for ever, and a mixed collection's answer changes as
    /// the viewer scrolls. A row with a photograph on page one and a clip on
    /// page two is a `.photo` post whose current page plays.
    public var currentPageVideoURL: URL? {
        showsCarousel ? carousel?.currentPageVideoURL : nil
    }

    /// The clip this row is holding a player for, whether or not the viewer is
    /// on its page.
    ///
    /// ⚠️ What the POOL is asked about, where `currentPageVideoURL` is what
    /// decides whether it advances. A row that answered only for its current
    /// page would drop out of the ranking the moment the viewer paged onto a
    /// photograph — the slot would go, the player with it, and the paused frame
    /// would be replaced by the thumbnail this exists to keep off screen.
    public var retainedVideoURL: URL? {
        currentPageVideoURL ?? (loadedVideoRenderView == nil ? nil : hostedPageVideoURL)
    }

    /// The clip belonging to the page the surface is actually hanging in.
    private var hostedPageVideoURL: URL? {
        guard let carousel, let surface = loadedVideoRenderView else { return nil }
        return carousel.videoURL(ofPageHosting: surface)
    }

    /// The viewer moved this row's carousel. Reported OUT because what has to
    /// happen next — reconciling autoplay against a page that may or may not be
    /// a video — is the surface's business, not the cell's.
    public var onMediaPageChanged: ((Int) -> Void)?

    /// A finger is resting on this row's media (`true`), or has lifted
    /// (`false`). Relayed from the carousel, or from the preview itself for a
    /// single attachment — the gesture is the same on both, and so is what it
    /// means.
    public var onMediaHoldChanged: ((Bool) -> Void)?

    // MARK: - Autoplay surface

    /// The surface an autoplaying row renders into, built on first use so a
    /// timeline of stills never allocates a player layer it will not use.
    ///
    /// Placed INSIDE the preview box, unlike the tile's, which fills the whole
    /// cell. That is the row's shape talking: the media is one part of a card,
    /// so the video has to be clipped to the part — and putting it in the box
    /// also means it inherits the box's rounding and, for free, the alpha that
    /// `setHeroMediaConcealed` applies while a twin is in the air. A sibling
    /// surface would have needed concealing separately, and would have been
    /// the thing left visible over a flight.
    ///
    /// ⚠️ For a collection it answers PER PAGE, once a budget has bought the row
    /// a second surface. Until then `pageSurfaces` holds at most the watched
    /// page and this behaves exactly as the single-surface version every
    /// existing caller was written against.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        // ⚠️ GATED ON A GRANTED BUDGET, and this is not an optimisation.
        //
        // Minting per page regardless meant a row with no allowance still ended
        // up holding two surfaces — and the coordinator reads exactly that
        // ("more than one surface") to decide it may release a loan instead of
        // stopping it. So a row nobody had given anything to would leave the
        // previous clip's player bound, untracked and unreclaimable. With the
        // gate, a budget of zero is the old single-surface behaviour, exactly.
        if showsCarousel, clipBudget > 0, let carousel, carousel.currentPageVideoURL != nil {
            let page = carousel.currentPage
            if let existing = pageSurfaces[page] {
                loadedVideoRenderView = existing
                install(existing)
                return existing
            }
            // The row's first surface belongs to the first clip page that asks
            // for one: minting a second here would leave the original hanging
            // with a live player and no page to draw it on.
            if let inherited = loadedVideoRenderView,
               !pageSurfaces.values.contains(where: { $0 === inherited }) {
                pageSurfaces[page] = inherited
                install(inherited)
                return inherited
            }
            let view = VideoRenderView()
            #if DEBUG
            view.debugLabel = "row-p\(page)"
            #endif
            view.isHidden = true
            view.isUserInteractionEnabled = false
            pageSurfaces[page] = view
            loadedVideoRenderView = view
            install(view)
            return view
        }
        if let loadedVideoRenderView {
            // ⚠️ RE-INSTALLED, not just returned.
            //
            // On a collection the surface is evicted from its page on every
            // page change — it has to be, or a clip keeps drawing on the page
            // the viewer scrolled away from, which is still on screen peeking.
            // Returning the view without putting it back somewhere meant the
            // SECOND visit to a clip played into a view with no superview: the
            // coordinator reported a clean start, the pool decoded, and the
            // card showed a still. Autoplay worked exactly once per row.
            //
            // `install` no-ops when the surface is already where it belongs, so
            // the single-attachment path is untouched — re-pinning it would
            // reset `isReadyForDisplay` for ~170ms on every reconcile.
            install(loadedVideoRenderView)
            return loadedVideoRenderView
        }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "row"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        install(view)
        loadedVideoRenderView = view
        return view
    }

    /// Puts the playback surface where the media the viewer is looking at
    /// actually is: pinned to the preview box for a single attachment, and
    /// re-parented onto the current PAGE for a collection.
    ///
    /// ⚠️ The two use different layout systems on purpose, and that is why this
    /// exists rather than a branch at each call site. The box is laid out by
    /// constraints; the carousel places its pages by FRAME on every width
    /// change, and a surface pinned by constraints inside one of them would
    /// fight the page it is sitting in. `removeFromSuperview` first, because
    /// that is what drops the constraints the previous home left on it.
    private func install(_ view: VideoRenderView) {
        if showsCarousel, let carousel {
            // ⚠️ ONLY onto a page that carries a clip.
            //
            // This hosted on whatever page was current, which is fine while the
            // viewer is looking at the video and catastrophic one page over: any
            // caller asking for the surface — and the flight staging is one —
            // moved it onto the PHOTOGRAPH being read and drew the clip over it.
            // On screen the card swapped to the video at the instant of the tap,
            // and the flight then carried what it found.
            //
            // A still page is left alone. The surface stays where it belongs,
            // paused, and comes back when the viewer does.
            guard carousel.currentPageVideoURL != nil else { return }
            guard !carousel.hostsSurfaceOnCurrentPage(view) else { return }
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            carousel.host(view)
            return
        }
        guard view.superview !== mediaView else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        mediaView.addSubview(view)
        view.pin(to: mediaView)
        sendVideoSurfaceBelowBadge(view)
    }

    public private(set) var loadedVideoRenderView: VideoRenderView?

    // MARK: - Retained clips

    /// A surface per clip page this row is keeping warm, keyed by page.
    ///
    /// ⚠️ THE ROW'S BUDGET IS WHAT IS LEFT OVER, not the pool's whole capacity.
    ///
    /// A post open full-screen is the only thing drawing and may spend the lot.
    /// A row is one of several on screen, and the coordinator hands every chosen
    /// row a player before anything is kept warm — so a row helping itself to
    /// the same window would starve its neighbours, which is precisely the
    /// budget `maxConcurrent` exists to divide. `retainClips(budget:)` is told
    /// how much is spare; when the answer is nothing, this holds one entry and
    /// the row behaves as it always did.
    private var pageSurfaces: [Int: VideoRenderView] = [:]

    /// How many EXTRA clips this row has been allowed to keep. Zero until a
    /// coordinator says otherwise, which is what makes the retention opt-in
    /// rather than something a row helps itself to.
    private var clipBudget = 0

    /// The surface belonging to the page the viewer is actually looking at.
    ///
    /// ⚠️ ASKED OF THE CAROUSEL, NEVER REMEMBERED — and that is the whole of a
    /// reported defect.
    ///
    /// `loadedVideoRenderView` is re-pointed when someone asks the cell for a
    /// surface, which happens in the coordinator's START pass. Anything running
    /// BEFORE that — the pause pass, in particular — reads the page the viewer
    /// has just left. Pausing "everything except the watched one" then spared
    /// the clip being left and paused the one arriving, so a card's carousel
    /// ended up with two clips playing at once.
    ///
    /// A still page has no watched clip, which is the honest answer: nothing on
    /// it should be advancing.
    public var watchedClipSurface: VideoRenderView? {
        guard showsCarousel, let carousel else { return loadedVideoRenderView }
        return pageSurfaces[carousel.currentPage]
    }

    public var retainedPlaybackSurfaces: [VideoRenderView] {
        var surfaces = Array(pageSurfaces.values)
        if let loadedVideoRenderView,
           !surfaces.contains(where: { $0 === loadedVideoRenderView }) {
            surfaces.append(loadedVideoRenderView)
        }
        return surfaces
    }

    @discardableResult
    public func retainClips(budget: Int) -> [VideoRenderView] {
        clipBudget = budget
        guard showsCarousel, let carousel else { return [] }
        // One policy, in one place: the same window the post page uses. The
        // budget is the EXTRA allowance, so the watched clip is added back — a
        // row granted nothing still keeps the one it is playing.
        let keep = Set(CarouselRetentionWindow.pagesToRetain(
            videoPages: carousel.videoPageIndices,
            currentPage: carousel.currentPage,
            capacity: budget + 1
        ))
        var dropped: [VideoRenderView] = []
        for (page, view) in pageSurfaces where !keep.contains(page) {
            guard view !== loadedVideoRenderView else { continue }
            carousel.evictSurface(onPage: page)
            view.removeFromSuperview()
            pageSurfaces[page] = nil
            dropped.append(view)
        }
        // Re-hung every time, and idempotent: a page whose surface is still its
        // own but whose carousel was re-laid out has to be put back.
        for (page, view) in pageSurfaces {
            view.translatesAutoresizingMaskIntoConstraints = true
            carousel.host(view, onPage: page)
        }
        return dropped
    }

    /// The clips this row would like brought to their first frame, each with a
    /// surface ready to receive one.
    ///
    /// The surface carries THAT page's cover as its poster: hosted without one
    /// it is a black rectangle over the photograph until the stream fills,
    /// which is a worse fault than the delay the warming is there to remove.
    public func clipsToPrewarm() -> [(url: URL, surface: VideoRenderView)] {
        guard showsCarousel, clipBudget > 0, let carousel else { return [] }
        let pages = CarouselRetentionWindow.pagesToPrewarm(
            videoPages: carousel.videoPageIndices,
            currentPage: carousel.currentPage,
            budget: clipBudget
        )
        return pages.compactMap { page in
            guard let url = carousel.videoURL(onPage: page) else { return nil }
            let view: VideoRenderView
            if let existing = pageSurfaces[page] {
                view = existing
            } else {
                view = VideoRenderView()
                #if DEBUG
                view.debugLabel = "row-warm-p\(page)"
                #endif
                view.isUserInteractionEnabled = false
                pageSurfaces[page] = view
            }
            view.setPoster(carousel.cover(onPage: page))
            view.isHidden = false
            view.translatesAutoresizingMaskIntoConstraints = true
            carousel.host(view, onPage: page)
            return (url, view)
        }
    }

    /// Gives up every clip surface but the watched one — for reuse, and for the
    /// end of this row's playback.
    @discardableResult
    public func releaseRetainedClips() -> [VideoRenderView] {
        var dropped: [VideoRenderView] = []
        for (page, view) in pageSurfaces where view !== loadedVideoRenderView {
            carousel?.evictSurface(onPage: page)
            view.removeFromSuperview()
            pageSurfaces[page] = nil
            dropped.append(view)
        }
        return dropped
    }

    /// For a collection: only while the surface hangs in the page being looked
    /// at. A paused clip one page over is rendering, and is not what the viewer
    /// is looking at.
    public var isRenderingCurrentMedia: Bool {
        guard let view = loadedVideoRenderView else { return false }
        guard showsCarousel, let carousel else { return true }
        return carousel.hostsSurfaceOnCurrentPage(view)
    }

    /// Whether the surface could actually put pixels on screen: on the page
    /// being looked at, visible, and not sitting at zero alpha behind a flight.
    public var isSurfaceDrawable: Bool {
        guard let view = loadedVideoRenderView else { return false }
        return !view.isHidden && view.alpha > 0 && isRenderingCurrentMedia
    }

    /// ⚠️ The CONVERSE fault: a clip drawing on a page that has none.
    ///
    /// The audit's first invariant only asked whether a clip's page was showing
    /// its clip. It could not see the opposite — a surface hosted on a
    /// PHOTOGRAPH — and that is the shape the flight defect took: the card swapped
    /// to the video at the moment of the tap, on a page that carries no video at
    /// all. Both directions are the same requirement stated once: what is on a
    /// page is what that page is.
    /// The surface, for a host that needs to ask the pool about it.
    public var playbackSurface: VideoRenderView? { loadedVideoRenderView }

    public var drawsVideoOnAStillPage: Bool {
        guard let view = loadedVideoRenderView, !view.isHidden, view.alpha > 0,
              showsCarousel, let carousel
        else { return false }
        return carousel.currentPageVideoURL == nil
            && carousel.hostsSurfaceOnCurrentPage(view)
    }

    public func adoptVideoRenderView(_ view: VideoRenderView) {
        if let existing = loadedVideoRenderView, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.isHidden = false
        // ⚠️ THE ADOPTED VIEW IS THIS PAGE'S SURFACE FROM HERE ON.
        //
        // Without this the page map still names the surface the landing just
        // replaced, and the live one — the view actually carrying the adopted
        // player — is in no map at all. Nothing can pause what it cannot name,
        // so that player ran on for as long as the row lived: returning to its
        // page found playback seconds ahead of where it was left, and the
        // picture raced to reach it.
        //
        // Reported precisely: "in the post it pauses properly, in the card the
        // video catches up as if it had kept going". It had. The post's card
        // view took this same line when its own landing was fixed; the row
        // never got it, and that asymmetry is exactly what was observed.
        if showsCarousel, let carousel, carousel.currentPageVideoURL != nil {
            pageSurfaces[carousel.currentPage] = view
        }
        install(view)
        loadedVideoRenderView = view
    }

    /// Keeps the ▶ glyph over the video, the way the tile keeps its furniture
    /// over a playing brick: the badge is what tells a video row apart, and it
    /// should read the same whether the preview is a still or moving.
    ///
    /// Separate from the `pin` above, and it has to be — `pin(to:)` begins with
    /// `addSubview`, which moves the view to the FRONT. Ordering the surface
    /// before pinning it is therefore silently undone, which is exactly what
    /// happened: the first playing row rendered correctly with its badge gone.
    private func sendVideoSurfaceBelowBadge(_ view: VideoRenderView) {
        mediaView.insertSubview(view, belowSubview: playBadge)
    }

    public func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        // Told, not inferred. Removing the view from its superview leaves a
        // carousel page still believing it holds one — its reference is weak
        // and the flight card retains the view — and a page that believes that
        // refuses to take it back.
        carousel?.evictHostedSurface()
        view.removeFromSuperview()
        return view
    }

    /// Reveals the surface once a player has been attached. The cover stays
    /// underneath as the poster, so the first frame replaces it rather than
    /// flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        // `renderedCover`, not `mediaView.image`: on a collection the box's own
        // image view is empty — the pages hold the pictures — so the poster
        // would have been nil and the surface would have shown black until the
        // first frame decoded.
        view.setPoster(renderedCover)
        view.revealOnFirstFrame()
    }

    /// Back to a still row. Faded rather than switched off, so a sweep that
    /// stops several rows at once does not snap their covers back in one frame.
    public func endVideoPreview() {
        loadedVideoRenderView?.hideCrossFading()
    }

    /// Puts a cover on immediately, without waiting for the async load already
    /// in flight — the same race the tile closes, for the same reason: the
    /// autoplay gate must not pass on a cover the row is not actually showing.
    public func applyCover(_ image: UIImage) {
        guard mediaView.image == nil else { return }
        mediaView.image = image
        loadedVideoRenderView?.setPoster(image)
    }

    /// Fired when the cover lands from an async load, so the autoplay gate is
    /// re-run for a row that arrived faceless.
    public var onCoverLoaded: (() -> Void)?

    /// Called when the collection view recycles this row, so the coordinator
    /// takes its player back before the cell is bound to another post.
    public var onReuse: (() -> Void)?

    /// Decides whether the caption OVERFLOWS, at the width the layout is
    /// actually going to give this row.
    ///
    /// It cannot be decided in `configure`: a self-sizing cell is configured
    /// before it is sized, so the width there is whatever the recycled cell
    /// happened to be carrying, and a caption measured against the wrong width
    /// answers the wrong question — three lines at one width is five at
    /// another. The attributes are authoritative, which is the same reason
    /// `CaptionBubbleCell` measures here rather than there.
    ///
    /// The measurement is the honest one: how tall the caption WANTS to be
    /// against how tall the cap allows. Asking `UILabel` whether it truncated
    /// would be reading a result of the layout pass that is being computed.
    override public func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let targetWidth = layoutAttributes.frame.width
        guard targetWidth > 0 else {
            return super.preferredLayoutAttributesFitting(layoutAttributes)
        }
        if abs(bounds.width - targetWidth) > 0.5 {
            bounds.size.width = targetWidth
        }
        composeCaption(atWidth: targetWidth)
        // The preview's height is a function of the row's width, so it belongs
        // in the same pass and for the same reason: `configure` runs before the
        // cell is sized, and a height resolved against a recycled cell's old
        // width is the wrong height.
        resolveMediaHeight(atWidth: targetWidth)
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let fitted = contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        // Ceil, not round: half a point short of the caption is a clipped
        // descender on the last line.
        layoutAttributes.frame.size.height = ceil(fitted.height)
        return layoutAttributes
    }

    private func resolveMediaHeight(atWidth width: CGFloat) {
        mediaHeight.constant = Self.mediaHeight(
            forCardWidth: width, aspectRatio: mediaAspectRatio
        )
    }

    /// The ellipsis and the affordance, written INTO the caption so they sit at
    /// the end of the truncated text rather than under it.
    ///
    /// A label cannot do this for itself: `.byTruncatingTail` puts its ellipsis
    /// at the very end of the last line and leaves nowhere to put anything
    /// after it. So the text is shortened here, by hand, to the longest
    /// word-boundary prefix that still leaves room for "… Show more" on the
    /// last line — which is what makes the affordance read as part of the
    /// sentence it interrupts.
    private func composeCaption(atWidth width: CGFloat) {
        let font = captionLabel.font ?? .preferredFont(forTextStyle: .body)
        let available = width - Self.captionInset * 2
        guard !isCaptionExpanded, !fullCaption.isEmpty, available > 0 else {
            showMoreRange = nil
            captionLabel.attributedText = Self.plain(fullCaption, font: font)
            return
        }
        // Measured in LINES, from the font's own metrics — never a hardcoded
        // height, or a Dynamic Type step silently changes which captions are
        // considered long.
        let whole = Self.plain(fullCaption, font: font)
        guard Self.lineCount(whole, width: available) > Self.captionLineLimit else {
            showMoreRange = nil
            captionLabel.attributedText = whole
            return
        }
        let composed = Self.truncated(
            fullCaption, font: font, width: available, capLines: Self.captionLineLimit
        )
        captionLabel.attributedText = composed.text
        showMoreRange = composed.showMore
    }

    private static let showMoreTitle = "Show more"
    private static let ellipsis = "\u{2026} "

    private static func plain(_ text: String, font: UIFont?) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ])
    }

    /// How many lines `text` occupies at `width`, counted as LINE FRAGMENTS.
    ///
    /// Not `height / font.lineHeight`, which is what this did first and is
    /// wrong in a way that hides: `boundingRect` returns the laid-out height
    /// including leading, which for four lines of body text measured 88pt
    /// against a 20.5pt line height — 4.29, not 4. Rounding rescues small
    /// counts and drifts into over-reporting as they grow, so the error only
    /// appears at large Dynamic Type sizes or long captions.
    private static func lineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        guard text.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        var count = 0
        var index = 0
        while index < manager.numberOfGlyphs {
            var effective = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            count += 1
            index = NSMaxRange(effective)
        }
        return count
    }

    /// The longest word-boundary prefix of `text` whose last line still has
    /// room for "… Show more" AFTER it, plus the range that affordance
    /// occupies.
    ///
    /// Two steps, because the property wanted is not monotone and a single
    /// search cannot find it:
    ///
    /// 1. binary search for the longest prefix that fills at most `capLines` on
    ///    its own — this part IS monotone;
    /// 2. walk back a word at a time until the affordance fits on the same line
    ///    the prefix ends on.
    ///
    /// Searching in one step on "does the composition fit in `capLines`"
    /// instead — which is what this did first — maximises the wrong thing: a
    /// prefix filling three lines with the affordance wrapped alone onto a
    /// fourth satisfies it perfectly, and puts the affordance back on its own
    /// line, which is exactly what it exists to avoid. Caught by a test that
    /// counted the prefix's lines rather than the composition's.
    ///
    /// Word boundaries rather than characters: a caption cut mid-word reads as
    /// a rendering fault rather than as an interruption, and there are far
    /// fewer of them to search.
    private static func truncated(
        _ text: String, font: UIFont, width: CGFloat, capLines: Int
    ) -> (text: NSAttributedString, showMore: NSRange) {
        let ns = text as NSString
        var boundaries: [Int] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            boundaries.append(range.location + range.length)
        }
        if boundaries.isEmpty { boundaries = [ns.length] }

        func prefix(upTo end: Int) -> String {
            ns.substring(to: min(end, ns.length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func compose(_ prefix: String) -> NSAttributedString {
            let composed = NSMutableAttributedString(
                attributedString: plain(prefix + ellipsis, font: font)
            )
            composed.append(NSAttributedString(string: showMoreTitle, attributes: [
                .font: font,
                .foregroundColor: UIColor.tintColor
            ]))
            return composed
        }

        // 1. The longest prefix that fills at most `capLines` by itself.
        var low = 0
        var high = boundaries.count - 1
        var fullest = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = plain(prefix(upTo: boundaries[mid]), font: font)
            if lineCount(candidate, width: width) <= capLines {
                fullest = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        // 2. Back off until the affordance shares the prefix's last line.
        var index = fullest
        while index >= 0 {
            let body = prefix(upTo: boundaries[index])
            let composed = compose(body)
            let bodyLines = lineCount(plain(body, font: font), width: width)
            let composedLines = lineCount(composed, width: width)
            if composedLines == bodyLines, composedLines <= capLines {
                return (composed, showMoreRange(in: composed))
            }
            index -= 1
        }
        // Nothing fits beside it — a first word wider than the row. Show the
        // affordance alone rather than nothing at all.
        let composed = compose(prefix(upTo: boundaries[0]))
        return (composed, showMoreRange(in: composed))
    }

    private static func showMoreRange(in composed: NSAttributedString) -> NSRange {
        NSRange(
            location: composed.length - (showMoreTitle as NSString).length,
            length: (showMoreTitle as NSString).length
        )
    }

    /// Brings in the closing metric line, which the page never had, instead of
    /// letting it appear in a single frame.
    ///
    /// It runs at the LANDING — once the page is gone and the card is alone —
    /// and not during the flight, because the page is veiled over exactly that
    /// band: anything faded underneath an opaque cover arrives at full opacity
    /// anyway.
    ///
    /// ## Why the caption is NOT faded with it
    ///
    /// The card and the page differ on one more thing: the tail of the last
    /// line, where the affordance displaced the words the page still shows —
    /// "…a migration that… Show more" against "…a migration that had been".
    /// Cross-fading that was tried twice, once by dissolving the whole page
    /// against the card and once by dissolving this label against a copy of
    /// the page's version. Both showed the same artifact, because it is not a
    /// property of the mechanism: blending two DIFFERENT runs of text draws
    /// both of them, and the result reads as "that.had beenmore" rather than
    /// as a substitution.
    ///
    /// A fade only works against nothing, which is why the metric line takes
    /// one and the caption does not. Removing that last pop needs the two
    /// sides to stop differing — either the page truncating its own line four
    /// for the flight, or the veil hiding it so the card's can arrive into
    /// empty space — and both are structural rather than a fade.
    public func fadeInRevealedFurniture(duration: TimeInterval = 0.22) {
        // ONLY when the caption was truncated, and the symmetry with
        // `revealCut` is the reason. A truncated card's metric line arrives
        // into a band the page was filling with words, so it has to be brought
        // in rather than switched on. A whole caption's does not: the page
        // carries the same metric line at the same offset, unveiled, for the
        // entire flight — fading it in here would blink something that was
        // already on screen.
        // The BAND is deliberately absent from this, and its absence replaced a
        // fade that was here for one commit. The destination now BORROWS this
        // row's band for the flight (see `installRevealAuthorBand`), so the
        // window already shows a header identical to this one — the swap at the
        // landing is the identity, and fading this one in from zero would blink
        // something the viewer was already looking at.
        guard showMoreRange != nil else { return }
        metaRow.alpha = 0
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            self.metaRow.alpha = 1
        }
    }

    #if DEBUG
    /// Presses "Show more". Returns false when there was nothing to reveal,
    /// which is the answer a harness must not mistake for success.
    ///
    /// The simulator injects no touches, so this is the only way this control
    /// is reachable in an automated run.
    ///
    /// Fired when the viewer taps the media of a COLLECTION row.
    ///
    /// A row with one photograph needs nothing here — the collection view's own
    /// selection handles it. A carousel is a scroll view, and a scroll view in
    /// the content path swallows that selection, so the host has to be told
    /// separately. See `MediaCarouselView.onTapped`.
    public var onMediaTapped: (() -> Void)?

    /// Moves this row's carousel, e.g. to follow the page an opened post is on.
    /// Ignored by a row with no collection.
    public func setMediaPage(_ page: Int, animated: Bool = true) {
        guard let carousel, !carousel.isHidden else { return }
        carousel.setPage(page, animated: animated)
    }

    /// Which page of this row's carousel is showing, or nil for a row with no
    /// collection. A hero flight departs from this page, so whatever opens the
    /// post has to land on it.
    public var currentMediaPage: Int? {
        guard let carousel, !carousel.isHidden else { return nil }
        return carousel.currentPage
    }

    /// Scrolls this row's carousel, or false if it has none.
    @discardableResult
    public func debugScrollCarousel(toPage index: Int, animated: Bool = true) -> Bool {
        guard let carousel, !carousel.isHidden else { return false }
        return carousel.debugScroll(toPage: index, animated: animated)
    }

    @discardableResult
    public func debugTapShowMore() -> Bool {
        guard showMoreRange != nil else { return false }
        revealTapped()
        return true
    }
    #endif

    /// Hides ONLY the preview while its twin is in the air.
    ///
    /// A row is a card of which the media is one part, and the flight carries
    /// that part (`mediaHeroRect`) — so that part is exactly what must
    /// disappear. Hiding the whole cell instead, which is what a tile needs,
    /// took the caption, the author line and the metrics with it: they were
    /// missing for the length of the flight and snapped back at its last
    /// frame, because nothing in the air was standing in for them.
    ///
    /// The invariant, in one line: CONCEAL EXACTLY WHAT THE FLIGHT
    /// REPRODUCES. A tile is its media, so the tile hides whole; a row is not,
    /// so it does not. A text row never flies at all — it pushes natively.
    ///
    /// Alpha, not `isHidden`, and that is load-bearing: `mediaHeroRect`
    /// reports nil for a hidden preview, so hiding it would make the row
    /// unable to answer where its own media is — which is the rect the
    /// DISMISSAL flies home to.
    ///
    /// The metadata pills go with it, and they get there for free: they are
    /// subviews OF the preview, so the one alpha carries them. That is why they
    /// were built inside it rather than over it in the card — a chip left
    /// floating on an empty rounded box for the length of a flight is the same
    /// defect as a caption that vanishes, on a smaller scale, and the way not
    /// to have it is to have no second channel to keep in step.
    ///
    /// (The `playBadge` line below is that second channel, and it is redundant
    /// for exactly this reason — the badge is inside the preview too. Kept,
    /// because a reader checking whether the badge is concealed should find an
    /// answer rather than infer one.)
    public func setHeroMediaConcealed(_ concealed: Bool) {
        // A COLLECTION conceals one PAGE, not the preview.
        //
        // The rule is the same one this method's note states — conceal exactly
        // what the flight reproduces — read one level further in: a flight from
        // a collection carries the current page, so the box, the neighbour's
        // peek and the chips all stay. Hiding the box took the peek and the
        // chips with it and brought the whole strip back in one frame at the
        // landing, which is the pop this rule exists to prevent, rebuilt inside
        // the preview it was written for.
        // ⚠️ REMEMBERED, because a flight outlives a configure.
        //
        // A row can be re-dequeued and reconfigured while its twin is in the
        // air, and `prepareForReuse` resets the furniture to visible. The
        // concealment was applied to the instance that flew, so the fresh one
        // came back with its play badge lit in the MIDDLE of a dismissal —
        // on single-media rows only, because a collection's badge is hidden
        // outright by `post.isCollection` and so has nothing to reveal.
        // ⚠️ Only a flight ENDING earns the settle. `prepareForReuse` comes
        // through here too, and animating there would flutter the chips of
        // every row a scroll recycles — a cost paid continuously for an effect
        // that belongs to one moment.
        let wasConcealed = isHeroMediaConcealed
        isHeroMediaConcealed = concealed
        // ⚠️ THE FURNITURE GOES IN BOTH SHAPES, and that is the unification.
        //
        // A single attachment hid its chips for free — they are subviews of the
        // preview, and the preview went to alpha 0. A collection conceals only
        // the PAGE, so its counters, date and indicator stayed lit through the
        // whole flight while the single-media version's vanished. Same gesture,
        // two behaviours, which is exactly the doubt raised about whether this
        // was ever really unified. It was not.
        //
        // What the flight carries is the media. What it does not carry is the
        // furniture — so the furniture goes, in both.
        for view in furnitureViews { view.alpha = concealed ? 0 : 1 }
        if let carousel, !carousel.isHidden {
            carousel.setCurrentPageConcealed(concealed)
        } else {
            mediaView.alpha = concealed ? 0 : 1
        }
        if wasConcealed, !concealed { animateFurnitureIn() }
    }

    /// Everything the preview wears that the flight does not reproduce.
    private var furnitureViews: [UIView] {
        [likesPill, commentsPill, agePill, pageIndicator, playBadge]
    }

    /// Whether a flight is currently standing in for this row's media.
    private(set) var isHeroMediaConcealed = false

    /// Brings the chips, the date and the badge back with a settle rather than
    /// a switch.
    ///
    /// ⚠️ The MEDIA is deliberately not animated. The flight has just handed the
    /// picture over; fading THAT in would show the hand-off instead of hiding
    /// it. What pops is the furniture — counters, date, badge — which the flight
    /// never carried and which therefore arrives from nothing on the landing
    /// frame.
    private func animateFurnitureIn() {
        // ⚠️ NOT ALL AT ONCE, AND NOT AS ONE PIECE.
        //
        // Four chips arriving on the same frame with the same curve read as a
        // single sheet being switched on — the eye sees one event, not four
        // objects. A few hundredths of a second between them is enough for it
        // to read as things settling into a row.
        //
        // And each capsule's CONTENTS lag its shape by a couple of points. A
        // label transformed with its capsule is one object sliding; a label that
        // arrives a moment after the shape it sits in makes the shape read as a
        // container the text drops into. It is a small dishonesty about physics
        // and it is what makes the row feel alive rather than assembled.
        // ⚠️ FADE AND SCALE, NO TRANSLATION.
        //
        // A chip that slides in comes FROM somewhere, and there is nowhere for
        // it to have come from — it was always at that spot, merely invisible.
        // Growing into place says the true thing: this was here, and it is
        // arriving. The spring is deliberately shallow; a pronounced bounce on
        // four small capsules reads as a toy.
        for (index, view) in furnitureViews.enumerated() where !view.isHidden {
            let contents = (view as? PostMetaPillView)?.contentRow
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            contents?.alpha = 0
            contents?.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            let step = 0.04 * Double(index)
            UIView.animate(
                withDuration: 0.36, delay: step,
                usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                view.alpha = 1
                view.transform = .identity
            }
            // The contents run the same curve a beat later, so the capsule
            // reads as a container the text grows into rather than as one solid
            // thing changing size.
            UIView.animate(
                withDuration: 0.36, delay: step + 0.06,
                usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                contents?.alpha = 1
                contents?.transform = .identity
            }
        }
    }

    /// Hides whatever THIS row's flight is carrying, for as long as it is in
    /// the air — and the routing lives here because only the row knows.
    ///
    /// A media row flies its preview and keeps the rest: caption, counters and
    /// author stay put, because none of them left. A TEXT row has no preview,
    /// and what a reveal carries away is the card itself — so the card is what
    /// goes.
    ///
    /// Without this a dragged window and the row it came from show the same
    /// post twice, side by side, which is not a hero picking a card up; it is a
    /// copy being made. The grid keeps the row's SLOT either way, so nothing
    /// reflows underneath while the viewer is holding it.
    public func setHeroConcealed(_ concealed: Bool) {
        if mediaView.isHidden {
            card.alpha = concealed ? 0 : 1
        } else {
            setHeroMediaConcealed(concealed)
        }
    }


    /// The card's own rounding and fill, so a flight impersonating this row
    /// is its twin rather than an approximation of it. Restating either as a
    /// literal in the flight card is how the two drift.
    /// The platform's own radius for a grouped content card.
    ///
    /// There is no named constant to read: iOS 26's `UICornerRadius` offers
    /// only `.fixed(_)` and `.containerConcentric(minimum:)`, and a card at the
    /// root of a scroll view has no rounded container to be concentric with. So
    /// the default is taken from what UIKit DRAWS — an `.insetGrouped` list
    /// section, which is the system's own version of this shape.
    ///
    /// Measured off one, on two independent sections, by fitting the corner
    /// profile `dx = R - sqrt(2·R·dy - dy²)`: **24.8pt (rms 0.28)** and
    /// **25.3pt (rms 0.16)**. The pipeline is calibrated against known radii and
    /// runs a couple of percent low, which puts the true value at 25–26.
    ///
    /// ❌ Two bespoke values were tried against the system context menu first
    /// and both are recorded here so they are not re-derived: **32**, the
    /// menu's own radius, which makes the two curves identical and therefore
    /// makes the band between them swell through the turn (20.0pt on the
    /// straights, 22.8pt at 45°); and **48**, the menu's radius plus the 16pt
    /// margin it sits at, which does hold the band flat (15.5–16.3pt at every
    /// angle) and is simply too round for a card. Matching a transient overlay
    /// was the wrong target — the card is on screen all the time, and it should
    /// look like the platform.
    public static let cardCornerRadius: CGFloat = 26

    /// How far every child of a card is held off its edges: the caption, the
    /// author band, the closing metric line, and the media preview, which is
    /// the point — text and image share one pair of vertical lines rather than
    /// each having its own.
    ///
    /// ## It is not only a margin
    ///
    /// It is the card's ONE free number, and it sets four things at once:
    ///
    /// * the reading padding of a card,
    /// * where the preview's edges fall (on the caption's),
    /// * **the preview's radius**, `cardCornerRadius - contentInset`, and
    ///   therefore how close the image's roundness is to the card's,
    /// * the reading padding of the post's own PAGE — `captionInset` is shared
    ///   with `PostCaptionRowView` structurally, because a reveal has to land
    ///   the window's caption on the card's.
    ///
    /// The third is the one that is easy to miss and the reason this value
    /// cannot be argued to. A card at 26 with a 16pt padding gives a 10pt
    /// preview: correct by the concentric rule and a 2.6× drop in roundness
    /// between the container and the thing inside it, which reads as a hard
    /// rectangle in a soft card.
    ///
    /// **12**, chosen off three builds side by side:
    ///
    /// ```
    ///   padding   preview   drop     page prose
    ///   16        10        2.6x     16   the loosest, and the widest gap
    ///   12        14        1.9x     12   ← here
    ///   10        16        1.6x     10
    ///    8        18        1.4x      8   ❌ measured cramped, page worse
    /// ```
    ///
    /// ❌ 8 is recorded rather than merely rejected: geometrically it is the
    /// most homogeneous of the four, and it is still wrong. It was tried whole —
    /// one number governing every curve in the card (26 → 18 → 10, a constant
    /// band at all three levels, chips landing within half a point of their own
    /// capsule) — and the arithmetic being perfect did not save it. The card
    /// reads cramped, and because the page shares this number, a full column of
    /// prose ended up 8pt from the screen's edge.
    public static let contentInset: CGFloat = 12

    /// The gap between two chips of the preview's bottom row. Smaller than the
    /// inset that holds the row off the preview's edges: chips in one row belong
    /// together more closely than the row belongs to the frame.
    public static let chipGap: CGFloat = 6

    /// How far the preview's own furniture — the metadata pills, the play badge
    /// — is held off its edges. `contentInset` again, and that is the point.
    ///
    /// ## Why furniture may be a capsule, and the preview may not
    ///
    /// The concentric rule — a child's radius is its parent's less the inset
    /// between them — is about CORNERS. It exists because two curves turning
    /// together at a corner have a band between them, and unless the radii
    /// differ by exactly the inset that band swells through the turn. Along a
    /// STRAIGHT edge there is no such constraint: the band is the inset, at
    /// every point, whatever shape the child is.
    ///
    /// So the question for a chip resting on the preview is not what radius the
    /// arithmetic gives it (a rectangle, at any padding worth using) but whether
    /// it is anywhere near the preview's corners at all. Held off both edges by
    /// the preview's own radius or more, it is not: a rounded rect's corner arc
    /// occupies a box of exactly its radius. The chip rests on flat edge, has no
    /// competing curve to hold a band with, and is free to be the capsule a chip
    /// should be.
    ///
    /// ❌ 8 was the first value, and it is what put the chips INSIDE the corner
    /// boxes — where a capsule's ~10.5 sat within half a point of the preview's
    /// own radius, which is the equal-radii case: measured, an 8pt band on the
    /// straights opening to 11.5 at 45°. Concentric would have fixed it at
    /// radius 2 and cost the chips their shape. Moving them off the corner costs
    /// nothing and dissolves the question.
    ///
    /// The clearance is therefore a FLOOR, not a preference: whatever the card's
    /// padding is, furniture on the preview has to start outside an arc whose
    /// size moves the other way. Tighten the card and the preview gets rounder,
    /// and its corners reach further in.
    ///
    /// `CardShapeSystemTests` asserts it, because it is what the capsule is
    /// standing on.
    public static var mediaFurnitureInset: CGFloat {
        max(contentInset, mediaCornerRadius)
    }

    /// How far the media preview is held off the card's edge — named because
    /// the preview's own radius is derived from it, and the two must move
    /// together or the curves stop being parallel.
    public static var mediaInset: CGFloat { contentInset }
    public static let cardFillColor: UIColor = .secondarySystemBackground
    /// The caption's inset, which is the preview's, which is the card's — see
    /// `contentInset`. Public because the post's own page reproduces this exact
    /// register so a reveal's window lands its caption on the card's own.
    public static var captionInset: CGFloat { contentInset }
    public static var captionTopInset: CGFloat { contentInset }
    /// The closing metric line's placement, shared with the flight card that
    /// stands in for a text row.
    public static let metaBottomInset: CGFloat = 14
    /// NOT an inset — the gap between two counters inside the line, which is a
    /// question about reading a row of numbers rather than about where the card
    /// ends. It does not follow `contentInset`.
    public static let metaSpacing: CGFloat = 14
    // MARK: - The card's shape system
    //
    // Every radius on a card, in one place, because four radii chosen
    // separately is how a card stops looking like one object.
    //
    // ```
    //   card      26        the container, and the platform's own answer
    //   preview   14        concentric: 26 - 12, corners ON the card's corners
    //   chips     capsule   clear of the preview's corners, so unconstrained
    //   avatar    circle    a portrait, exempt — see below
    // ```
    //
    // Two rules produce all of it, and the second is the one that is usually
    // missing:
    //
    // 1. **A child whose corners sit at its parent's is concentric with it** —
    //    radius = parent's less the inset. The preview.
    // 2. **A child clear of its parent's corners has no radius obligation at
    //    all** — it meets only straight edge. The chips.
    //
    // An avatar is neither: it is a picture of a person, and every surface in
    // this app draws one as a circle. A circle near a rounded corner has never
    // read as a disagreement, because it is not perceived as a container — it
    // is perceived as a face. Rounding it to 10 for consistency's sake would
    // make the card MORE uniform and less legible, which is the trade a shape
    // system exists to avoid making by accident.
    //
    // ❌ Making the chips concentric was tried and is the reason this note
    // exists: at 8pt in from the preview's edges the arithmetic gave 2, and a
    // chip at radius 2 is a rectangle. The choice looked like "correct shape or
    // correct radius" until the third option turned up — move the chip off the
    // corner, where neither answer is required.
    // MARK: - The preview's height

    /// The widest a preview may be drawn: 16:9. A floor on HEIGHT, and it is
    /// what stops a 21:9 clip from becoming a slit with a subject in it.
    public static let widestMediaAspect: CGFloat = 16.0 / 9.0
    /// The tallest a preview may be drawn: 4:5, the portrait cap Instagram
    /// settled on and the same one the mock corpus already seeds.
    ///
    /// It is the number that decides how much of a screen one card may take.
    /// Measured on this device (402pt wide, 348pt of preview): 4:5 is 435pt of
    /// preview and about 63% of the screen with the band, caption and padding
    /// on top. Uncapped, a 9:16 post would be 619 and **84%** — one post, one
    /// screen, which is what this exists to prevent.
    public static let tallestMediaAspect: CGFloat = 5.0 / 4.0

    /// How tall the preview is for a post of a given shape, in a card of a
    /// given width.
    ///
    /// A pure function of the two, deliberately: the height has to come from
    /// the MODEL and never from the image once it lands. `MediaAttachment`
    /// already states the rule — heights are computed from `aspectRatio`, never
    /// by sizing views — because a height that changes when the file arrives
    /// reflows everything below it in a list the viewer is already scrolling.
    ///
    /// ⚠️ `aspectRatio` is 1 for a SQUARE post and 1 for a post the backend
    /// never stamped with dimensions; `GalleryPost` says so in as many words.
    /// So an unmeasured post lands here as a square — 348pt rather than the
    /// 180pt letterbox rows used to draw. That is the fail-open direction and
    /// it is the right one for a height (a square is a plausible photo; a slit
    /// is not), but it is a real behaviour change for any surface whose
    /// payload omits width and height.
    public static func mediaHeight(forCardWidth cardWidth: CGFloat, aspectRatio: Double) -> CGFloat {
        let mediaWidth = cardWidth - contentInset * 2
        guard mediaWidth > 0 else { return 0 }
        let ratio = aspectRatio > 0 ? CGFloat(aspectRatio) : 1
        let natural = mediaWidth / ratio
        let shortest = mediaWidth / widestMediaAspect
        let tallest = mediaWidth * tallestMediaAspect
        return (min(max(natural, shortest), tallest)).rounded()
    }

    /// How many lines of caption a card previews before it offers the rest.
    ///
    /// A card is a PREVIEW and the post is where the text is read, so the cap
    /// is set where a long caption still reads as a paragraph rather than as a
    /// wall — four lines. Only the card truncates: `PostCaptionRowView`, which
    /// wears the same face on the post's own page, deliberately does not.
    public static let captionLineLimit = 4
    /// The gap between the caption and whatever follows it — the metric line,
    /// the media preview, or the reveal affordance.
    public static let captionFollowGap: CGFloat = 12
    /// The author band's measurements, restated as this cell's own names only
    /// so call sites read naturally — the values live with the view that draws
    /// them, because the reveal's prop draws the same band.
    public static var authorAvatarDiameter: CGFloat { PostAuthorBandView.avatarDiameter }
    public static var authorFollowGap: CGFloat { PostAuthorBandView.captionGap }

    /// Fired when the viewer asks for the rest of a truncated caption. The HOST
    /// owns the answer, not this cell: a cell is recycled and the expansion has
    /// to survive that, so the set of expanded posts lives in
    /// `CaptionExpansion` and comes back through `configure`.
    public var onRevealFullCaption: (() -> Void)?
    /// Fired when the viewer taps the band's identity. The HOST navigates —
    /// a cell cannot reach a navigation controller and should not try.
    public var onAuthorTapped: (() -> Void)? {
        get { authorBand.onAuthorTapped }
        set { authorBand.onAuthorTapped = newValue }
    }

    /// The rows the band's "..." offers, asked for when it is pressed. Nil
    /// hides the control — see `PostAuthorBandView.menuActions`.
    public var authorMenuActions: (() -> [PostCardMenuAction])? {
        get { authorBand.menuActions }
        set { authorBand.menuActions = newValue }
    }

    /// What a popover-shaped sheet raised from the menu should point at.
    public var authorMenuAnchor: UIView { authorBand.menuAnchor }

    /// The band's repost control. Nil HIDES it — visibility tracks the answer,
    /// not the presence of a provider.
    public var onRepostTapped: (() -> Void)? {
        get { authorBand.onRepostTapped }
        set { authorBand.onRepostTapped = newValue }
    }

    /// The band's save control. Nil hides it.
    public var onBookmarkTapped: (() -> Void)? {
        get { authorBand.onBookmarkTapped }
        set { authorBand.onBookmarkTapped = newValue }
    }

    /// Whether this post is saved. Set by the host from whatever owns the pile;
    /// the control never decides for itself.
    public var isBookmarked: Bool {
        get { authorBand.isBookmarked }
        set { authorBand.isBookmarked = newValue }
    }

    /// Draws the band's "..." without wiring it — for a transition's stand-in
    /// card, which must look like the row it stands in for. See
    /// `PostAuthorBandView.showMenuControlAsScenery`.
    public func showAuthorMenuControlAsScenery() {
        authorBand.showMenuControlAsScenery()
    }

    private let card = UIView()
    /// The author band — shown only where the row's post actually carries an
    /// identity.
    ///
    /// A profile gallery's posts do not: that surface is already scoped to one
    /// author, so `GalleryPost`'s author fields are left nil there and the band
    /// disappears without anyone passing a flag. The band is therefore a
    /// function of the DATA rather than of the screen, which is the only
    /// version of this that cannot be wired up wrong.
    ///
    /// The VIEW is shared with the reveal's transition prop — see
    /// `PostAuthorBandView` for why that matters.
    private let authorBand = PostAuthorBandView()
    private var showsAuthorBand = false
    /// The caption hangs off the band when there is one and off the card's own
    /// top edge when there is not — swapped per configure.
    private var captionFollowsBand: NSLayoutConstraint!
    private var captionAtCardTop: NSLayoutConstraint!
    private let captionLabel = UILabel()
    private var isCaptionExpanded = false
    /// The caption as the post carries it. The label shows a SHORTENED version
    /// while truncated, so the label's own text is not a copy of this and
    /// cannot be used in its place.
    private var fullCaption = ""
    /// The closing metric line, held so a landing can bring it in gently —
    /// see `fadeInRevealedFurniture`.
    private var metaRow: UIStackView!
    /// Where "Show more" sits inside the label's current attributed text, or
    /// nil when the caption fits and there is no affordance at all.
    ///
    /// It is the tap target: a range, not a view, because the affordance is a
    /// run of glyphs inside the caption's own layout now — see
    /// `captionTapped`.
    private var showMoreRange: NSRange?
    private let mediaView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.preferredFont(forTextStyle: .footnote)
    /// The closing line's counters — same type, colour and glyph as the two a
    /// media card wears, because they are the same two numbers and will be the
    /// same two buttons.
    private let reactions = PostMetricLabel(
        symbol: "heart", font: PostMetaPillView.font,
        color: PostMetaPillView.foreground, iconColor: PostMetaPillView.glyphForeground
    )
    private let comments = PostMetricLabel(
        symbol: "bubble.right", font: PostMetaPillView.font,
        color: PostMetaPillView.foreground, iconColor: PostMetaPillView.glyphForeground
    )
    private let views = PostMetricLabel(symbol: "eye", font: metaFont, color: .secondaryLabel)
    private let ageLabel = UILabel()
    private var closingLikesPill: PostCardPillView!
    private var closingCommentsPill: PostCardPillView!

    /// The media row's metadata, wearing the overlay's type and colour.
    ///
    /// A SEPARATE INSTANCE rather than the closing line's own label moved onto
    /// the preview: the two placements differ in font, weight, symbol variant
    /// and colour, all of which `PostMetricLabel` fixes at init, so re-parenting
    /// would have meant making every one of them mutable and re-applying the
    /// set on each `configure` — on the recycling path, to save one view.
    ///
    /// LIKES and COMMENTS, one chip each — the two numbers a viewer acts on.
    /// Views are carried by the model and rendered nowhere on a card.
    /// ⚠️ OUTLINE, and the filled variants are deliberately NOT used here.
    ///
    /// These were `heart.fill` and `bubble.right.fill` while the closing line's
    /// were outline, so the same post showed a filled heart on a photograph and
    /// a hollow one on text — the outline/fill pair spent on CONTEXT. It is the
    /// channel that carries STATE, the way the band's bookmark already uses it,
    /// and these two are about to become buttons that need it: filled means the
    /// viewer liked it, not that the post has a picture.
    private let overlayReactions = PostMetricLabel(
        symbol: "heart", font: PostMetaPillView.font,
        color: PostMetaPillView.foreground, iconColor: PostMetaPillView.glyphForeground
    )
    private let overlayComments = PostMetricLabel(
        symbol: "bubble.right", font: PostMetaPillView.font,
        color: PostMetaPillView.foreground, iconColor: PostMetaPillView.glyphForeground
    )
    private let overlayAge = UILabel()
    private var likesPill: PostMetaPillView!
    private var commentsPill: PostMetaPillView!
    private var agePill: PostChipSlotView!
    /// Which page of a collection is showing. Always built — it is a chip in the
    /// same row as the other two and hides itself for a single-media post.
    private let pageIndicator = MediaPageIndicatorView()
    /// Built on first use: most posts have one piece of media.
    private var carousel: MediaCarouselView?

    /// The carousel, for a test that needs to ask where a page put something.
    var debugCarousel: MediaCarouselView? { carousel }

    private var loadTask: Task<Void, Never>?
    /// The metadata line always hangs off the caption; what changes per
    /// configure is whether it CLOSES the card. A media row's line is hidden
    /// under the preview, laid out but drawing nothing, which is what keeps it
    /// out of the height without leaving it unconstrained.
    /// The preview's height, which is the post's OWN aspect ratio clamped —
    /// see `mediaHeight(forCardWidth:aspectRatio:)`. Held so a width change can
    /// re-resolve it.
    private lazy var mediaHeight: NSLayoutConstraint =
        mediaView.heightAnchor.constraint(equalToConstant: 0)
    /// The aspect the current post declares, kept because the height depends on
    /// a width this cell does not know until it is measured.
    private var mediaAspectRatio: Double = 1

    private var metaFollowsCaption: NSLayoutConstraint!
    /// Active for text rows only: the line is the card's last thing. A media
    /// row ends at the preview instead — see `mediaClosesCard`.
    private var metaClosesCard: NSLayoutConstraint!
    private var mediaConstraints: [NSLayoutConstraint] = []

    override public init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Self.cardFillColor
        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.pin(to: contentView)

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = Self.captionLineLimit
        // WORD WRAPPING, not tail truncation, and that is not a detail: the
        // ellipsis is written into the text here rather than drawn by the
        // label, because it has to be followed by "Show more" ON THE SAME
        // LINE. A label that truncates for itself puts the ellipsis at the
        // very end of the last line and leaves nowhere to put anything after
        // it.
        captionLabel.lineBreakMode = .byWordWrapping
        // TOP-ANCHORED DRAWING, and this is what makes the expansion read as a
        // reveal rather than as a jump.
        //
        // A label centres its text block inside its own bounds. Expanding sets
        // the whole caption on a label whose frame is still four lines tall and
        // then animates that frame open — so for the length of the animation
        // the text is taller than the box holding it, and centred means the
        // lines already on screen slide UP and out before drifting back down.
        // Anchored to the top they simply stay where they are while the rest
        // arrives underneath.
        captionLabel.contentMode = .top
        // The affordance is a run of glyphs inside this label, so the label is
        // what receives its tap.
        captionLabel.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(captionTapped))
        tap.delegate = self
        captionLabel.addGestureRecognizer(tap)
        buildAuthorBand()

        captionLabel.constrain(in: card) { parent in
            captionLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.captionInset)
            captionLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.captionInset)
        }
        captionAtCardTop = captionLabel.topAnchor.constraint(
            equalTo: card.topAnchor, constant: Self.captionTopInset
        )
        captionFollowsBand = captionLabel.topAnchor.constraint(
            equalTo: authorBand.bottomAnchor, constant: Self.authorFollowGap
        )
        captionAtCardTop.isActive = true

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true
        // ⚠️ `UIImageView` ships with interaction OFF, and everything inside the
        // preview inherits that: the carousel's scroll view was unhittable, so a
        // swipe on the pages reached the tab pager instead and changed tab.
        //
        // It survived a unit test on the pager's yielding rule AND the fix to
        // that rule, because the rule asks what is under the touch — and with
        // the box refusing hits, what was under the touch was the card. One
        // default, two symptoms, and only a real drag on the simulator found it.
        mediaView.isUserInteractionEnabled = true
        // CONCENTRIC with the card, not a constant of its own: the preview is
        // inset from the card's edge, and a curve parallel to the one around it
        // is the inner radius reduced by exactly that inset. It was 12 against
        // an 18pt card, which was parallel to nothing.
        mediaView.layer.cornerRadius = Self.mediaCornerRadius
        mediaView.layer.cornerCurve = .continuous
        card.addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        // The same inset as the chips at the other end, and as everything on the
        // card above it — furniture on the preview is held off it exactly as the
        // preview is held off the card.
        // ⚠️ HOLD TO PAUSE LIVES ON THE MEDIA, NOT ON THE CAROUSEL.
        //
        // A post with one attachment is a gallery of one — the gesture means the
        // same thing on both and there is no reason for two implementations to
        // drift apart. It sat on the carousel first, which gave the behaviour to
        // collections only and left single-video cards without it.
        //
        // On `mediaView`, an ancestor of the carousel, so the pages still
        // receive the pan.
        //
        // ⚠️ IT MUST CANCEL THE TOUCH, and this is where the two shapes were not
        // really unified. A collection opens by its carousel's own tap; a single
        // attachment opens by the COLLECTION VIEW selecting the cell, which is
        // driven by plain touch delivery. Letting the touch through therefore
        // opened the post the moment a hold ended — on single-media cards only,
        // which is exactly how it was reported.
        //
        // Cancelling costs the pans nothing: a gesture recognizer is not touch
        // delivery, so the carousel still pages and the feed still scrolls. What
        // it stops is the cell's own selection tracking — and only once the hold
        // has actually recognised, so an ordinary tap still opens the post.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleMediaHold))
        hold.minimumPressDuration = MediaCarouselView.holdToPauseDuration
        hold.cancelsTouchesInView = true
        mediaView.addGestureRecognizer(hold)

        playBadge.constrain(in: mediaView) { parent in
            playBadge.topAnchor.constraint(
                equalTo: parent.topAnchor, constant: Self.mediaFurnitureInset
            )
            playBadge.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor, constant: -Self.mediaFurnitureInset
            )
        }
        buildMediaMetaPills()

        ageLabel.font = Self.metaFont
        ageLabel.textColor = .secondaryLabel
        ageLabel.adjustsFontForContentSizeCategory = true
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        // ⚠️ THE SAME TWO CHIPS A MEDIA CARD WEARS — the same numbers, the same
        // order, the same capsule, so the two card shapes offer one affordance.
        //
        // They were a bare pair of grey labels, which was right while the media
        // card's were a legibility device and nothing more. They are becoming
        // BUTTONS, and an affordance that appears only when the post happens to
        // carry a photograph is not an affordance at all.
        //
        // A card pill, not a media one: what is behind them here is the card's
        // flat fill, which a material would resolve to and vanish into.
        closingLikesPill = PostCardPillView(contents: [reactions])
        closingCommentsPill = PostCardPillView(contents: [comments])
        // ⚠️ The DATE stays a bare label, and that asymmetry is deliberate.
        //
        // On the preview it wears a capsule because a word over a photograph has
        // no floor. Here it has one, and a capsule on this card would be read as
        // a control — the very thing the two beside it are about to become. So
        // the card says it plainly: what is in a capsule can be pressed.
        let metaRow = UIStackView(
            arrangedSubviews: [closingLikesPill, closingCommentsPill, spacer, ageLabel]
        )
        self.metaRow = metaRow
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        // The chips' own gap, not the line's: two capsules side by side belong
        // together more closely than a run of loose labels did. The spacer takes
        // up everything else.
        metaRow.spacing = Self.chipGap
        metaRow.constrain(in: card) { parent in
            metaRow.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor, constant: Self.captionInset
            )
            // ⚠️ The DATE is inset by a pill's padding on top of the row's, so
            // the row's INK is symmetric.
            //
            // The row is pinned at `captionInset` on both sides, which aligns
            // the two capsules' EDGES with the caption above and looks correct
            // stated as a constraint. On screen it is lopsided: the leading
            // number starts 12 inside its capsule, so the row's ink runs from 24
            // on the left to 12 on the right and the date appears shoved against
            // the card.
            //
            // Adding the pill's own padding puts the date where it would sit if
            // it wore one — which is what a reader compares it to, the two
            // capsules beside it. Its ink then lands ~24 from the trailing edge
            // and ~21 from the bottom, the same corner the leading chip's number
            // makes on the other side.
            metaRow.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor,
                constant: -(Self.captionInset + PostMetaPillView.insets.trailing)
            )
        }
        metaFollowsCaption = metaRow.topAnchor.constraint(
            equalTo: captionLabel.bottomAnchor, constant: Self.captionFollowGap
        )
        metaFollowsCaption.isActive = true
        metaClosesCard = metaRow.bottomAnchor.constraint(
            equalTo: card.bottomAnchor, constant: -Self.metaBottomInset
        )
        metaClosesCard.isActive = true
        mediaConstraints = [
            mediaView.topAnchor.constraint(
                equalTo: captionLabel.bottomAnchor, constant: Self.captionFollowGap
            ),
            mediaView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.mediaInset),
            mediaView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.mediaInset),
            mediaHeight,
            // The preview CLOSES a media card, at the same inset it is held off
            // the sides by — the metadata that used to sit under it is on the
            // preview now. Concentric all the way round, and the card is 28pt
            // shorter for it.
            mediaView.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -Self.mediaInset
            )
        ]
    }

    /// The two chips that carry a media row's metadata, resting on the
    /// preview's bottom edge — counters leading, age trailing, both inside the
    /// preview so that ONE alpha conceals the lot while a flight is in the air
    /// (see `setHeroMediaConcealed`).
    ///
    /// The bottom edge, and not the top: the play badge already owns the top
    /// trailing corner, and a video row would have had the age underneath it.
    ///
    /// Held off both edges by `mediaFurnitureInset`, which is what puts them
    /// clear of the preview's corner arcs and lets them be capsules — see that
    /// property for the geometry.
    private func buildMediaMetaPills() {
        overlayAge.font = PostMetaPillView.font
        overlayAge.textColor = PostMetaPillView.foreground
        overlayAge.adjustsFontForContentSizeCategory = true
        // 999, not required: the same rung as the counts (see the chip row's
        // priority ladder below), so the date and the numbers hold the row
        // together and the indicator is what yields.
        overlayAge.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        // ⚠️ Not `.label`, and not sampled from the picture either — see
        // `MediaDateInk`, which records why the sampling version was dropped.
        // A bare word on a photograph is held up by its halo, so the two are
        // set together and neither is meaningful alone.
        overlayAge.textColor = MediaDateInk.colour
        overlayAge.layer.shadowColor = MediaDateInk.halo.cgColor
        overlayAge.layer.shadowOffset = .zero
        overlayAge.layer.shadowRadius = MediaDateInk.haloRadius
        overlayAge.layer.shadowOpacity = MediaDateInk.haloOpacity

        // ONE NUMBER PER CHIP, not one chip with two numbers.
        //
        // Likes and comments are separate verbs — how many liked it, how many
        // said something — and a single capsule reading "♥ 160 💬 12" makes them
        // one fact about the post. Two chips also let the row breathe at the
        // leading edge the way the trailing date does.
        likesPill = PostMetaPillView(contents: [overlayReactions])
        commentsPill = PostMetaPillView(contents: [overlayComments])
        // ⚠️ A SLOT, not a pill: the date is bare text on a fading material.
        //
        // It keeps the row's rhythm and loses the capsule, because a capsule is
        // a claim that what is inside it can be pressed — true of the two
        // counters, never of a date. Everything that measured against this chip
        // still measures the same box.
        agePill = PostChipSlotView(contents: [overlayAge])

        likesPill.constrain(in: mediaView) { parent in
            likesPill.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor, constant: Self.mediaFurnitureInset
            )
            likesPill.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor, constant: -Self.mediaFurnitureInset
            )
        }
        commentsPill.constrain(in: mediaView) { parent in
            commentsPill.leadingAnchor.constraint(
                equalTo: likesPill.trailingAnchor, constant: Self.chipGap
            )
            commentsPill.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor, constant: -Self.mediaFurnitureInset
            )
        }
        agePill.constrain(in: mediaView) { parent in
            agePill.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor, constant: -Self.mediaFurnitureInset
            )
            agePill.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor, constant: -Self.mediaFurnitureInset
            )
        }
        // The page indicator sits BETWEEN the two, centred on the preview
        // rather than on the space left over — the row reads as three chips on
        // one baseline, and centring on the gap would slide it whenever a
        // counter gained a digit.
        // Centred on the age chip's CENTRE, not aligned to its bottom.
        //
        // The three chips are different heights — a row of 6pt dots is shorter
        // than a line of caption2 — so a shared bottom edge puts the short one's
        // mass below the others. What reads as "one row" is centres on a line,
        // which is also what survives Dynamic Type moving the text chips and not
        // the dots.
        //
        // Against the AGE chip because it is the one always on screen: a post
        // with no counters hides the leading chip, and hanging the indicator off
        // something that can disappear is how it ends up somewhere else.
        pageIndicator.constrain(in: mediaView) { parent in
            pageIndicator.centerYAnchor.constraint(equalTo: agePill.centerYAnchor)
            // ⚠️ The SAME HEIGHT as the text chips, not its own.
            //
            // A row of 6pt dots is shorter than a line of caption2, so a chip
            // sized by its contents came out visibly smaller than the three
            // beside it and the row stopped reading as a row. Tied to the date's
            // height rather than to a constant, so Dynamic Type moves all four
            // together.
            pageIndicator.heightAnchor.constraint(equalTo: agePill.heightAnchor)
        }
        // ⚠️ Centred BETWEEN the two groups, not on the preview.
        //
        // Centring on the preview looked like the same thing and is not: it
        // fixes the indicator's leading edge, which caps the room left of it at
        // half the preview regardless of what the counters need. Measured, with
        // the chips at control size: the comments count truncated to "…" while
        // 60pt of preview sat empty to the right of the dots.
        //
        // Two guides of equal width give the row the shape it was asked for —
        // counters, dynamic space, indicator, dynamic space, date. The SPACES
        // absorb the difference, so the counters take the width they need and
        // the indicator floats in what is left.
        let leadingSpace = UILayoutGuide()
        let trailingSpace = UILayoutGuide()
        mediaView.addLayoutGuide(leadingSpace)
        mediaView.addLayoutGuide(trailingSpace)
        NSLayoutConstraint.activate([
            leadingSpace.leadingAnchor.constraint(equalTo: commentsPill.trailingAnchor),
            leadingSpace.trailingAnchor.constraint(equalTo: pageIndicator.leadingAnchor),
            trailingSpace.leadingAnchor.constraint(equalTo: pageIndicator.trailingAnchor),
            trailingSpace.trailingAnchor.constraint(equalTo: agePill.leadingAnchor),
            // ⚠️ REQUIRED: the gaps are what keep the chips from overlapping, and
            // two capsules touching on a photograph reads as one broken shape.
            leadingSpace.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.chipGap),
            trailingSpace.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.chipGap),
            // And when there is no indicator at all, the counters still have to
            // stay off the date.
            agePill.leadingAnchor.constraint(
                greaterThanOrEqualTo: commentsPill.trailingAnchor, constant: Self.chipGap
            )
        ])
        // A ladder, because at the largest accessibility sizes four chips do not
        // fit across a preview and SOMETHING has to give. In order of what may
        // break first:
        //
        //   749  the indicator's two-dot floor — a shorter run of dots still
        //        says "there is more, you are here"
        //   900  the two spaces being equal — an off-centre indicator is a
        //        cosmetic loss, and it buys the counters real width
        //   999  the counts and the date themselves (set on the labels), which
        //        must never truncate: a clipped count is a WRONG count
        //
        // The gaps above sit above all three at required, so the failure mode is
        // always an indicator that gave way, never chips that overlap.
        let centred = leadingSpace.widthAnchor.constraint(equalTo: trailingSpace.widthAnchor)
        centred.priority = UILayoutPriority(900)
        let dotFloor = pageIndicator.widthAnchor.constraint(
            greaterThanOrEqualToConstant: pageIndicator.minimumChipWidth
        )
        dotFloor.priority = UILayoutPriority(749)
        NSLayoutConstraint.activate([centred, dotFloor])

        // The chip's width never changes now — five dots at any length, with
        // the window sliding under them — so there is nothing for this row to
        // make room for. It briefly grew under a finger instead, which moved
        // the dots the finger had just landed on: a control whose targets shift
        // when you touch it cannot be aimed, and every scrub began with a jump.
    }

    /// The carousel, built on first use — most posts have one piece of media and
    /// should not pay for a scroll view they will never scroll.
    ///
    /// Inserted BELOW the chips, and that is the layout's whole contract with
    /// them: the chips and the indicator belong to the PREVIEW, not to what is
    /// inside it. They are pinned to the box, the pages move underneath, and
    /// nothing about a drag can shift them. Putting them inside the scroll view
    /// would have been the natural way to write this and would have carried the
    /// counters off the screen with page two.
    private func makeCarouselIfNeeded() -> MediaCarouselView {
        if let carousel { return carousel }
        let view = MediaCarouselView()
        view.onPageChanged = { [weak self] page in
            guard let self else { return }
            self.pageIndicator.setCurrent(page)
            // ⚠️ The surface STAYS on its page. It used to be evicted here.
            //
            // Evicting put the page's thumbnail back the moment the viewer moved
            // on, and in a carousel that page is still on screen — so a clip
            // appeared to be replaced by a photograph while it was merely no
            // longer the one being watched. It is paused in place instead, and
            // keeps its last frame.
            //
            // Moving it is still handled: `install` re-hosts it when the viewer
            // arrives at a DIFFERENT clip, and `host` clears the page it came
            // from.
            self.onMediaPageChanged?(page)
        }
        // The indicator is a control, and the cell is what connects it: neither
        // half reaches the other, which is what keeps the carousel the only
        // thing that decides where the pages are.
        pageIndicator.onPageRequested = { [weak view] page in
            // ⚠️ NOT ANIMATED. The chip is a scrubber: the viewer's finger is
            // the clock, and an animation would run its own on top — a drag
            // across twelve pages would queue twelve scroll animations and
            // arrive late at every one of them. Teleporting keeps the page under
            // the finger where the finger is.
            view?.setPage(page, animated: false)
        }
        view.onTapped = { [weak self] in self?.onMediaTapped?() }
        mediaView.insertSubview(view, belowSubview: likesPill)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor),
            view.topAnchor.constraint(equalTo: mediaView.topAnchor),
            view.bottomAnchor.constraint(equalTo: mediaView.bottomAnchor)
        ])
        carousel = view
        return view
    }

    private func buildAuthorBand() {
        authorBand.constrain(in: card) { parent in
            authorBand.topAnchor.constraint(
                equalTo: parent.topAnchor, constant: Self.captionTopInset
            )
            authorBand.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor, constant: Self.captionInset
            )
            authorBand.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor, constant: -Self.captionInset
            )
        }
    }

    private func bindAuthorBand(to post: GalleryPost, imagePipeline: ImagePipeline) {
        let model = PostAuthorBandView.Model(post: post)
        showsAuthorBand = model != nil
        authorBand.isHidden = !showsAuthorBand
        captionAtCardTop.isActive = !showsAuthorBand
        captionFollowsBand.isActive = showsAuthorBand
        guard let model else {
            authorBand.cancelPendingWork()
            return
        }
        authorBand.configure(with: model, imagePipeline: imagePipeline)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // Hand the player back BEFORE anything else: a recycled row that kept
        // its loan would show the previous post's video under the new post's
        // cover. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        // Concealment is per-flight state and must not ride a recycled cell to
        // whatever post it is bound to next — the row equivalent of the tile's
        // `isHidden` reset.
        //
        // BOTH channels, because the routing depends on whether a carousel is
        // showing and that answer changes with the post: a row recycled from a
        // collection to a single photo would otherwise reset only the page it no
        // longer has, and keep the preview it now uses at alpha 0.
        setHeroMediaConcealed(false)
        mediaView.alpha = 1
        playBadge.alpha = 1
        loadTask?.cancel()
        loadTask = nil
        mediaView.image = nil
        // A recycled row must not keep the previous post's pages: the loads are
        // per-page tasks and the indicator is per-post state, and neither is
        // touched by `configure` for a post that turns out to have one piece of
        // media.
        carousel?.cancelPendingWork()
        carousel?.isHidden = true
        pageIndicator.isHidden = true
        onRevealFullCaption = nil
        // Back to truncated. A recycled row must not inherit the previous
        // post's expansion — `configure` re-applies the host's answer for the
        // post it is actually bound to.
        isCaptionExpanded = false
        captionLabel.numberOfLines = Self.captionLineLimit
        showMoreRange = nil
        // A landing's fade is per-flight state and must not ride a recycled
        // cell to whatever post it is bound to next.
        metaRow.alpha = 1
        authorBand.cancelPendingWork()
        // Both band handlers capture the POST they were built for, so a
        // recycled row must not keep them: the "..." would offer to unfollow
        // the previous post's author, and the identity would push their
        // profile.
        onAuthorTapped = nil
        authorMenuActions = nil
        onMediaTapped = nil
        // Both capture the POST they were built for, like the two above: a
        // recycled row would otherwise save someone else's post.
        onRepostTapped = nil
        onBookmarkTapped = nil
        isBookmarked = false
        // Concealment is per-FLIGHT state and must not ride a recycled cell to
        // whatever post it is bound to next — see `setHeroConcealed`.
        card.alpha = 1
        authorBand.alpha = 1
    }

    private func revealTapped() {
        guard !isCaptionExpanded else { return }
        isCaptionExpanded = true
        captionLabel.numberOfLines = 0
        showMoreRange = nil
        captionLabel.attributedText = Self.plain(fullCaption, font: captionLabel.font)
        onRevealFullCaption?()
    }

    @objc private func captionTapped() {
        revealTapped()
    }

    /// ⚠️ The recognizer must REFUSE every touch that is not on the affordance,
    /// not merely ignore it.
    ///
    /// A gesture recognizer on the label consumes taps on the label whether or
    /// not its action does anything, so a recognizer that simply returned early
    /// for a miss would make the caption — the largest thing on the card —
    /// stop opening the post. Refusing at `shouldBegin` leaves the touch to the
    /// collection view's own selection.
    public override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let range = showMoreRange, !isCaptionExpanded else { return false }
        return Self.characterIndex(
            at: gesture.location(in: captionLabel), in: captionLabel
        ).map { NSLocationInRange($0, range) } ?? false
    }

    /// Which character of the label's text is under `point`, laid out exactly
    /// as the label lays it out.
    ///
    /// TextKit rather than arithmetic on line heights: the affordance is the
    /// tail of a wrapped line, so its position depends on where the line broke,
    /// which only a real layout knows. The container is configured to match the
    /// label — zero padding, the label's line-break mode and line cap — because
    /// a container that differs in any of those breaks the text somewhere else
    /// and hit-tests a different string.
    ///
    /// Returns nil when the point is outside the laid-out glyphs, so a tap in
    /// the empty tail of the last line is a miss rather than the nearest
    /// character.
    private static func characterIndex(at point: CGPoint, in label: UILabel) -> Int? {
        guard let attributed = label.attributedText, attributed.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.lineBreakMode = label.lineBreakMode
        container.maximumNumberOfLines = label.numberOfLines
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        let index = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        // `glyphIndex(for:)` clamps to the nearest glyph, so a point past the
        // end of a line answers with that line's last character. Rejecting a
        // point outside the glyph's own rect is what turns that clamp back into
        // a miss.
        let glyphRect = manager.boundingRect(
            forGlyphRange: NSRange(location: index, length: 1), in: container
        )
        guard glyphRect.contains(point) else { return nil }
        return manager.characterIndexForGlyph(at: index)
    }

    public func configure(
        with post: GalleryPost, imagePipeline: ImagePipeline, captionExpanded: Bool = false
    ) {
        isCaptionExpanded = captionExpanded
        captionLabel.numberOfLines = captionExpanded ? 0 : Self.captionLineLimit
        fullCaption = post.caption
        bindAuthorBand(to: post, imagePipeline: imagePipeline)
        showMoreRange = nil
        // Provisional: the real composition needs the row's final width, which
        // only `preferredLayoutAttributesFitting` knows. Set here so a cell
        // that is never sized (a measuring instance) still reads correctly.
        captionLabel.attributedText = Self.plain(post.caption, font: captionLabel.font)
        let hasMedia = post.kind != .text
        mediaAspectRatio = post.aspectRatio
        // Provisional, on whatever width this cell currently carries — the
        // authoritative pass is `preferredLayoutAttributesFitting`. Set here so
        // a cell that is never measured (a stand-in, a preview) is not left
        // with a zero-height preview.
        resolveMediaHeight(atWidth: bounds.width)
        mediaView.isHidden = !hasMedia
        // A COLLECTION's badge belongs to the page, not to the box: with mixed
        // pages the box has no single answer, and a badge over the whole
        // preview would sit on a photograph as often as on a clip.
        playBadge.isHidden = post.kind != .video || post.isCollection
        // ⚠️ RE-ASSERTED, not assumed. A flight can be in the air while this
        // row is reconfigured, and everything above has just set the furniture
        // visible. Without this the badge lights up mid-dismissal.
        if isHeroMediaConcealed { setHeroMediaConcealed(true) }
        // The line and the pills are the same four values in two placements, so
        // exactly one of them is on screen. The line is hidden rather than
        // unconstrained: it keeps hanging off the caption under the preview,
        // drawing nothing, which is what stops a media row's layout from being
        // ambiguous while keeping the line out of the card's height.
        metaRow.isHidden = hasMedia
        metaClosesCard.isActive = !hasMedia
        NSLayoutConstraint.deactivate(hasMedia ? [] : mediaConstraints)
        NSLayoutConstraint.activate(hasMedia ? mediaConstraints : [])

        reactions.set(post.reactionCount)
        comments.set(post.commentCount)
        // A number the post does not have leaves an empty capsule on the card,
        // exactly as it would on a photograph.
        closingLikesPill.syncVisibilityToContents()
        closingCommentsPill.syncVisibilityToContents()
        views.set(post.viewCount)
        overlayReactions.set(post.reactionCount)
        overlayComments.set(post.commentCount)
        let age = PostMetadata.compactAge(ofMillis: post.publishedAtMS)
        ageLabel.text = age
        overlayAge.text = age
        // A number the post does not have leaves an empty capsule on the photo,
        // which is worse than no capsule — each chip answers for its own.
        likesPill.syncVisibilityToContents()
        commentsPill.syncVisibilityToContents()

        mediaView.image = nil
        mediaView.backgroundColor = post.kind == .video ? .darkGray : .tertiarySystemFill

        // A collection hands its pages to the carousel and stops here: the
        // box's own image view stays empty, which is what keeps a single-media
        // post on exactly the path it has always taken — same load, same video
        // surface, same cover.
        pageIndicator.configure(count: post.pages.count, current: 0)
        if post.isCollection {
            // The box behind the pages is the CARD, not the placeholder fill a
            // single-media row uses: with a gutter between pages and a sliver of
            // the next one at the edge, that fill is on screen at rest and has
            // to be the surface the pages are lying on.
            mediaView.backgroundColor = Self.cardFillColor
            let carousel = makeCarouselIfNeeded()
            carousel.isHidden = false
            carousel.configure(with: post.pages, imagePipeline: imagePipeline)
            return
        }
        carousel?.isHidden = true
        carousel?.cancelPendingWork()

        guard hasMedia, let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            mediaView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            guard let self else { return }
            UIView.transition(
                with: self.mediaView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.mediaView.image = image
            }
            // The row now has a face, which is the one thing the autoplay gate
            // was waiting for. Nothing else would ask again while the timeline
            // sits still.
            loadedVideoRenderView?.setPoster(image)
            onCoverLoaded?()
        }
    }
}

extension PostGridListRowCell: GridPlaybackCell {}

// MARK: - Media tile

/// One square of the Media grid: photo thumbnail, or video poster + badge,
/// with the compact counter pair (reactions, views) resting bottom-leading —
/// caption2 over a soft shadow, no scrim, so the preview stays the star.
public final class PostGridTileCell: UICollectionViewCell {
    public static let reuseID = "PostGridTileCell"

    /// The mosaic's rounding, and the default: it is paired with that layout's
    /// 1.5pt hairline gutter, where anything softer would leave visible pinches
    /// where four bricks meet.
    public static let mosaicCornerRadius: CGFloat = 10

    /// The brick's rounding, settable because the two grids that share this
    /// cell space their tiles differently — see
    /// `ChaoticSliceLayout.harmonisedGutter`. Gap and curve are one decision,
    /// so a surface that widens the gap sets this to match.
    public var cornerRadius: CGFloat = PostGridTileCell.mosaicCornerRadius {
        didSet { contentView.layer.cornerRadius = cornerRadius }
    }

    /// The image the brick is currently showing — see `PostGridListRowCell`'s
    /// note for why a hero reads this rather than the image pipeline.
    public var renderedCover: UIImage? { imageView.image }

    /// A tile IS its media, edge to edge, so the whole cell is the rect
    /// visibility is measured against.
    public var videoMediaRect: CGRect { bounds }

    /// A tile IS its media: if a surface exists it is showing the only thing
    /// this cell has.
    public var isRenderingCurrentMedia: Bool { loadedVideoRenderView != nil }

    /// The surface an autoplaying tile renders into, built on first use so a
    /// grid of stills never allocates a player layer it will not use.
    ///
    /// Not a `lazy var`: the coordinator needs to ask whether a cell *could* be
    /// playing (`loadedVideoRenderView`) without the question itself allocating
    /// the layer, which is exactly what touching a lazy var would do.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let loadedVideoRenderView { return loadedVideoRenderView }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "tile"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Above the still, below the badge and counters, so the furniture keeps
        // reading over moving video exactly as it does over a poster.
        contentView.insertSubview(view, aboveSubview: imageView)
        loadedVideoRenderView = view
        return view
    }

    /// The video surface if one was ever built, else nil — never allocates.
    public private(set) var loadedVideoRenderView: VideoRenderView?

    /// Installs a flight card's live surface as this tile's own, at landing.
    ///
    /// The view arrives already rendering, so the tile has nothing to wait for
    /// — the alternative is starting a fresh layer that is blank for ~100ms
    /// just as the card is removed, which is the flash at the end of a
    /// dismissal.
    public func adoptVideoRenderView(_ view: VideoRenderView) {
        if let existing = loadedVideoRenderView, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isHidden = false
        contentView.insertSubview(view, aboveSubview: imageView)
        loadedVideoRenderView = view
    }

    /// Gives up the live surface so a hero flight can fly the *same* layer.
    ///
    /// Mirroring — attaching the player to a second `AVPlayerLayer` — cannot be
    /// seamless, because a freshly attached layer has no decoded frame and
    /// reports `isReadyForDisplay == false` for ~100ms. Measured. Moving the
    /// view that is already rendering has no such window: same layer, same
    /// player, same frame, just a different superview.
    ///
    /// The cell drops its reference; a later play builds a fresh surface.
    public func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        view.removeFromSuperview()
        return view
    }

    /// Called when the collection view recycles this cell, so whoever loaned it
    /// a player takes it back. Mirrors `MapAnnotationView.onReuse`: a recycled
    /// cell that kept its player would render another post's video.
    public var onReuse: (() -> Void)?

    private let imageView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.postGridSystemFont(
        matching: .preferredFont(forTextStyle: .caption2), weight: .semibold
    )
    private let reactions = PostMetricLabel(
        symbol: "heart.fill", font: metaFont, color: .white, shadowed: true
    )
    private let views = PostMetricLabel(
        symbol: "eye.fill", font: metaFont, color: .white, shadowed: true
    )
    private var loadTask: Task<Void, Never>?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true
        // Soft bricks, not hard edges. `cornerRadius` re-applies this whenever
        // a host wants the softer pairing; the curve stays continuous either
        // way, which is what keeps a widened radius from reading as a stadium.
        contentView.layer.cornerRadius = cornerRadius
        contentView.layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.pin(to: contentView)

        // The badge sits over media of any brightness: a soft shadow instead
        // of a scrim keeps the thumbnail unobstructed.
        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: contentView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: 8)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8)
        }

        // Views lead, reactions follow — reach first, then resonance.
        let counters = UIStackView(arrangedSubviews: [views, reactions])
        counters.axis = .horizontal
        counters.spacing = 8
        counters.constrain(in: contentView) { parent in
            counters.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
            counters.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -7)
            counters.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -8)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // A recycled cell must come back VISIBLE. A hero flight hides the tile
        // it is flying from, and that hide lives on the cell — so a cell
        // recycled while hidden carries the invisibility to whatever post it is
        // next bound to, and nothing on the reuse path would ever put it back.
        // One tile lost per flight whose cell got recycled before its unhide,
        // which is what made the gallery thin out over repeated round trips.
        isHidden = false
        alpha = 1
        // Hand the player back BEFORE anything else: a recycled cell that kept
        // its loan would show the previous post's video under the new post's
        // still. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
    }

    /// Puts a cover on the tile immediately, without waiting for the async load
    /// that is already in flight to come back.
    ///
    /// Closes a race the autoplay gate would otherwise lose: `configure` asks
    /// the cache once, and if the image lands *after* that (from the prefetch)
    /// the cache has it while this cell is still showing nothing. A gate that
    /// consulted the cache would pass, and the tile would start playing with a
    /// blank face anyway — which is the exact failure the gate exists to
    /// prevent.
    public func applyCover(_ image: UIImage) {
        guard imageView.image == nil else { return }
        imageView.image = image
        loadedVideoRenderView?.setPoster(image)
    }

    /// Fired when the cover lands from an async load.
    ///
    /// Autoplay is gated on the cover being present, and the gate is evaluated
    /// by a reconcile that normally only runs on scroll. Without this, a tile
    /// whose cover arrives while the grid is sitting still would fail the gate
    /// once and never be asked again — it would simply never play.
    public var onCoverLoaded: (() -> Void)?

    /// Reveals the video surface once a player has been attached. The still
    /// stays underneath as the poster, so the first frame replaces it rather
    /// than flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(imageView.image)
        // The cover keeps the tile until there is video to replace it with.
        // Unhiding here put an empty surface over the cover for the whole
        // decode start-up — measured at ~1.2s on a cold tile — which is a tile
        // going dark at rest, before any transition is involved.
        view.revealOnFirstFrame()
        #if DEBUG
        // Whether the tile had a cover AT THE MOMENT playback started. Holding
        // the surface back is only worth anything if there is something behind
        // it; a nil here means the tile is black no matter what the renderer
        // does, and the fix belongs in the cover pipeline rather than here.
        if ProcessInfo.processInfo.arguments.contains("-avsbdl-log") {
            print(String(format: "[avsbdl] %.3f tile beginVideoPreview cover=%@",
                         CACurrentMediaTime(), imageView.image == nil ? "NIL" : "present"))
        }
        #endif
    }

    /// Back to a still tile.
    public func endVideoPreview() {
        // Faded, not switched off. This runs for every tile `beginHandoff`
        // stops as a flight leaves, and a binary hide snaps each of their
        // covers back in a single frame — several thumbnails popping at once,
        // on the grid, at exactly the moment the viewer is watching the flight.
        loadedVideoRenderView?.hideCrossFading()
    }

    public func configure(with post: GalleryPost, imagePipeline: ImagePipeline) {
        playBadge.isHidden = post.kind != .video
        // Video tiles keep a dark floor: their poster may be unrenderable
        // (or plain black in the simulator), and the glyph needs a stage.
        contentView.backgroundColor = post.kind == .video ? .darkGray : .secondarySystemBackground

        reactions.set(post.reactionCount)
        views.set(post.viewCount)

        imageView.image = nil
        guard let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            imageView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            guard let self else { return }
            UIView.transition(
                with: self.imageView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.imageView.image = image
            }
            // A tile can start playing before its cover arrives, and
            // `beginVideoPreview` reads the cover exactly once — so a cover
            // that lands afterwards never reached the surface, leaving it with
            // no poster to fall back on for the rest of its life. That is the
            // difference between a cold flight showing the thumbnail and
            // showing nothing.
            self.loadedVideoRenderView?.setPoster(image)
            self.onCoverLoaded?()
        }
    }
}

extension PostGridTileCell: GridPlaybackCell {}
