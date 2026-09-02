import CoreNavigation
import MediaPlayback
import PostGrid
import UIKit

/// The For You grid's hero card: what a mosaic brick looks like, as a
/// free-standing view the transition can fly.
///
/// The map pin can hand the hero its *actual* face (`PinCardView` is both the
/// pin and the card). A grid tile can't — its face is a `UICollectionViewCell`
/// the collection view owns and recycles — so this is a deliberate twin, and it
/// only stays a twin because it borrows the same constants from `PostGrid`
/// rather than restating them: the brick's 10pt continuous rounding, and the
/// counter overlay's glyphs, font and inset.
///
/// Layer order (bottom → top): cover image, DEPARTURE cover image, live video
/// surface, resting chrome (counters + play badge). The flight fades the resting
/// chrome out as the card leaves the grid and back in as it returns, so a landed
/// brick never pops its furniture on.
///
/// **Which half of the card belongs to which end of the flight.** The card's own
/// cover, its floor colour and its rounding are the TILE — the source end, and
/// `setZoomContentBlend`'s `t == 1`. The departure cover and the live surface are
/// both the PAGE at the other end (`t == 0`): on a dismissal the surface is the
/// picture the viewer is actually watching and the cover is that page's poster,
/// which is why the cover sits beneath it. Only the cover is in the FADE, though
/// — the surface owns its own alpha and needs no help covering the card, so the
/// blend leaves it alone (`applyBlend`). The counters and the play badge belong
/// to neither end.
final class PostGridFlightCard: UIView {
    /// Which surface the card is impersonating. The two pages present media
    /// differently, and a hero that flew from both with one set of constants
    /// would be a twin of neither.
    enum Style {
        /// A grid brick: the layout's tile corners, counters and badge overlaid
        /// on the media.
        case tile
        /// The preview inside a timeline row: 12pt corners, and NO counters —
        /// that row shows its metrics in a line *below* the media, so overlaying
        /// them on the flight would conjure furniture the source never had.
        case listMedia

        var cornerRadius: CGFloat {
            switch self {
            case .tile: PostGridFlightCard.tileCornerRadius
            case .listMedia: PostGridListRowCell.mediaCornerRadius
            }
        }

        var showsCounters: Bool { self == .tile }
        /// The play badge's inset, matched to each cell's own.
        var badgeInset: CGFloat {
            switch self {
            case .tile: 8
            case .listMedia: 10
            }
        }
    }

    /// Matches the rounding the For You grid gives its tiles, so the card is
    /// the brick's twin rather than its approximation.
    ///
    /// Sourced from the layout rather than restated as a literal: the card, the
    /// tile and the hoisted dismissal surface (`ForYouViewController`) all have
    /// to round identically, and three copies of one number is how they drift
    /// apart. Every flight this card serves departs from the For You grid — the
    /// profile gallery has no zoom source — so the chaotic layout's pairing is
    /// unconditionally the right one here.
    static let tileCornerRadius = ChaoticSliceLayout.harmonisedCornerRadius

    private let style: Style
    /// Whether a live surface has been adopted, tracked explicitly rather than
    /// inferred from `videoRenderView.isHidden`.
    ///
    /// `isHidden` used to carry both meanings at once, and they have since
    /// diverged: `VideoRenderView.revealOnFirstFrame()` keeps a surface hidden
    /// until it has a frame, so "hidden" now means "not ready YET" as well as
    /// "no media at all". Reading the flag for the second meaning made the card
    /// disown a surface it genuinely had — and `ZoomFlight` gates
    /// `prepareZoomLiveMediaForFlight` on this, which is what gives the surface
    /// its size. The card then flew a zero-sized layer over a dark background,
    /// which is a black frame at the moment the feed hands over.
    fileprivate var hasAdoptedLiveMedia = false
    private let imageView = UIImageView()
    /// The half of the blend that MOVES: everything the landing draws, above
    /// everything the departure draws (a donated live surface included), faded
    /// in as one unit. See the note where it is added.
    private let landingPane = UIView()
    /// The landing's still, at the bottom of the pane — the floor under a live
    /// surface that has not produced its first frame, and the whole operand
    /// when the landing has no clip.
    private let landingCoverView = UIImageView()
    /// The landing's own moving picture, when one could be joined.
    private weak var landingLiveView: UIView?
    /// The PAGE's cover — the blend's second operand, empty and hidden until a
    /// flight hands one in (`setDeparturePicture`).
    ///
    /// ABOVE the tile's cover because the blend only ever moves the alpha of
    /// whichever operand is on TOP and leaves the other fully opaque beneath it
    /// (see `applyBlend`). BELOW the live surface because on a dismissal that
    /// surface is the departing page's own moving picture and this is nothing
    /// but its poster — burying the video under a still would fly a frozen frame
    /// for the whole flight, which is the regression the live media work exists
    /// to prevent.
    private let departureCoverView = UIImageView()
    /// The floor the card rests on, kept so `applyContentFloor` can put it back.
    ///
    /// Not re-derivable from `backgroundColor`: the hot-adopt path clears that
    /// property, so by the time anything needs the resting value it is gone.
    private let restingBackground: UIColor
    /// Whether the card is flying a donated surface that ALREADY had a frame at
    /// adopt — the case that earns the transparent floor, and the only case
    /// `applyContentFloor` has to weigh the blend against.
    private var fliesHotLiveMedia = false
    /// The card's own surface, used when it has to mirror. Replaced by a
    /// donated one whenever the source can hand over the layer it is already
    /// rendering — see `adoptZoomLiveMediaView`.
    private(set) var videoRenderView: VideoRenderView = {
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "card"
        #endif
        return view
    }()
    /// The tile's furniture: the counter pair and the play badge, in one view
    /// so the flight can fade them as a unit.
    private let restingChromeView = UIView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.systemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold
    )
    private let reactions = PostMetricLabel(
        symbol: "heart.fill", font: metaFont, color: .white, shadowed: true
    )
    private let views = PostMetricLabel(
        symbol: "eye.fill", font: metaFont, color: .white, shadowed: true
    )

    init(post: GalleryPost, cover: UIImage?, style: Style) {
        self.style = style
        // Video bricks keep a dark floor, exactly as the tile cell does: the
        // poster may be unrenderable and the glyph needs a stage.
        restingBackground = post.kind == .video ? .darkGray : .secondarySystemBackground
        super.init(frame: .zero)
        #if DEBUG
        // Balanced in deinit: a card alive after its flight settled is the
        // hero census's `cards` count, asserted zero by the UI suites.
        ZoomDebugCensus.increment(ZoomDebugCensus.Key.flightCard)
        #endif
        clipsToBounds = true
        backgroundColor = restingBackground
        layer.cornerRadius = style.cornerRadius
        layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = cover
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)

        departureCoverView.contentMode = .scaleAspectFill
        departureCoverView.clipsToBounds = true
        // OPAQUE ground, and the same one the card rests on. An operand that is
        // see-through anywhere sums with the other to a half-drawn frame, which
        // is precisely what the fade law forbids; the matching ground also makes
        // the two letterbox identically at every size the card passes through.
        departureCoverView.backgroundColor = restingBackground
        departureCoverView.isHidden = true
        departureCoverView.frame = bounds
        departureCoverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(departureCoverView)

        videoRenderView.frame = bounds
        videoRenderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoRenderView.clipsToBounds = true
        videoRenderView.isHidden = true
        addSubview(videoRenderView)

        // ⚠️ ABOVE THE LIVE SURFACE, and that is the whole point of it existing.
        //
        // The blend used to be one channel: the departure on top, fading off to
        // reveal the card's own picture beneath. For two stills that reads as
        // the cross-dissolve it is. It reads as NOTHING when the departure is a
        // running video, because a donated surface sits above both operands and
        // covers them at every instant — so the landing simply appeared, whole,
        // in the frame the card was removed. Filmed, and predicted in writing by
        // `setDeparturePicture`'s own caller contract before it was.
        //
        // `PinCardView` solves this by fading its surface with the departure.
        // This card cannot: its surface arrives DONATED and already running,
        // and `VideoRenderView.revealOnFirstFrame` owns that alpha — two drivers
        // on one property is a defect this codebase has already lived through.
        //
        // So the moving half changes ends. The departure — cover or live
        // surface — stays whole underneath, and the LANDING rises over it. That
        // is also the rule stated for every transition on this screen: never
        // fade the source, fade the destination in over it. One mechanism now
        // serves the still case and the video case, and nothing writes the
        // surface's alpha.
        // ⚠️ A PANE, not a bare image view, and the reason is the alpha.
        //
        // The rising operand has to be able to be a live PLAYER: a landing that
        // is a clip deserves the clip, not a thumbnail of it. But a live
        // surface's alpha belongs to `revealOnFirstFrame`, so the blend cannot
        // move it. Fading a CONTAINER moves both operands as one and touches
        // neither's own alpha — the still underneath covers the instant before
        // the surface has a frame, and the two rise as a single opaque unit.
        landingPane.backgroundColor = restingBackground
        landingPane.isUserInteractionEnabled = false
        landingPane.clipsToBounds = true
        landingPane.isHidden = true
        landingPane.alpha = 0
        landingPane.frame = bounds
        landingPane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(landingPane)

        landingCoverView.contentMode = .scaleAspectFill
        landingCoverView.clipsToBounds = true
        // Opaque, and on the same ground as the other operand, so the two
        // letterbox identically at every size the card passes through.
        landingCoverView.backgroundColor = restingBackground
        landingCoverView.image = cover
        landingCoverView.frame = landingPane.bounds
        landingCoverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        landingPane.addSubview(landingCoverView)

        restingChromeView.isUserInteractionEnabled = false
        restingChromeView.frame = bounds
        restingChromeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(restingChromeView)

        playBadge.tintColor = .white
        // ⚠️ THE CARD WEARS WHAT THE ROW WORE, and the two rules had drifted.
        //
        // The row hides its badge for a collection AND the flight fades its
        // furniture out — but this card's rule was `kind != .video` alone, so a
        // single-video post flew with a play badge lit in the transition window
        // while a collection flew without one. Reported as the badge appearing
        // during a dismissal, on single media only.
        //
        // A timeline row shows no furniture on the card at all — the note on
        // `showsCounters` states the reason and it applies to the badge for
        // exactly the same reason: conjuring furniture the flight never had is
        // the defect, whichever piece it is.
        playBadge.isHidden = post.kind != .video || post.isCollection || !style.showsCounters
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: restingChromeView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: style.badgeInset)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -style.badgeInset)
        }

        guard style.showsCounters else { return }
        reactions.set(post.reactionCount)
        views.set(post.viewCount)
        let counters = UIStackView(arrangedSubviews: [views, reactions])
        counters.axis = .horizontal
        counters.spacing = 8
        counters.constrain(in: restingChromeView) { parent in
            counters.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
            counters.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -7)
            counters.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -8)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if DEBUG
    deinit {
        ZoomDebugCensus.decrement(ZoomDebugCensus.Key.flightCard)
    }
    #endif

    // MARK: - Departure blend

    /// How far the card has blended toward its OWN content: 0 draws the page's
    /// picture, 1 the tile's.
    ///
    /// 1 at rest, because a card that was never handed a departure picture is
    /// only ever the tile.
    private var blend: CGFloat = 1

    /// Hands the card the picture at the OTHER end of the flight, as the blend's
    /// second operand. The card keeps drawing the tile's cover; this only gives
    /// the blend something to draw against.
    ///
    /// It exists because a grid tile is a doorway into a PAGING feed, so the two
    /// ends of a flight are routinely not the same picture — page five posts on
    /// and dismiss and the card opens on a cover the viewer last saw five posts
    /// ago, cut in at full screen. `ForYouGridZoomSource` re-points its anchor to
    /// close that gap; `ExternalHeroZoomSource` deliberately cannot, and even the
    /// re-pointing one falls back to the departure tile whenever the landed post
    /// cannot be flown to.
    ///
    /// `nil` means there is no second operand: the channel goes inert and the
    /// card renders exactly as it did before this existed, byte for byte,
    /// transparent floor included. That is how the row of the product rule that
    /// must NOT blend gets there — one picture at both ends, which a blend could
    /// only soften.
    ///
    /// An operand that is not a photograph is still fine as long as it is an
    /// opaque IMAGE: a text page can hand in the flat ground it was drawn on and
    /// the fade runs from that colour to the tile. What must never arrive here is
    /// its TEXT — blending two runs of text draws both of them, which is the law
    /// this whole channel is built around.
    ///
    /// ⚠️ CALLER CONTRACT: this is the picture a card flies when it has no LIVE
    /// one. A card that is still holding a live surface at the landing lands on
    /// the page's moving picture rather than on the tile's cover, because the
    /// surface covers the card at every instant and the blend cannot fade it —
    /// see `applyBlend`. That is the right answer where the landing tile adopts
    /// that very surface (`ForYouGridZoomSource.zoomAdoptLiveMediaView`), and it
    /// is unchanged behaviour everywhere else; what it is not is something this
    /// channel can be asked to fix.
    ///
    /// So a picture handed in here is never WRONG — the donation may arrive
    /// after staging, and the caller cannot know at staging whether it will —
    /// but it is only ever SEEN on a card that ends up without live media, which
    /// includes the hoisted dismissal, where the host flies the page's surface
    /// itself and leaves this card holding nothing.
    func setDeparturePicture(_ image: UIImage?) {
        departureCoverView.image = image
        departureCoverView.isHidden = image == nil
        // The landing operand exists only opposite a departure one. Hidden
        // rather than merely transparent, so a card with nothing to blend has
        // exactly the subview tree it had before this channel existed.
        landingPane.isHidden = image == nil
            || (landingCoverView.image == nil && landingLiveView == nil)
        if image == nil { departureBaseSize = nil }
        // Autoresizing and a transform do not compose; from here the cover is
        // posed by hand — see `DepartureCoverLayout`.
        departureCoverView.autoresizingMask = []
        setNeedsLayout()
        applyContentFloor()
        applyBlend()
    }

    /// The departure size carried between layout passes — see
    /// `DepartureCoverLayout.apply`, which owns what it means.
    private var departureBaseSize: CGSize?

    /// ⚠️ THE SAME RULE THE MARKER'S CARD USES, and it belongs here for a
    /// reason that only became visible once a video page could hand over a
    /// picture at all.
    ///
    /// A tile's aspect is close to a page's, so re-cropping this cover every
    /// frame has never been filmed on this card — the crop it recomputes is
    /// almost the crop it had. That is a property of the pictures that have
    /// reached it so far, not of the code: it is the defect
    /// `DepartureCoverLayout` documents, one page shape away from showing.
    override func layoutSubviews() {
        super.layoutSubviews()
        departureBaseSize = DepartureCoverLayout.apply(
            to: departureCoverView, in: bounds, departureBase: departureBaseSize
        )
        // ⚠️ POSED, NOT AUTORESIZED, and the zero case is why.
        //
        // A card can be built before it has any bounds — the flight builds one
        // at staging and another for the animator — and autoresizing from 0x0
        // stays 0x0 for ever: the deltas it scales are all zero. Measured as a
        // landing operand installed into `pane={{0,0},{0,0}}`, which draws
        // nothing at any blend. Every pose calls this method, and `layoutSubviews`
        // is where a resting card gets one, so both do it.
        landingPane.frame = bounds
        landingCoverView.frame = landingPane.bounds
        landingLiveView?.frame = landingPane.bounds
    }

    /// The blend channel: `t == 0` is the page's picture, `t == 1` the tile's.
    /// Alpha-only, so calling this inside an animation block sweeps it with the
    /// rest of the flight.
    ///
    /// ⚠️ DELIBERATELY DISJOINT FROM `zoomRestingChrome`. That channel is the
    /// flight's own, it owns the counters and the play badge, and it runs on a
    /// different clock on purpose — `ZoomFlight.poseInterpolated` excludes the
    /// chrome alphas and swaps them inside the release spring instead. A blend
    /// riding it would drag the counters onto the pictures' clock and vice versa.
    func setBlend(_ t: CGFloat) {
        blend = min(max(t, 0), 1)
        applyBlend()
    }

    /// Applies `blend` to the page operand, which is always the one on top.
    ///
    /// ⚠️ EXACTLY ONE operand's alpha ever moves; the tile's cover stays fully
    /// opaque underneath it. That is the whole argument for why this blend is
    /// allowed where the flight's other fades are not. Two half-drawn layers over
    /// the card's floor is the "two half-drawn overlays" that
    /// `ZoomFlight.poseInterpolated` rules out for the chrome alphas and that
    /// `RevealTransition`'s window law rules out for the caption. With one opaque
    /// operand behind, every intermediate frame is an opaque sum of two
    /// photographs — a whole picture, never two transparent ones.
    ///
    /// ⚠️ THE COUNTERS AND THE BADGE ARE IN NEITHER OPERAND, and the counters are
    /// why. They are a run of TEXT over the media, and text is exactly what the
    /// fade law is about; they are also the TILE's furniture rather than a
    /// picture of anything, so there is no page-side half for them to cross-fade
    /// against. They keep the owner they already have — `zoomRestingChrome`,
    /// posed by the flight. `.listMedia` has no furniture at all: a timeline
    /// row's caption, author line and metrics are drawn by the row BELOW the
    /// media and the card never carries them, which is what leaves both styles
    /// with two pictures and nothing else to blend.
    ///
    /// ⚠️ AND THE LIVE SURFACE IS NOT IN THE FADE, which is where this card and
    /// `PinCardView` genuinely differ rather than merely being spelt differently.
    /// The pin's surface only ever arrives by mirroring, so nothing but the pin
    /// writes its alpha; this card's arrives donated and already running, through
    /// `VideoRenderView.revealOnFirstFrame` — a mechanism whose entire job is to
    /// OWN that alpha, holding it at 0 until a frame exists and taking it to 1 in
    /// a two-frame cross-fade the instant one lands. That moment is not the
    /// card's to schedule, so a blend writing the same property would be two
    /// drivers on one layer: the defect `zoomLiveMediaSurface` already records
    /// for `frame`, in `alpha`.
    ///
    /// It also does not need to be. A surface is laid out to cover the card at
    /// every instant of the morph, so while it draws it IS the page operand, and
    /// the cover fading underneath it is simply not on screen. The consequence is
    /// a caller's to weigh, not this method's — see `setDeparturePicture`.
    private func applyBlend() {
        // No second operand: back to the resting value, which is the un-blended
        // card exactly as it was.
        guard departureCoverView.image != nil,
              landingCoverView.image != nil || landingLiveView != nil
        else {
            departureCoverView.alpha = 1
            landingPane.alpha = 0
            return
        }
        // ⚠️ THE DEPARTURE DOES NOT MOVE. It is the picture the viewer is
        // holding, and a transition that fades it is a transition that passes
        // through a frame of neither picture. The landing rises over it instead
        // — over the live surface too, since `landingCoverView` is above that.
        //
        // `blend` means the same thing it always did: 1 is the card's OWN
        // content, 0 is the picture at the other end. So this is the card's own
        // picture arriving, on both legs, by construction.
        departureCoverView.alpha = 1
        landingPane.alpha = blend
    }

    /// The landing's own moving picture, installed at the TOP of the pane so it
    /// covers the still while it draws — and its alpha left strictly alone, for
    /// the reason `ZoomFlightCard.setZoomLandingLiveMedia` states.
    func setZoomLandingLiveMedia(_ view: UIView) {
        guard view !== landingLiveView else { return }
        landingLiveView?.removeFromSuperview()
        landingLiveView = view
        view.frame = landingPane.bounds
        // Autoresizing AND the explicit pose: autoresizing carries it when the
        // pane is resized directly, the pose carries it when the card is built
        // before it has bounds and only the flight ever gives it any.
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.clipsToBounds = true
        landingPane.addSubview(view)
        // Re-derived rather than assigned: the landing operand and the departure
        // picture arrive independently, and whichever lands second decides.
        landingPane.isHidden = departureCoverView.image == nil
        applyBlend()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f card LANDING LIVE installed pane=%@",
                         CACurrentMediaTime(), NSCoder.string(for: landingPane.bounds)))
        }
        #endif
    }

    /// Whether the card draws anything of its own beneath the page operand.
    ///
    /// A card flying an already-rendering surface is deliberately transparent
    /// under it: the surface's content rides outside the CATransaction, so its
    /// first composite can lag its commit by a pass, and an opaque cover or floor
    /// under it turns that pass into a visible content blink — the landing tile's
    /// stale cover drawn over the still-live source (video → cover → video).
    ///
    /// A departure picture cancels that, because it removes the reason. What sits
    /// under the surface then is the PAGE's own poster rather than the tile's
    /// cover, so the lagging pass shows the picture already in flight instead of
    /// a foreign one — and the blend positively requires an opaque floor, since
    /// fading the page operand off a transparent card lands on a hole.
    private func applyContentFloor() {
        let isOpaque = departureCoverView.image != nil || !fliesHotLiveMedia
        imageView.isHidden = !isOpaque
        backgroundColor = isOpaque ? restingBackground : .clear
    }
}

// MARK: - ZoomFlightCard

extension PostGridFlightCard: ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { style.cornerRadius }


    var zoomRestingChrome: UIView? { restingChromeView }

    /// The live surface, but ONLY while this card still contains it.
    ///
    /// A dismissal hoists the surface out of the card and into a host above the
    /// navigation controller, and from that moment the host owns its geometry.
    /// Reporting it here anyway meant the flight kept posing it too: `poseAtSource`
    /// sets `center` in CARD-LOCAL coordinates, which for a ~130pt tile is about
    /// (65, 65) — the top-left of the SCREEN once the view lives in the host's
    /// space. That is the landscape media's jump to the left at frame 0.
    ///
    /// The two drivers also fought over the same layer: setting `frame` (the
    /// host) on a view with an in-flight `transform` animation (the card) is
    /// undefined, and it showed — a probe caught `position` AND `position-2`
    /// stacked on one layer, with `bounds` inflating 406->752 while the card
    /// was shrinking toward the tile.
    ///
    /// The invariant is the fix: a card poses only the media it actually holds.
    var zoomLiveMediaSurface: UIView? {
        guard hasAdoptedLiveMedia, videoRenderView.isDescendant(of: self) else { return nil }
        return videoRenderView
    }

    var zoomLiveMediaNativeSize: CGSize? { videoRenderView.nativeVideoSize }

    /// True when the card has no live media (the cover is the content and is
    /// always drawing), or when the live surface it adopted is genuinely
    /// visible and rendering. False is the interesting answer: it means the
    /// cover underneath is what the viewer is looking at.
    var zoomLiveMediaIsDrawing: Bool {
        hasAdoptedLiveMedia ? videoRenderView.isRenderingVisibly : true
    }

    /// ⚠️ THE REQUIREMENT IS PRODUCTION, THE DETAIL IS NOT.
    ///
    /// `ZoomFlightCard.zoomLiveMediaDebugState` is an unconditional protocol
    /// requirement — pinned by `ZoomExistentialDispatchTests`, because a
    /// diagnostic that answers the DEFAULT for every real card is a diagnostic
    /// that lies. So this must exist in every configuration. What must not is
    /// `VideoRenderView.debugSurfaceState`, which is a debug affordance and
    /// stays behind its own fence; Release keeps the half of the answer that
    /// costs nothing.
    var zoomLiveMediaDebugState: String {
        guard hasAdoptedLiveMedia else { return "no live media" }
        #if DEBUG
        return videoRenderView.debugSurfaceState
        #else
        return "live media"
        #endif
    }

    /// A grid tile never previews live, so this only ever fires on the dismiss
    /// leg — the feed's playing page mirrors its player here, and the card
    /// carries the live video home instead of a frozen cover.
    /// Takes ownership of a surface that is ALREADY rendering, swapping it in
    /// for the card's own.
    ///
    /// Preferred over `adoptZoomLiveMedia`, and the difference is the whole
    /// point: mirroring builds a second `AVPlayerLayer`, which has no decoded
    /// frame and stays `isReadyForDisplay == false` for ~100ms, so the card
    /// shows its static poster while the source is already hidden. Adopting the
    /// live view moves the layer that is mid-playback, so frame 0 of the flight
    /// is a real video frame.
    ///
    /// No poster is set here: the surface is already showing video, and a
    /// poster would only be a chance to flash.
    func adoptZoomLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        videoRenderView.removeFromSuperview()
        videoRenderView = view
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.clipsToBounds = true
        // ABOVE the page operand, never merely above the tile's cover: the
        // surface IS that operand in motion and this cover is only its poster.
        insertSubview(view, aboveSubview: departureCoverView)
        hasAdoptedLiveMedia = true
        // A card flying a surface that ALREADY HAS A FRAME must be
        // transparent beneath it. The surface's content rides outside the
        // CATransaction, so its first composite can lag its commit by a pass
        // — and an opaque cover or floor under it turns that pass into a
        // visible content blink: the stale cover drawn over the still-live
        // source (video → cover → video). Transparent, the same pass shows
        // the source THROUGH the card at the same rect — continuity instead
        // of a flash. A COLD surface keeps the cover: there is no video
        // anywhere yet, so the cover is the content, exactly as on a card
        // with no live media at all.
        //
        // Latched rather than assigned, and re-derived rather than applied
        // here: a departure picture may be handed in on either side of this
        // call, and `applyContentFloor` is what decides between the two of
        // them whichever order they arrive in.
        if view.hasFrame { fliesHotLiveMedia = true }
        applyContentFloor()
        // Not `isHidden = false`. On a cold flight this surface has no frame
        // yet, and showing it would replace the cover — the very pixels the
        // tile is displaying — with an empty surface for one decode interval.
        // The cover stays until there is real video to put over it.
        view.revealOnFirstFrame()
        #if DEBUG
        view.debugTracksFlight = true
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            // Full state at adopt. `frames=0` says it was never primed;
            // `hidden=Y frames>0` says something hid it after; anything else
            // points at a later detach.
            // Geometry too: a subview inserted with a zero frame renders at
            // the origin, which is what a ghost at the top-left corner is.
            print(String(format: "[zoom-live] %.3f card ADOPTED LIVE VIEW %@ cardBounds=%@ surfaceFrame=%@",
                         CACurrentMediaTime(), view.debugSurfaceState,
                         NSCoder.string(for: bounds), NSCoder.string(for: view.frame)))
        }
        #endif
    }

    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        guard mirror(videoRenderView) else { return }
        hasAdoptedLiveMedia = true
        videoRenderView.setPoster(imageView.image)
        videoRenderView.isHidden = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f card attached readyNow=%@",
                         CACurrentMediaTime(), videoRenderView.isReadyForDisplay ? "true" : "false"))
        }
        #endif
    }

    func setZoomCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
    }

    /// The tile is the flight's `t == 1` end and the page's picture its `t == 0`
    /// end, which is already what `setBlend` means — the tile is the arrival on a
    /// dismissal and the departure on a present, but either way "1" is the card's
    /// own content and "0" is the picture at the other end.
    ///
    /// Inert until a departure picture has been handed in, so every flight that
    /// does not need a blend is untouched by this.
    func setZoomContentBlend(_ t: CGFloat) {
        setBlend(t)
        // Posed from inside the flight's animation block — see the note on the
        // marker card's own `setZoomContentBlend`. A deferred `layoutSubviews`
        // is not an animation, and this is the only hook every pose runs.
        departureBaseSize = DepartureCoverLayout.apply(
            to: departureCoverView, in: bounds, departureBase: departureBaseSize
        )
        // ⚠️ POSED, NOT AUTORESIZED, and the zero case is why.
        //
        // A card can be built before it has any bounds — the flight builds one
        // at staging and another for the animator — and autoresizing from 0x0
        // stays 0x0 for ever: the deltas it scales are all zero. Measured as a
        // landing operand installed into `pane={{0,0},{0,0}}`, which draws
        // nothing at any blend. Every pose calls this method, and `layoutSubviews`
        // is where a resting card gets one, so both do it.
        landingPane.frame = bounds
        landingCoverView.frame = landingPane.bounds
        landingLiveView?.frame = landingPane.bounds
    }

    /// The surface fills the card and resizes with it, so `resizeAspectFill`
    /// recomputes the crop on every frame of the morph.
    ///
    /// This replaces a page-sized surface driven by a uniform scale. That
    /// approach renders the PAGE's crop no matter what shape the card currently
    /// is: against a 402x874 page, a 2:1 landscape brick showed only 22.9% of
    /// the surface vertically, so takeoff jumped from the tile's wide
    /// aspect-fill to a thin band of a page-shaped video. A 1:2 portrait brick
    /// showed 92.3% and looked fine — which is why the jump read as
    /// landscape-only.
    /// FALSE: the surface is laid out once at destination size and driven by
    /// a uniform-scale transform, the same path the map pin uses.
    ///
    /// It was true, so the flight resized the surface's bounds instead. The
    /// surface's FRAME tracked the card perfectly under that — measured
    /// per-frame off the presentation layer — but an
    /// `AVSampleBufferDisplayLayer` does not re-render its video rect during an
    /// ANIMATED bounds change: inside a correctly sized, correctly centred
    /// surface the content stayed drawn at its previous size, pinned to the
    /// layer origin. On screen that is the media unveiling from its top-left
    /// corner rather than zooming, which is exactly what was reported.
    ///
    /// Core Animation DOES interpolate layer content under a transform, so the
    /// scale path renders smoothly at every intermediate size.
    ///
    /// **The trade this re-accepts.** A page-sized surface under a uniform
    /// scale renders the PAGE's crop whatever shape the card currently is:
    /// against a 402x874 page a 2:1 landscape brick shows only 22.9% of the
    /// surface vertically. That is why this was flipped to true originally.
    /// `PostGridSliceArrangement` keeps that crop small by placing each clip in
    /// the block whose aspect is nearest its media, so the flight travels the
    /// page's own aspect — which is what makes this affordable again.
    ///
    /// The chaotic layout narrows the range this has to survive as well as
    /// matching within it: BSP blocks are scored toward 3:4 … 4:3, so there is
    /// no 2:1 brick left to produce the worst case above. The trade is that
    /// there is no 1:2 brick either, so a 9:16 clip cannot be matched as tightly
    /// as the old mosaic matched it — verify takeoff on portrait video before
    /// trusting this comment.
    var zoomLiveMediaTracksCardBounds: Bool { false }

    /// Lays the surface out ONCE at destination size, with autoresizing off so
    /// nothing else moves it. The flight owns its transform and centre from
    /// here; the layer's bounds never change again, which is what keeps the
    /// content rendering smoothly across the morph.
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        videoRenderView.transform = .identity
        videoRenderView.autoresizingMask = []
        videoRenderView.bounds = CGRect(origin: .zero, size: destinationSize)
    }

    // `applyZoomRestingShadow` is left at its default no-op: mosaic bricks rest
    // flat against their neighbours with only a hairline gutter between them,
    // so a drop shadow at the source end would appear from nowhere. The pin
    // needs one because it floats above a map; this does not.
}
