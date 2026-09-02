import UIKit

/// **THE TEXT REVEAL**. A hero for a page that has no media to fly.
///
/// Every previous attempt at a text hero flew a *replica* of the row and made
/// it impersonate the destination, and all five of them died of the same
/// thing: a text page IS its comment stream — a hosted child controller with
/// its own self-sizing layout and its own safe area — and no stand-in can be
/// that. The artifacts were the symptoms (a skeleton in the photographed
/// still, a blank card, the wrong safe area, two captions, a caption floating
/// outside the card as it shrank); impersonation was the disease.
///
/// So this does not impersonate anything. The REAL destination is installed at
/// full size and laid out before the first frame, and what animates is the
/// *mask* it is seen through: a rounded rect that sweeps from the row's rect
/// to the whole screen. There is nothing to keep in step with the page,
/// because the thing on screen is the page.
///
/// ```
///   t=0                    t=0.5                  t=1
///   ┌───────────┐          ┌───────────────┐      ┌──────────────────┐
///   │ caption…  │  ──────► │ caption…      │ ───► │ caption…         │
///   └───────────┘          │ ▸ comment     │      │ ▸ comment        │
///    row-sized mask        └───────────────┘      │ ▸ comment        │
///    over the real page     the mask opens        └──────────────────┘
/// ```
///
/// Two channels ride one spring — the mask's `frame`/`cornerRadius`, and the
/// page's `transform`. Neither touches the page's layout, which is what keeps
/// the caption exactly where it was measured (see `RevealStage`).
///
/// A screen a CARD-SHAPED close can land on, asked for the shape of that
/// landing.
///
/// It exists because the surface that stages the close and the surface it
/// lands on can be in different features: the map presents a cluster's feed
/// and has to give it a dismissal, but the landing is the Feed package's
/// place page, which Maps cannot name. The one thing Maps needs from it — a
/// geometry — is already a CoreNavigation type, so the seam belongs here
/// beside it rather than in either feature.
///
/// `nil` means "nothing to land on", which is how the caller selects the
/// plain slide instead.
@MainActor
public protocol CardCloseLanding: AnyObject {
    /// The window's landing, staged and measured. `feed` is the screen being
    /// dismissed, so the landing can ask it what it settled on.
    func cardCloseGeometry(dismissing feed: UIViewController) -> RevealGeometry?

    /// Undo whatever the staging concealed. Called on completed pops only —
    /// by then the landing is on screen and anything still hidden is a bug.
    func clearLandingConcealment()
}

@MainActor
public struct RevealGeometry {
    /// The rect the window opens from / closes onto, in the given space.
    /// `nil` means the source is not on screen — the reveal falls back to a
    /// centred window, the same concession the hero makes.
    public let sourceFrame: (UICoordinateSpace) -> CGRect?
    /// The source's own rounding, so the mask starts as the row's twin.
    public let sourceCornerRadius: CGFloat
    /// The source's own FILL, worn by the destination for the length of the
    /// reveal and cross-faded back to the page's own ground.
    ///
    /// Geometry alone does not make a handshake. The mask was measured exactly
    /// on the card's rect — 16pt in, 370 wide, 18pt corners — and the opening
    /// still read as a full-width band, because what showed through it was the
    /// PAGE's ground (`.systemBackground`) where the card's
    /// (`.secondarySystemBackground`) had been. Two tones, one rect, no edge:
    /// the card appeared to vanish at the instant it was supposed to grow.
    ///
    /// `nil` leaves the destination's ground alone, which is the behaviour for
    /// a source that has no fill of its own to lend.
    public let sourceFill: UIColor?
    /// How far below the SOURCE's top its own caption ends, when that caption
    /// is truncated — `nil` when the source shows the whole thing.
    ///
    /// This is the number that makes a collapsed card openable without a cut.
    /// Measured on an iPhone SE: a card whose caption is capped at four lines
    /// is 145pt tall, while the page's caption row for the same post is 299 —
    /// so 154pt of the destination has no counterpart in the source at all,
    /// and the mask slices straight through it. Worse than the slicing, the
    /// source spends its last ~44pt on its metric line while the destination
    /// has text there, so the final frame swaps words for furniture.
    ///
    /// Below this offset the destination is VEILED for the length of the
    /// flight, so the window shows what the card shows — the same four lines —
    /// and the card's own closing line arrives into empty space rather than
    /// over a sentence.
    public let sourceCaptionEnd: CGFloat?
    /// Puts the veil on the destination at `cut` (in the destination's own
    /// coordinates), or takes it away with `nil`.
    public let installDestinationVeil: (CGFloat?, UIColor?) -> Void
    /// The veil's opacity. Driven inside the flight's animation block, so it
    /// lifts as the page opens and returns as it closes — and scrubs with a
    /// finger on the dismissal.
    public let setDestinationVeilOpacity: (CGFloat) -> Void
    /// Puts the SOURCE's author band into the destination, given the page's
    /// caption ANCHOR to place it against — or takes it away with `nil`.
    ///
    /// The anchor rather than a y, because turning one into the other needs the
    /// card's own insets, and those live in PostGrid where this does not.
    ///
    /// The strip above a card's caption is the one part of the window that
    /// never matched: a card names its author there and a page does not. Drawn
    /// into the page, the window shows what the card shows from frame 0 and the
    /// landing swap is the identity rather than a dissolve.
    public let installDestinationAuthorBand: (CGRect?) -> Void
    /// The band's opacity, on the same channel as the veil's — full when the
    /// window is the card, gone when the page is itself.
    public let setDestinationAuthorBandOpacity: (CGFloat) -> Void
    /// Lends the destination a ground, or hands its own back with `nil`.
    ///
    /// Driven rather than composited, and that is deliberate: an overlay in
    /// the card's colour would have to sit ABOVE the page to tint it, which
    /// puts it above the caption too — and the caption is the one thing that
    /// must be legible from the first frame. Painting the page's own ground
    /// has no such problem, cross-fades natively (`backgroundColor` is
    /// animatable), and scrubs under a finger.
    public let setDestinationGround: (UIColor?) -> Void
    /// Where the destination's caption bubble sits on the FULL-SIZE page.
    /// Matched mode aligns this with the source rect at t=0; `nil` (or plain
    /// mode) leaves the page unmoved and the window simply opens over it.
    public let anchorFrame: (UICoordinateSpace) -> CGRect?
    /// Builds the stand-in a DISMISSAL carries home — the card itself, drawn
    /// fresh, rather than the page seen through a window.
    ///
    /// It exists because the page stops being usable as its own hero the moment
    /// its comments are scrolled: the caption moves, often off screen, and a
    /// window aligned to it either carries the wrong rows home or drags the
    /// whole stream across the display to fetch the right ones. Neither is a
    /// transition. See `RevealDismissCardView`.
    ///
    /// `nil` keeps the old behaviour — the page itself, registered — which is
    /// still correct for a surface that cannot draw a stand-in.
    public let makeDismissStandIn: () -> UIView?
    /// Builds what the OPENING starts as, for a source whose content the page
    /// does not repeat — and the reason this leg needed one at all.
    ///
    /// A row does not: its caption IS the page's caption, so the window can
    /// show the real page from frame 0 and be showing the right thing. That is
    /// the premise the whole transition was built on, and it holds for a row.
    ///
    /// A map's marker is a glyph on a tinted disc, and the page has no glyph
    /// anywhere. Opened without a stand-in, the disc becomes a 44pt porthole
    /// onto the page's top-left corner — a window onto something the viewer
    /// never tapped. So the marker is drawn fresh, the window opens as IT, and
    /// the two channels hand over in the same order the dismissal uses,
    /// reversed: the glyph goes first, then the fill it sits on, revealing the
    /// page that was underneath the whole time.
    ///
    /// `nil` keeps the row's behaviour, which is the default.
    public let makePresentStandIn: () -> UIView?
    /// How far below the SOURCE's top edge its caption begins — zero for a card
    /// that shows only its caption, the author band plus its gap for one that
    /// names its author. See `RevealStage.pageTranslation`.
    public let sourceCaptionTop: CGFloat
    /// Hide the row the window was taken FROM, for as long as it is in the air.
    ///
    /// The reveal can leave the row in place while the window sits exactly on
    /// it, because the two are showing the same thing — which is how this
    /// shipped, and why nobody noticed. A GRAB moves the window off that spot,
    /// and then the row underneath is a second copy of the post the viewer
    /// believes they are holding. What should read as picking a card up reads
    /// as photocopying it.
    ///
    /// So the source is concealed for the flight's whole length and restored
    /// when it lands — the same bargain the hero strikes with
    /// `ZoomTransitionSource.setZoomSourceHidden`, and for the same reason.
    /// Restored a beat BEFORE the window is retired, never after: the two are
    /// identical at the landing rect, so swapping them inside one transaction
    /// is invisible, while doing it in two is a flash of empty grid.
    public let setSourceConcealed: (Bool) -> Void
    /// The view the depth cue recedes: the content, not the chrome around it.
    /// Same rule (and same reason) as `ZoomTransitionSource.zoomPresenterDepthView`.
    public let depthView: () -> UIView?
    /// The opening is over, `true` landed and `false` reversed mid-air.
    ///
    /// Exists for chrome the opening FADED rather than dismissed: the source's
    /// bar is driven to alpha 0 by the flight, and the owner takes it down for
    /// real here — under the landed page, where the frame change cannot be
    /// seen. A reversed opening puts it back instead.
    public let presentationDidEnd: (Bool) -> Void
    /// Last chance to move before a dismissal measures its landing — the grid
    /// scrolling the row back into view, or pinning its content inset.
    public let willStageDismissal: () -> Void
    /// The close is over, WHICHEVER WAY IT WENT — `true` committed, `false`
    /// sprung back.
    ///
    /// Paired with `willStageDismissal` and fired on both outcomes, because
    /// the thing it undoes (a pinned content inset) is set on every dismissal
    /// and a cancelled swipe reports through no other channel. The hero learnt
    /// this the same way: its thaw hangs off `setZoomSourceHidden(false)`,
    /// which is likewise called on every ending.
    ///
    /// The outcome is a parameter and not two hooks because the caller's two
    /// jobs differ by exactly one thing — a cancelled close has to put back
    /// the source chrome it restored at grab-begin, and a committed one must
    /// not.
    public let dismissalDidEnd: (Bool) -> Void
    /// Whether the page counter-translates to match its caption to the row's
    /// (`true`), or simply sits still while the window opens over it
    /// (`false`). The prototype exposes both because the choice is a matter of
    /// taste that no argument settles — see `-text-reveal-plain`.
    public let matchesAnchor: Bool
    /// How the page meets its window — see `RevealPageFit`.
    public let pageFit: RevealPageFit

    public init(
        sourceFrame: @escaping (UICoordinateSpace) -> CGRect?,
        sourceCornerRadius: CGFloat,
        sourceFill: UIColor? = nil,
        sourceCaptionEnd: CGFloat? = nil,
        installDestinationVeil: @escaping (CGFloat?, UIColor?) -> Void = { _, _ in },
        setDestinationVeilOpacity: @escaping (CGFloat) -> Void = { _ in },
        installDestinationAuthorBand: @escaping (CGRect?) -> Void = { _ in },
        setDestinationAuthorBandOpacity: @escaping (CGFloat) -> Void = { _ in },
        setDestinationGround: @escaping (UIColor?) -> Void = { _ in },
        anchorFrame: @escaping (UICoordinateSpace) -> CGRect? = { _ in nil },
        sourceCaptionTop: CGFloat = 0,
        makeDismissStandIn: @escaping () -> UIView? = { nil },
        makePresentStandIn: @escaping () -> UIView? = { nil },
        setSourceConcealed: @escaping (Bool) -> Void = { _ in },
        depthView: @escaping () -> UIView? = { nil },
        presentationDidEnd: @escaping (Bool) -> Void = { _ in },
        willStageDismissal: @escaping () -> Void = {},
        dismissalDidEnd: @escaping (Bool) -> Void = { _ in },
        matchesAnchor: Bool = true,
        pageFit: RevealPageFit = .clipped
    ) {
        self.sourceFrame = sourceFrame
        self.sourceCornerRadius = sourceCornerRadius
        self.sourceFill = sourceFill
        self.sourceCaptionEnd = sourceCaptionEnd
        self.installDestinationVeil = installDestinationVeil
        self.setDestinationVeilOpacity = setDestinationVeilOpacity
        self.installDestinationAuthorBand = installDestinationAuthorBand
        self.setDestinationAuthorBandOpacity = setDestinationAuthorBandOpacity
        self.setDestinationGround = setDestinationGround
        self.anchorFrame = anchorFrame
        self.sourceCaptionTop = sourceCaptionTop
        self.makeDismissStandIn = makeDismissStandIn
        self.makePresentStandIn = makePresentStandIn
        self.setSourceConcealed = setSourceConcealed
        self.depthView = depthView
        self.presentationDidEnd = presentationDidEnd
        self.willStageDismissal = willStageDismissal
        self.dismissalDidEnd = dismissalDidEnd
        self.matchesAnchor = matchesAnchor
        self.pageFit = pageFit
    }
}

/// How the departing page meets the window that is closing over it.
///
/// ⚠️ THE ONE THING ALL THREE ANSWER: whether the page moves at all. Two of
/// them scale it, and the reason both exist is that "do not truncate the media"
/// means different geometry depending on what the window is becoming.
public enum RevealPageFit {
    /// The page holds still and the window shows part of it. Right when the
    /// window is a CARD-shaped slice of a page laid out the same way, which is
    /// what makes the hand-off at the end exact — and wrong the moment the
    /// window's shape stops resembling the page's, where it is just a keyhole
    /// panning over a photograph.
    case clipped
    /// The page fills the window and is cropped by it. For a landing the window
    /// is REPLACED by rather than resolved into — a 44pt marker draws none of
    /// the page — where filling is what keeps the media reading as the thing
    /// travelling.
    case covering
    /// The page fits INSIDE the window, whole, with the card's own ground
    /// around it. For a landing whose shape diverges from the page's early: a
    /// 343x145 row against a 402x874 screen crops almost everything under
    /// `covering`, because covering keys on the width, and the width is the
    /// dimension that barely moves.
    case contained

    /// ⚠️ TRUE FOR EVERY FIT THAT MOVES THE PAGE, which is the question almost
    /// every caller is actually asking — and asking it as `== .covering` is a
    /// bug that compiles.
    ///
    /// It shipped: the schedule that keeps the destination off screen during a
    /// drag was gated on `.covering` alone, so a `.contained` landing fell back
    /// to the three acts and its card appeared under the finger. Filmed on a
    /// place page's Activity close, and reported as the same defect twice
    /// because it WAS the same defect, reached by a fit the gate did not name.
    ///
    /// Named once here so the two questions cannot be confused: which fit, and
    /// whether the page travels at all.
    public var carriesPage: Bool { self != .clipped }
}

/// A stand-in that can wear the window's rounding. Declared here so
/// CoreNavigation can shape one without knowing what draws it.
@MainActor
public protocol RevealStandInShaping: AnyObject {
    func setCornerRadius(_ radius: CGFloat)
    /// The card's opacity INSIDE the stand-in, separate from the stand-in's
    /// own — see `RevealStage.swapToStandIn`.
    func setContentOpacity(_ alpha: CGFloat)
}

// MARK: - Shared staging

/// The mask and the two poses both legs interpolate between. Extracted so the
/// present and the pop are provably the same geometry read in opposite
/// directions, rather than two rect calculations that have to agree.
///
/// ## Why a mask, and why the page travels by TRANSFORM
///
/// The first build re-parented the page into a clipping wrapper whose frame
/// swept from the row to the screen. It measured correctly — the caption was
/// 16pt below the window's top edge by construction — and rendered wrongly:
/// at 60fps the opening window showed the page's COMMENT rows where its
/// caption should have been.
///
/// The cause is the one that killed the impersonation attempts, arriving by a
/// different door. **Safe area is computed from where a view actually is.** A
/// page re-parented into a 76pt window at the bottom of the screen resolves a
/// different safe area, `viewSafeAreaInsetsDidChange` fires, the comment
/// panel re-places itself, and the caption is no longer where it was
/// measured. Moving the page by `frame` does the same thing for the same
/// reason.
///
/// Both are avoided by never moving the page's LAYOUT:
///
/// * the host is full-screen and STATIC, so the page inside it resolves
///   exactly the safe area it would have resolved on its own;
/// * the clip is a `mask` on that host, so what changes is which part of the
///   page is drawn, not where the page is;
/// * the page's travel is a `transform`, which moves pixels and leaves bounds
///   — and therefore safe area, and therefore the caption — alone.
///
/// ⚠️ AND A SCALE IS ADMITTED ON THE SAME TERMS, for a landing that draws none
/// of the page's type — see `RevealStage.pageCovering`. It is the same kind of
/// operation as the translation: it moves pixels and leaves bounds alone.
///
/// That is a claim about UIKit, so it was MEASURED rather than argued. With
/// `CGAffineTransform(scaleX: 0.6, y: 0.6)` applied to a staged page,
/// `safeAreaInsets` came back `{116, 0, 86, 0}` — identical to the
/// untransformed run — and `viewSafeAreaInsetsDidChange` did not fire. The
/// re-parenting failure above is about a view being somewhere else; a
/// transformed view is not.
///
/// A covering pose registers by the page's CENTRE, because a transform is
/// applied about the layer's anchor point and an origin-to-origin translation
/// stops registering the moment a scale enters the matrix.
@MainActor
enum RevealStage {
    /// `mask` is in container coordinates; `pageTranslation` is the page's
    /// transform.
    ///
    /// A POINT, not a height, even though both poses below translate purely
    /// vertically. A grab moves the window in two dimensions, and the page has
    /// to travel with it or the window slides ACROSS the text like a hole
    /// panning over a page — the words clipped at one edge and appearing at the
    /// other, which is nothing like carrying a card. Keeping the horizontal
    /// component here means the grab poses the page through the same function
    /// the two legs do, rather than reaching past it.
    struct Pose {
        let mask: CGRect
        let maskRadius: CGFloat
        let pageTranslation: CGPoint
        /// ⚠️ `var` WITH A DEFAULT, not `let`. A `let` with an initial value is
        /// excluded from the memberwise initializer entirely; a `var` with one
        /// gives that initializer a defaulted parameter, so every existing
        /// `Pose(...)` literal keeps compiling and keeps meaning exactly what
        /// it meant.
        var pageScale: CGFloat = 1
        /// ⚠️ THE DEPARTING PAGE'S OWN ALPHA, and the reason it is a pose value
        /// rather than a channel someone sets on the side: it has to travel
        /// with the geometry, because it is the geometry's other half.
        ///
        /// The window used to hand over by bringing the ARRIVAL up over the
        /// page. That put the destination's content on screen while the finger
        /// was still deciding — laid out for a card the window had not become
        /// yet, so its text was clipped at the window's edge. Filmed.
        ///
        /// The page leaves on its own instead, and nothing arrives until the
        /// release. What the window shows in between is where the viewer is
        /// going, which is the honest answer to a gesture that has not
        /// committed.
        var pageOpacity: CGFloat = 1
    }

    /// The whole page, unmasked and untranslated — the landed pose, identical
    /// on both legs.
    static func open(container: UIView) -> Pose {
        Pose(
            mask: container.bounds,
            maskRadius: ScreenGeometry.cornerRadius(behind: container),
            pageTranslation: .zero
        )
    }

    /// The page seen through the source's rect. `anchor` is the caption
    /// bubble's rect on the full-size page, in CONTAINER space.
    /// `ridingFrom`, when given, is the OPEN window — and it wins: a pose that
    /// rides carries the page by the window's displacement rather than aligning
    /// it to anything. See `pageRiding`.
    static func closed(
        sourceRect: CGRect,
        radius: CGFloat,
        anchor: CGRect?,
        matchesAnchor: Bool,
        captionTop: CGFloat = 0,
        ridingFrom open: CGRect? = nil,
        fit: RevealPageFit = .clipped
    ) -> Pose {
        if let open {
            if fit != .clipped {
                let pose = pageFitting(sourceRect, from: open, fit: fit)
                return Pose(
                    mask: sourceRect,
                    maskRadius: radius,
                    pageTranslation: pose.translation,
                    pageScale: pose.scale,
                    // Gone by the landing: the arrival is what the window holds
                    // there, and two things in one window is the double image
                    // this whole area exists to prevent.
                    pageOpacity: 0
                )
            }
            return Pose(
                mask: sourceRect,
                maskRadius: radius,
                pageTranslation: pageRiding(sourceRect, from: open)
            )
        }
        // Matched: the page is pushed down so the caption row's CONTAINER
        // starts where the source row's does. Top to top, with nothing added —
        // the two are the same layout, so their captions land on the same line
        // by construction. `PostCaptionRowView` insets its caption by
        // `PostGridListRowCell.captionTopInset` because that is what the card
        // does, and a transition that re-applied the same inset on top would
        // be counting it twice.
        //
        // It did. Measured on the user's iPhone SE recording: the close
        // settled, held for two frames, then the row jumped — a single
        // frame-to-frame delta larger than any frame of the animation itself,
        // showing the caption doubled 33px apart. 33px at 2x is 16pt, which is
        // exactly `captionTopInset`. The parameter that carried it is gone
        // rather than set to zero, so nothing can re-introduce the double
        // count.
        //
        // Plain: no travel at all, and the mask is a hole opening onto a page
        // that never moves.
        let translation: CGFloat = if matchesAnchor, let anchor {
            // Plus the card's own caption offset: the window is the whole card,
            // so the page's caption has to land where the CARD's is rather than
            // at the window's top edge.
            sourceRect.minY + captionTop - anchor.minY
        } else {
            0
        }
        return Pose(
            mask: sourceRect, maskRadius: radius,
            pageTranslation: CGPoint(x: 0, y: translation)
        )
    }

    /// ⚠️ THE PAGE COVERS THE WINDOW — it is not seen THROUGH it.
    ///
    /// The other two laws leave the page at its own size and change which part
    /// of it is drawn: `pageRiding` carries it by the window's displacement, and
    /// the plain pose does not move it at all. Both are right for a landing that
    /// is a CARD — a row, a tile — because the window is then showing the page
    /// at the size the card will show it, and the hand-off at the end is 1:1.
    ///
    /// A 44pt marker is not a card. Clipping a full-size page down to a disc
    /// shows a keyhole onto one corner of it, which is why this transition grew
    /// a stand-in carrying a copy of the page's MEDIA — and that copy is what a
    /// viewer, playing with the grab, called out: the media anchored in the
    /// window with the post fading away over it, when the post is what should
    /// have been travelling.
    ///
    /// So the page travels whole. Scaled to COVER the window (never to fit it,
    /// which would letterbox and show ground where the page ran out) and
    /// registered by its CENTRE — because a view's transform is applied about
    /// its anchor point, and an origin-to-origin translation stops registering
    /// the moment a scale enters the matrix.
    ///
    /// At rest it is the identity: an unmoved, unscaled page, so an abandoned
    /// grab needs no special case.
    ///
    /// ⚠️ It assumes the page's frame IS the open window — true for a pushed
    /// full-screen page, and asserted at both staging sites, because if that
    /// ever stops holding the pose silently stops reducing to `open` at rest.
    static func pageFitting(
        _ window: CGRect, from open: CGRect, fit: RevealPageFit
    ) -> (scale: CGFloat, translation: CGPoint) {
        let horizontal = window.width / max(open.width, 1)
        let vertical = window.height / max(open.height, 1)
        // COVER takes the larger — the page overflows and the window crops it.
        // CONTAIN takes the smaller — the page fits whole and the window's own
        // ground fills what is left. `clipped` never reaches here.
        let scale = fit == .contained ? min(horizontal, vertical) : max(horizontal, vertical)
        return (
            scale: scale,
            translation: CGPoint(x: window.midX - open.midX, y: window.midY - open.midY)
        )
    }

    /// ⚠️ HOW FAR THE WINDOW MAY SHRINK WHILE A FINGER IS STILL HOLDING IT.
    ///
    /// A window that morphs all the way to its landing by progress is right
    /// against a CARD — large enough that a full drag still leaves something
    /// recognisable in the hand — and brutal against a 44pt marker: a modest
    /// pull took the post most of the way to a disc before the viewer had
    /// decided anything.
    ///
    /// Clamped on the flight's own floor, and for the flight's own stated
    /// reason: a held window is still the PAGE, the viewer is deciding rather
    /// than landing, and the distance left belongs to the release spring.
    /// Sharing `ZoomFlight.minimumGrabScale` rather than restating it is what
    /// makes the two families feel like one gesture.
    static func grabMorph(at progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return 1 + (ZoomFlight.minimumGrabScale - 1) * clamped
    }

    /// ⚠️ WHAT A HELD GRAB SHOWS, for a landing that is not a card: the
    /// departure's own rect, uniformly scaled and displaced. The SHAPE never
    /// changes — same aspect, same corner proportion (`heldRadius`), same
    /// opacity — only the size and the position.
    ///
    /// Everything else was tried under the hand and every one was filmed and
    /// reported. Morphing toward the landing's shape cut the media away, or
    /// opened the card's ground around it. Sweeping the corner toward the
    /// landing's made a capsule halfway through a drag that had decided
    /// nothing. Fading the page out started the hand-over before there was
    /// anything to hand over.
    ///
    /// What survives is the one thing a grab actually is: the viewer holding
    /// the screen they were reading, smaller and moved. Whether it leaves is
    /// not known until they let go, so the transition — ratio, corner, fade —
    /// belongs to the release, and only if the dismissal commits.
    static func heldWindow(
        _ open: CGRect, displacedBy offset: CGPoint, at progress: CGFloat
    ) -> CGRect {
        let morph = grabMorph(at: progress)
        let size = CGSize(width: open.width * morph, height: open.height * morph)
        let centre = CGPoint(x: open.midX + offset.x, y: open.midY + offset.y)
        return CGRect(
            x: centre.x - size.width / 2, y: centre.y - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// The held window's corner: the screen's own, scaled with it, so the shape
    /// is the screen's at every instant of the drag.
    static func heldRadius(_ screenRadius: CGFloat, at progress: CGFloat) -> CGFloat {
        screenRadius * grabMorph(at: progress)
    }

    /// How far the page slides so its caption stays REGISTERED with a window
    /// that a finger is moving.
    ///
    /// The animated legs get this for free: their window travels toward the
    /// landing while the page's transform interpolates alongside, so the gap
    /// between the window's edges and the caption's shrinks from its resting
    /// value to nothing. A GRAB breaks that, because the window's position is
    /// the finger's and no longer a function of progress. Interpolate the
    /// transform on its own and the window slides ACROSS the page — measured on
    /// a scripted grab, a window dragged 134pt right showed "…ping the new
    /// build tonight" with its first word cut off at the left edge: a hole
    /// panning over text, not a card being carried.
    ///
    /// So the law is written down rather than left to emerge. The gap between
    /// the window's edge and the caption's is the RESTING gap, scaled by how
    /// far from home the grab is:
    ///
    ///     captionEdge - windowEdge = (1 - progress) * anchorEdge
    ///
    /// and since `captionEdge = anchorEdge + translation`, that is the line
    /// below. It reduces to both poses exactly — `.zero` at rest, and
    /// `closed`'s own translation once the window is home — so no two numbers
    /// have to be kept in agreement by hand. `RevealRegistrationTests` pins
    /// both ends.
    ///
    /// Both axes, because a grab moves in both. The horizontal component is
    /// zero at each END — the row and the page carry their captions at the same
    /// inset, which is why the animated legs never needed it — and non-zero for
    /// every frame in between, which is the only interval a grab lives in.
    /// `captionTop` is how far below the SOURCE card's top edge its caption
    /// begins — zero for a plain card, the author band plus its gap for one
    /// that names its author. It is what lets the window be the whole card
    /// while the caption still lands on the card's own.
    ///
    /// It enters as `progress * captionTop`, which is the only place it can go:
    /// at rest the page's caption is where the page puts it and the band is
    /// irrelevant, and at home the gap between the window's top and the
    /// caption has to be exactly the card's. Everything between interpolates,
    /// as the rest of the law does.
    static func pageTranslation(
        carrying window: CGRect, anchor: CGRect?, progress: CGFloat,
        captionTop: CGFloat = 0
    ) -> CGPoint {
        guard let anchor else { return .zero }
        return CGPoint(
            x: window.minX - progress * anchor.minX,
            y: window.minY - progress * anchor.minY + progress * captionTop
        )
    }

    /// How the window stops being the page and becomes the card, WITHOUT ever
    /// being both — as a pure function of how far the dismissal has gone.
    ///
    /// The obvious version cross-fades one into the other, and it is the
    /// mistake this transition has already paid for four times over: blending
    /// two different runs of text draws BOTH of them. The caption ghost died of
    /// it four times for four different reasons, and the note that survived is
    /// the general one — a fade only works against NOTHING.
    ///
    /// So there is a nothing. The stand-in is the card's fill and the card is
    /// what it holds, and the two fade at different times with a beat between:
    ///
    /// ```
    ///   0        .10        .45   .55        .85         1
    ///   │ page    │ fill in  │ EMPTY │ card in │  card    │
    ///   └─────────┴──────────┴───────┴─────────┴──────────┘
    ///             text vs a    the    a card vs
    ///             flat colour  beat   nothing
    /// ```
    ///
    /// Neither fade ever has text on both sides.
    ///
    /// ## Why on progress, and why in the MIDDLE
    ///
    /// The first version ran this on a fixed clock at grab-begin, on the
    /// reasoning that a held finger should not be able to park the viewer
    /// mid-blend. Two things were wrong with it. The blend it was protecting
    /// against no longer exists — there is a beat now, so the worst a held
    /// finger can do is hold on an empty card-coloured window, which is a
    /// state rather than a smear. And a timed swap at grab-begin empties the
    /// window while the viewer is still looking at what they were reading,
    /// which is abrupt at the one moment nothing has happened yet.
    ///
    /// Worse, it did not work: an interactive transition's start runs inside
    /// navigation setup machinery where `UIView.animate` applies WITHOUT
    /// animating (the trap `ZoomDismissInteractionController` documents for its
    /// detach dip), so the delayed half never ran and nothing else set the
    /// card's opacity on a committed grab. The card stayed invisible for the
    /// whole flight and appeared when the stand-in was retired — the abrupt
    /// last frame.
    ///
    /// On progress there is no clock to lose. The drag sets these directly, as
    /// it sets every other value, and the empty state lands in the middle of
    /// the gesture where the viewer has already decided to leave.
    static func swapFractions(at progress: CGFloat) -> (fill: CGFloat, content: CGFloat) {
        (fill: easeIn(ramp(progress, from: pageFadeStart, to: pageFadeEnd)),
         content: easeOut(ramp(progress, from: cardFadeStart, to: cardFadeEnd)))
    }


    /// When the marker's face begins arriving over a page that is covering the
    /// window. Its own constant, so it can be pulled earlier or later without
    /// disturbing the shared three-act schedule.
    static let coveringFaceFadeStart: CGFloat = cardFadeStart

    /// The fill a stand-in should be wearing at `progress`: one dissolve over a
    /// covering page, or the three acts.
    ///
    /// Takes PROGRESS rather than the computed fill, because the covering
    /// dissolve does not run on the three acts' schedule and cannot be
    /// expressed as a function of them.
    ///
    /// ⚠️ THE FILL ACT IS DELETED ON THE COVERING PATH, not rescheduled. That
    /// act exists to give an arriving CAPTION a nothing to fade against — and a
    /// 44pt disc has no caption, so all it buys there is a coloured hole where
    /// the post used to be. That hole is what a viewer, playing with the grab,
    /// described as the post fading away over its own media. The "nothing" the
    /// face fades against here is the opaque live post itself.
    static func fill(at progress: CGFloat, carriesPage: Bool = false) -> CGFloat {
        // ⚠️ NOTHING ARRIVES WHILE THE FINGER IS DOWN, on a fit that carries
        // the page. The arrival's whole job is to be what the window becomes,
        // and it becomes it on the release — see `Pose.pageOpacity`, which is
        // the other half of the same rule.
        if carriesPage { return 0 }
        return swapFractions(at: progress).fill
    }

    /// ⚠️ EXACTLY ONE ALPHA MOVES over a covering page, and it is the view's.
    ///
    /// The stand-in's own alpha fades the marker in as ONE opaque unit — disc
    /// and glyph together — which is the only shape of fade this transition
    /// permits against a finished drawing. Ramp the content as well and the
    /// glyph renders at alpha squared: it fades faster than the disc beneath
    /// it, and the frame in the middle is the half-drawn overlay the blend law
    /// forbids.
    static func contentOpacity(at progress: CGFloat, carriesPage: Bool) -> CGFloat {
        carriesPage ? 1 : swapFractions(at: progress).content
    }

    private static func ramp(_ value: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(max((value - start) / (end - start), 0), 1)
    }

    /// Both curves ACCELERATE AWAY FROM TRANSPARENT, which is the end that
    /// costs something to dwell at.
    ///
    /// Linear opacity spends as long being barely-there as being nearly-solid,
    /// and the two are not worth the same: a shape at 5% reads as a smudge
    /// rather than as a thing arriving or leaving. So the fill leaves zero
    /// slowly and slams into one — the page holds its ground and then goes —
    /// and the card leaves zero fast and eases into one, so it is legible
    /// almost as soon as it exists.
    private static func easeIn(_ t: CGFloat) -> CGFloat { t * t }
    private static func easeOut(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }

    /// The page dissolving into the card's fill.
    static let pageFadeStart: CGFloat = 0.10
    static let pageFadeEnd: CGFloat = 0.45
    /// The reveal's OWN damping, a little looser than the media flight's.
    ///
    /// Peak overshoot is `exp(-πζ/√(1-ζ²))`, which puts the three values this
    /// has worn in order:
    ///
    /// ```
    ///   0.82  1.1%   the flight's — read as drawn open on rails
    ///   0.70  4.6%   visibly springy, and too much of it
    ///   0.78  2.0%   here
    /// ```
    ///
    /// The flight's number was chosen for a photograph landing on the same
    /// photograph, where any wobble reads as the picture failing to sit still.
    /// A window has nothing to keep still — what arrives is a rounded rect
    /// becoming a screen — so it can carry roughly twice the flight's bounce
    /// and no more: at 4.6% the settle stopped reading as momentum and started
    /// reading as an effect.
    ///
    /// Its own constant rather than a change to `ZoomFlight.springDamping`,
    /// because the media hero was never the thing that read flat and must not
    /// move.
    static let springDamping: CGFloat = 0.78
    /// The push-off — small on purpose now that the DURATION carries the
    /// character.
    ///
    /// A kick off the source is what made this read as abrupt: the window left
    /// fast and then had to shed all of it, so the fastest and slowest parts of
    /// the motion were a few frames apart. Starting nearly from rest and taking
    /// longer gives the same distance a visible acceleration and a visible
    /// settle, which is what "smooth" is asking for.
    static let springVelocity: CGFloat = 0.35
    /// The reveal's own duration, longer than the flight's 0.42.
    ///
    /// A media flight moves a card across a screen; a reveal grows a 44pt disc
    /// into the whole of one, which is a much larger visual change over the
    /// same time and is why it read as abrupt at the flight's length. The
    /// distance is the argument for the extra time, not taste.
    ///
    /// ⚠️ Everything staged in fractions rides this — see
    /// `springVisibleFraction` and the hand-off — so it stays a single number
    /// that the legs are shares of, never a second literal in an animator.
    static let springDuration: TimeInterval = 0.55
    /// How much of a spring's DURATION its visible travel occupies.
    ///
    /// The hand-off's fractions are shares of the window's journey, and a timed
    /// animation can only be given shares of a CLOCK. Those are the same thing
    /// under a linear curve and nothing like it under a spring, which covers
    /// almost all of its distance early and spends the remainder settling
    /// invisibly. Legs scheduled against the whole duration therefore fire
    /// against a window that has already arrived.
    ///
    /// Used only where the hand-off is on a timer — a chevron pop, an opening.
    /// A GRAB needs none of this: it is driven by progress, which is the
    /// journey itself.
    static let springVisibleFraction: CGFloat = 0.6
    /// The card arriving into it — starting EXACTLY where the fill finishes.
    ///
    /// There was a beat between them, and it is gone. It was there to keep the
    /// two fades from ever having text on both sides, which is the mistake this
    /// transition paid for four times over — but it was belt on top of braces:
    /// the fill is opaque, so at `pageFadeEnd` the page is not dimmed, it is
    /// COVERED. Nothing can show through it, beat or no beat.
    ///
    /// What the beat did instead was hold a card-coloured window with nothing
    /// in it for a tenth of the gesture, which reads as a hole rather than as a
    /// hand-off. Starting the card where the fill lands means the window is
    /// never empty for any measurable time — and the invariant that mattered
    /// still holds, because it was never the gap that held it.
    static let cardFadeStart: CGFloat = 0.45
    static let cardFadeEnd: CGFloat = 0.80

    /// The page RIDING the window: it moves with it, rigidly, and nothing
    /// inside it moves relative to anything else.
    ///
    /// The third of three ways a page can behave under a flight, and each
    /// answers a different question:
    ///
    /// * **registered** (`pageTranslation`) — the page slides so its caption
    ///   lands on the card's. Right when the window is going to SHOW the page,
    ///   wrong once a stand-in is showing the card instead: the alignment then
    ///   chases a caption nobody will see, and the comments slide under the
    ///   stand-in for the length of the grab.
    /// * **still** (`.zero`) — the page does not move and the window opens over
    ///   it. The `-text-reveal-plain` behaviour, and what the first fix for the
    ///   slide reached for. It removes the slide and introduces a worse one:
    ///   the window travels under the finger while its contents stay nailed to
    ///   the screen, so the viewer is dragging a hole rather than a card.
    /// * **riding** (this) — the page translates by exactly the window's own
    ///   displacement. Nothing inside the window moves relative to the window,
    ///   which is what holding something feels like.
    static func pageRiding(_ window: CGRect, from open: CGRect) -> CGPoint {
        CGPoint(x: window.minX - open.minX, y: window.minY - open.minY)
    }

    /// The static full-screen host and its mask. The page keeps the frame the
    /// transition context gave it; only the mask and the transform ever move.
    /// ⚠️ `ground` IS NOT DECORATION — it is what `RevealPageFit.contained`
    /// promises and had no way to keep.
    ///
    /// A contained page fits INSIDE the window "with the card's own ground
    /// around it". Nothing painted that ground: the host was clear, so as the
    /// window's aspect diverged from the page's on the release, the DESTINATION
    /// showed through the sides of the closing card. Invisible during the drag,
    /// where the window keeps the screen's aspect and the page fills it
    /// exactly, and it opens the moment the spring starts.
    static func makeHost(
        around page: UIView, in container: UIView, pageFrame: CGRect,
        ground: UIColor? = nil
    ) -> (host: UIView, mask: UIView) {
        let host = UIView(frame: container.bounds)
        host.backgroundColor = ground
        container.addSubview(host)
        host.addSubview(page)
        // Cleared BEFORE the frame is assigned: `frame` is derived from bounds
        // and transform, so framing a still-transformed page sets the wrong
        // bounds. Inert today on a first staging, and not inert on the
        // documented double-stage (UIKit asks for `interruptibleAnimator` even
        // under an interaction controller), where under a scale it would
        // mis-SIZE the page rather than only mis-place it.
        page.transform = .identity
        page.frame = pageFrame
        // Opaque, because a mask reads its alpha channel — a clear view masks
        // everything away, which is a blank screen rather than a clipped one.
        let mask = UIView()
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        host.mask = mask
        return (host, mask)
    }

    /// `standIn`, when there is one, takes the WINDOW's frame rather than the
    /// page's transform — which is the whole point of it. The page moves with
    /// its own scroll and its own registration; the stand-in is the card, and
    /// the card is wherever the window is.
    static func apply(_ pose: Pose, mask: UIView, page: UIView, standIn: UIView? = nil) {
        mask.frame = pose.mask
        mask.layer.cornerRadius = pose.maskRadius
        // Scale first, then translate — so the translation is in the
        // container's own points and does not shrink with the page.
        page.transform = CGAffineTransform(
            translationX: pose.pageTranslation.x, y: pose.pageTranslation.y
        ).scaledBy(x: pose.pageScale, y: pose.pageScale)
        page.alpha = pose.pageOpacity
        standIn?.frame = pose.mask
        (standIn as? RevealStandInShaping)?.setCornerRadius(pose.maskRadius)
        // LAID OUT HERE, inside whatever block is applying the pose, and that
        // is the whole of keeping a stand-in's contents centred.
        //
        // A stand-in holds the card centred by constraint. Constraints resolve
        // in a layout pass, and a layout pass is not an animation: with the
        // frame animating from one rect to another, the card inside jumped
        // straight to its final centre while the window was still travelling —
        // a gap opening in the middle of the release, exactly where the
        // transition promises continuity. The drag never showed it, because
        // direct sets get a layout pass every turn anyway.
        //
        // Called from INSIDE the animation, the layout animates too: the frame
        // interpolates from A to B, the card's centre interpolates from
        // centre(A) to centre(B), and since centring is affine in the frame and
        // both ride the same curve, centred at the ends means centred all the
        // way through.
        standIn?.layoutIfNeeded()
    }

    /// Puts `page` back where the transition context expects to find it and
    /// retires the host. Called on every outcome — committed, cancelled, or
    /// failed — because a page left inside a removed host is a blank screen.
    static func unwrap(_ page: UIView, from host: UIView, to container: UIView, frame: CGRect) {
        // Restored with the transform: a page handed back half-faded is a
        // screen the viewer cannot see, on every outcome including a cancel.
        page.alpha = 1
        page.transform = .identity
        page.frame = frame
        container.addSubview(page)
        host.removeFromSuperview()
    }

    /// The rect to fall back to when the source is off screen: a small centred
    /// mask, so the page collapses toward the middle instead of onto a row
    /// nobody can see.
    static func centredFallback(in container: UIView) -> CGRect {
        ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: 96)
    }

    #if DEBUG
    /// The TIMESTAMP is half the value of these lines, not decoration.
    ///
    /// The simulator's Slow Animations multiplies every duration by ten and is
    /// invisible from inside the process — the code is unchanged and only the
    /// wall clock knows. It cost a wrong diagnosis here: a chrome fade timed at
    /// 2.65s for a 0.25s animation read as "the fade never ran", and the frames
    /// backing that up read as a regression that did not exist. `xcodebuild
    /// test` relaunches Simulator.app and turns the slowdown back on, so a run
    /// that was headless when it started may not be by the time it is measured.
    /// Compare consecutive stamps against the durations asked for before
    /// believing any of it.
    static func log(_ leg: String, _ message: String) {
        guard ProcessInfo.processInfo.arguments.contains("-text-reveal-log") else { return }
        print(String(format: "[text-reveal] %.3f %@ %@", CACurrentMediaTime(), leg, message))
    }
    #endif
}

/// Places the veil, given the anchor the flight measured.
///
/// Nothing to do when the source shows its whole caption (`sourceCaptionEnd`
/// nil) or when there is no anchor to measure from — a plain reveal has no
/// overflow to hide, and veiling one would only dim a page that matches.
/// Puts the source's author band into the destination, where the page has
/// nothing — see `RevealGeometry.installDestinationAuthorBand`.
///
/// Nothing to place when the source has no band of its own — every profile
/// gallery, and every card whose post carries no identity.
@MainActor
func installAuthorBand(geometry: RevealGeometry, anchor: CGRect?) {
    guard geometry.sourceCaptionTop > 0, !geometry.pageFit.carriesPage else {
        geometry.installDestinationAuthorBand(nil)
        return
    }
    geometry.installDestinationAuthorBand(anchor)
}

/// ⚠️ NEITHER PROP EXISTS FOR A FIT THAT CARRIES THE PAGE, and the guard lives
/// HERE rather than at the ramps that drive them.
///
/// Both are scenery belonging to the DESTINATION — the landing card's fill
/// below its caption, and the landing row's author band — and both are added
/// as subviews of the departing page, so they scale with it and are drawn
/// inside the window the finger is holding. A carrying grab may show nothing
/// of where it is going until the viewer lets go, and these were the last two
/// channels still doing it: a card-coloured hole opening down the miniature
/// post, with a second author header above it.
///
/// Only ONE origin ever armed them on a carrying fit — the place page's
/// Activity close — and every other carrying source dodged it by passing
/// `captionEnd: nil` rather than by the transition refusing it. A convention
/// that four sources happened to keep is not a rule; this is.
///
/// The release leg was never implicated: a carrying fit's landing pose takes
/// the page's opacity to zero, and both props die with it.
@MainActor
func installVeil(geometry: RevealGeometry, anchor: CGRect?) {
    guard let end = geometry.sourceCaptionEnd, let anchor,
          !geometry.pageFit.carriesPage
    else {
        geometry.installDestinationVeil(nil, nil)
        return
    }
    #if DEBUG
    RevealStage.log("veil", "anchorY=\(Int(anchor.minY)) captionEnd=\(Int(end))"
        + " cut=\(Int(anchor.minY + end))")
    #endif
    geometry.installDestinationVeil(anchor.minY + end, geometry.sourceFill)
}

/// The animation controller UIKit insists on having beside a custom
/// interactive driver — and which must do NOTHING, because the driver IS the
/// animation.
///
/// Vending `RevealPopAnimator` here instead is not harmless. UIKit asks an
/// animator for `interruptibleAnimator` even when an interaction controller is
/// driving, and that call STAGES: measured, the grab set up its host, mask and
/// dim, and a heartbeat later the animator built a second set over the same
/// page, reading its landing through the depth recede the grab had already
/// applied (a 343x145 row came back 325.85x137.75). Two stages, one page.
///
/// So the grab's leg gets an animator that owns no geometry at all. Duration is
/// still answered because UIKit budgets the transition with it.
@MainActor
final class RevealGrabAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        RevealStage.springDuration
    }

    /// EMPTY, and it has to be. UIKit routes an interactive pop to the
    /// interaction controller's `startInteractiveTransition` and — verified by
    /// tracing a scripted grab — never calls this at all. Completing the
    /// transition here "just in case" is not a safety net: it would end the
    /// transition under a grab that is still holding the page, which renders as
    /// the whole dismissal collapsing into a single frame. The grab owns the
    /// completion, on both outcomes, in its own teardown.
    func animateTransition(using context: any UIViewControllerContextTransitioning) {}
}

// MARK: - Present

/// The window opens. Non-interactive, and on the hero's own spring, so a text
/// post and a media post settle with identical physics.
@MainActor
final class RevealPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let geometry: RevealGeometry
    /// Source chrome that must LEAVE with the opening rather than before it —
    /// the app's floating tab bar.
    ///
    /// The bar draws OVER the grid without insetting it, so at rest it covers
    /// the bottom of the row a reveal departs from: measured on an iPhone 17
    /// Pro, the bar occupies y 791…874 and the row 741…817, so 26pt of the
    /// card — its whole metric line — is not on screen. Hidden before the push,
    /// as a plain push does it, that line SNAPS into existence one frame after
    /// the mask opens: the card the viewer tapped is not the card that starts
    /// growing.
    ///
    /// Driven here instead, the bar is fully in place on frame 0 — so the
    /// revealed rect is pixel-identical to what was there — and dissolves as
    /// the page grows past it.
    private weak var departingChrome: UIView?

    init(geometry: RevealGeometry, departingChrome: UIView?) {
        self.geometry = geometry
        self.departingChrome = departingChrome
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        RevealStage.springDuration
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to)
        else {
            context.completeTransition(false)
            return
        }
        let pageFrame = context.finalFrame(for: toVC)

        // THE WHOLE POINT, and the reason none of the impersonation defects
        // can occur here: the destination is installed at full size and laid
        // out BEFORE anything is measured or posed. Its safe area is the real
        // one, its comment stream is really mounted, and its caption is the
        // only caption in existence — and it stays that way, because nothing
        // below moves its layout again.
        toView.frame = pageFrame
        container.addSubview(toView)
        container.layoutIfNeeded()

        let anchor = geometry.anchorFrame(container)
        let sourceRect = geometry.sourceFrame(container) ?? RevealStage.centredFallback(in: container)

        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        container.insertSubview(dim, belowSubview: toView)

        let (host, mask) = RevealStage.makeHost(
            around: toView, in: container, pageFrame: pageFrame
        )
        let closed = RevealStage.closed(
            sourceRect: sourceRect,
            radius: geometry.sourceCornerRadius,
            anchor: anchor,
            matchesAnchor: geometry.matchesAnchor,
            captionTop: geometry.sourceCaptionTop
        )
        let open = RevealStage.open(container: container)
        // The window opens AS THE SOURCE when the source's content is not the
        // page's — a marker's glyph, which the page has nowhere. Added above
        // the masked page, posed on the same closed pose, and handed over in
        // the dismissal's order reversed: content first, then the fill under
        // it. Nil for a row, whose caption is the page's caption.
        let standIn = geometry.makePresentStandIn()
        if let standIn {
            container.addSubview(standIn)
            standIn.alpha = 1
            (standIn as? RevealStandInShaping)?.setContentOpacity(1)
        }
        RevealStage.apply(closed, mask: mask, page: toView, standIn: standIn)
        // The page wears the CARD before it wears itself. Set outside the
        // animation block so frame 0 is already the card's tone; the block
        // below hands the ground back, which cross-fades it.
        geometry.setDestinationGround(geometry.sourceFill)
        // …and shows no more of itself than the card did. The cut is measured
        // from the SOURCE's top, and the two tops are aligned by `closed`, so
        // it lands in the destination at the anchor's top plus that offset.
        installVeil(geometry: geometry, anchor: anchor)
        installAuthorBand(geometry: geometry, anchor: anchor)
        geometry.setDestinationVeilOpacity(1)
        geometry.setDestinationAuthorBandOpacity(1)

        #if DEBUG
        RevealStage.log("present", "source=\(NSCoder.string(for: sourceRect))"
            + " anchor=\(anchor.map(NSCoder.string(for:)) ?? "nil")"
            + " travel=\(Int(closed.pageTranslation.y)) matched=\(geometry.matchesAnchor)")
        #endif

        // The grid recedes behind the opening mask — the same depth cue a hero
        // applies, on the content only, so the screen's own chrome stays
        // grounded.
        // The row goes the moment the window takes its place. Invisible at
        // frame 0 — the window is sitting exactly on it — and the whole point
        // everywhere after.
        geometry.setSourceConcealed(true)
        let presenting = geometry.depthView() ?? context.viewController(forKey: .from)?.view
        let screenRadius = ScreenGeometry.cornerRadius(behind: container)
        ZoomFlight.applyRecededChrome(to: presenting, radius: screenRadius)

        let duration = transitionDuration(using: context)
        // TAIL-WEIGHTED, on its own clock — the hero's `delayFactor: 0.35`,
        // reproduced here because the first capture showed why it exists: run
        // linearly with the mask, the dim had the grid at half black before
        // the page was a third open, so the surface the reveal is supposed to
        // be growing OUT of was gone by the time it had grown.
        UIView.animate(withDuration: duration * 0.65, delay: duration * 0.35, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        // FRONT-LOADED, unlike the dim: the bar has to be gone by the time the
        // mask has grown past where it sits, or it stands over the opening
        // page (it is a sibling of the navigation controller and renders above
        // the whole transition). Fading over the first 60% clears it while the
        // mask is still below it.
        let chrome = departingChrome
        UIView.animate(withDuration: duration * 0.6, delay: 0, options: [.curveEaseIn]) {
            chrome?.alpha = 0
        } completion: { _ in
            #if DEBUG
            RevealStage.log("present", "chrome faded to \(chrome?.alpha ?? -1)")
            #endif
        }
        // THE HAND-OFF, which is the dismissal's run backwards.
        //
        // The dismissal fades the page into the card's fill and then raises the
        // card inside it; an opening that starts as its source has to undo
        // exactly that, in the same order and on the same fractions — content
        // out first, then the fill it sat on, revealing the page that was
        // underneath from frame 0. The curves invert with the direction: a rise
        // that accelerated away from transparent is a fall that decelerates
        // into it.
        if let standIn {
            let shaping = standIn as? RevealStandInShaping
            // Against the spring's visible window for the same reason the pop
            // is — see `RevealStage.springVisibleFraction`.
            let span = duration * RevealStage.springVisibleFraction
            let contentOut = 1 - RevealStage.cardFadeEnd
            let fillOut = 1 - RevealStage.pageFadeEnd
            UIView.animate(
                withDuration: span * (RevealStage.cardFadeEnd - RevealStage.cardFadeStart),
                delay: span * contentOut,
                options: [.curveEaseOut]
            ) {
                shaping?.setContentOpacity(0)
            }
            UIView.animate(
                withDuration: span * (RevealStage.pageFadeEnd - RevealStage.pageFadeStart),
                delay: span * fillOut,
                options: [.curveEaseIn]
            ) {
                standIn.alpha = 0
            }
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: RevealStage.springDamping,
            initialSpringVelocity: RevealStage.springVelocity,
            options: [.allowUserInteraction]
        ) {
            RevealStage.apply(open, mask: mask, page: toView, standIn: standIn)
            // On the SAME spring as the mask, so the card does not become the
            // page a beat before or after it becomes the screen.
            self.geometry.setDestinationGround(nil)
            self.geometry.setDestinationVeilOpacity(0)
            self.geometry.setDestinationAuthorBandOpacity(0)
            presenting?.transform = CGAffineTransform(
                scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
            )
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            // A reversed opening never showed the page, so the row it was taken
            // from has to come back — before the window goes, so the two are
            // never both absent. A landed one keeps it hidden: the page is over
            // it, and the dismissal is what puts it back.
            if cancelled { self.geometry.setSourceConcealed(false) }
            // Idempotent close-out: the ground is already back by now, this
            // only guarantees it if the animation was interrupted.
            self.geometry.setDestinationGround(nil)
            self.geometry.installDestinationVeil(nil, nil)
            self.geometry.installDestinationAuthorBand(nil)
            RevealStage.unwrap(toView, from: host, to: container, frame: pageFrame)
            standIn?.removeFromSuperview()
            dim.removeFromSuperview()
            // Cleared under the opaque page, where the reset cannot be seen.
            presenting?.transform = .identity
            ZoomFlight.clearRecededChrome(from: presenting)
            // The owner takes the chrome down for real (or puts it back on a
            // reversal); the alpha goes home either way, since the view is
            // shared with every other screen that shows it.
            #if DEBUG
            RevealStage.log("present", "landed")
            #endif
            chrome?.alpha = 1
            self.geometry.presentationDidEnd(!cancelled)
            context.completeTransition(!cancelled)
        }
    }
}

#if DEBUG
/// Samples a leg's PRESENTATION values every frame, for the one question a
/// completion handler cannot answer.
///
/// ⚠️ Reading `layer.presentation()` when the transition completes proves
/// nothing: the animation has just been removed, so presentation returns the
/// model value and always equals the target. The question — does the window
/// travel all the way, or is it cut off and the row swapped in — is about the
/// frames BEFORE that, and only a display link sees them.
///
/// Prints one line per sample under `-text-reveal-log`, then a verdict: how far
/// short of the target the last sampled frame was.
@MainActor
final class RevealTrajectoryProbe {
    private var link: CADisplayLink?
    private weak var tracked: UIView?
    private let target: CGRect
    private let leg: String
    private let start = CACurrentMediaTime()
    private var samples: [(t: CFTimeInterval, rect: CGRect)] = []

    static func begin(_ leg: String, tracking view: UIView, to target: CGRect)
        -> RevealTrajectoryProbe? {
        guard ProcessInfo.processInfo.arguments.contains("-text-reveal-log") else { return nil }
        return RevealTrajectoryProbe(leg: leg, tracked: view, target: target)
    }

    private init(leg: String, tracked: UIView, target: CGRect) {
        self.leg = leg
        self.tracked = tracked
        self.target = target
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func sample() {
        guard let rect = tracked?.layer.presentation()?.frame else { return }
        samples.append((CACurrentMediaTime() - start, rect))
    }

    /// Call from the leg's completion, BEFORE anything is torn down.
    func finish() {
        link?.invalidate()
        link = nil
        guard let last = samples.last else {
            print("[text-reveal] \(leg) trajectory: no samples")
            return
        }
        for sample in samples {
            print(String(format: "[text-reveal] %@ t=%.3f y=%.1f h=%.1f",
                         leg, sample.t, sample.rect.minY, sample.rect.height))
        }
        print(String(format: "[text-reveal] %@ trajectory ended %.1fpt short in y,"
                     + " %.1fpt short in height, over %d frames",
                     leg, last.rect.minY - target.minY,
                     last.rect.height - target.height, samples.count))
    }
}
#endif

// MARK: - Pop

/// The window closes. Linear on purpose: this leg is what a finger scrubs, and
/// a percent driver tracks 1:1 only against a linear curve — the release
/// spring is the driver's own completion curve, not this one's.
@MainActor
final class RevealPopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let geometry: RevealGeometry
    /// Source chrome that comes back with the return (the app's tab bar), so
    /// it is revealed by the hand rather than switched on after the landing.
    private weak var returningChrome: UIView?
    /// Held so `interruptibleAnimator` hands UIKit the same object every time.
    private var staged: UIViewPropertyAnimator?

    init(geometry: RevealGeometry, returningChrome: UIView?) {
        self.geometry = geometry
        self.returningChrome = returningChrome
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        RevealStage.springDuration
    }

    /// ## The close springs, and `scrubsLinearly` is why it can
    ///
    /// This leg is the one a finger scrubs, and for a long time it was linear
    /// because `UIPercentDrivenInteractiveTransition` tracks 1:1 only against
    /// a linear curve. That is true — but it constrains the SCRUB, not the
    /// release, and the two were being conflated. The open has always been a
    /// spring; the close ran at constant velocity and stopped dead, and that
    /// asymmetry is what reads as stiff.
    ///
    /// A `UIViewPropertyAnimator` splits them. While the driver scrubs
    /// `fractionComplete`, `scrubsLinearly` maps progress linearly, so the page
    /// still tracks the hand exactly. On `finish()` the driver continues the
    /// animation and the animator reverts to its OWN timing — the spring
    /// below. One object, both behaviours, no branch on `isInteractive`.
    ///
    /// The chevron pop starts the same animator with no driver attached, so it
    /// wears the spring over its whole length.
    func interruptibleAnimator(
        using context: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        // UIKit asks more than once per transition and expects the SAME
        // object — a fresh one each time would stage the flight twice.
        if let staged { return staged }
        let animator = makeAnimator(using: context)
        staged = animator
        return animator
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print("[pop] reveal animate")
        }
        #endif
        interruptibleAnimator(using: context).startAnimation()
    }

    func animationEnded(_ transitionCompleted: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print("[pop] reveal ended completed=\(transitionCompleted)")
        }
        #endif
        staged = nil
    }

    private func makeAnimator(
        using context: any UIViewControllerContextTransitioning
    ) -> UIViewPropertyAnimator {
        // The open's spring, worn by the close. Same damping, so both legs
        // settle alike; the overshoot at 0.82 is a couple of points on a card
        // this size, which is the life and not a wobble.
        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: context),
            timingParameters: UISpringTimingParameters(
                dampingRatio: RevealStage.springDamping
            )
        )
        // Defaulted true, but the whole design above rests on it — said out
        // loud so nobody "tidies" it away.
        animator.scrubsLinearly = true

        let container = context.containerView
        guard let fromView = context.view(forKey: .from),
              let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to)
        else {
            animator.addAnimations {}
            animator.addCompletion { _ in context.completeTransition(false) }
            return animator
        }
        let pageFrame = fromView.frame
        toView.frame = context.finalFrame(for: toVC)
        container.insertSubview(toView, belowSubview: fromView)

        // The landing measured LAST: the grid may have scrolled, or may need
        // to pin its content inset so the row holds still for the length of
        // the close. Asked before the rect is read, never after.
        geometry.willStageDismissal()
        container.layoutIfNeeded()
        let anchor = geometry.anchorFrame(container)
        let sourceRect = geometry.sourceFrame(container) ?? RevealStage.centredFallback(in: container)

        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let (host, mask) = RevealStage.makeHost(
            around: fromView, in: container, pageFrame: pageFrame,
            // The ground a contained page sits on — see `makeHost`. Only that
            // fit promises it; a covering page fills the window by definition
            // and a clipped one is the window.
            ground: geometry.pageFit == .contained ? geometry.sourceFill : nil
        )
        let open = RevealStage.open(container: container)
        // The stand-in: the card, drawn fresh, above the page inside the same
        // window. It fades in over the flight while the page fades out under
        // it, so a page that was scrolled stops mattering the moment the
        // dismissal starts. Unscrolled, the two agree and the cross-fade is
        // the identity.
        //
        // Built BEFORE the closed pose, because whether there is one decides
        // what that pose says: a stand-in makes the page's alignment
        // meaningless, and registering the page while a card fades in over it
        // is the "scroll" artifact — the comments sliding under the stand-in
        // for the length of the grab, chasing a caption the window is no longer
        // going to show. Nothing behind it needs to move; it only has to hold
        // still and fade.
        let standIn = geometry.makeDismissStandIn()
        if let standIn {
            host.addSubview(standIn)
            standIn.alpha = RevealStage.fill(at: 0, carriesPage: geometry.pageFit.carriesPage)
            (standIn as? RevealStandInShaping)?.setContentOpacity(
                RevealStage.contentOpacity(at: 0, carriesPage: geometry.pageFit.carriesPage)
            )
        }
        // The same rule the grab leg states at length: the cell the window is
        // landing on is hidden for the whole close, or it shows beside the
        // window as a second copy of the same post. Put back below, in the same
        // transaction as the unwrap.
        geometry.setSourceConcealed(true)
        let closed = RevealStage.closed(
            sourceRect: sourceRect,
            radius: geometry.sourceCornerRadius,
            anchor: anchor,
            matchesAnchor: geometry.matchesAnchor,
            captionTop: geometry.sourceCaptionTop,
            ridingFrom: standIn != nil ? open.mask : nil,
            fit: geometry.pageFit
        )
        RevealStage.apply(open, mask: mask, page: fromView, standIn: standIn)
        geometry.setDestinationGround(nil)
        installVeil(geometry: geometry, anchor: anchor)
        installAuthorBand(geometry: geometry, anchor: anchor)
        geometry.setDestinationVeilOpacity(0)
        geometry.setDestinationAuthorBandOpacity(0)

        #if DEBUG
        RevealStage.log("pop", "landing=\(NSCoder.string(for: sourceRect))"
            + " anchor=\(anchor.map(NSCoder.string(for:)) ?? "nil")"
            + " travel=\(Int(closed.pageTranslation.y))")
        #endif

        let presenting = geometry.depthView() ?? toView
        let screenRadius = ScreenGeometry.cornerRadius(behind: container)
        ZoomFlight.applyRecededChrome(to: presenting, radius: screenRadius)
        presenting.transform = CGAffineTransform(
            scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
        )
        let chrome = returningChrome
        let chromeAlpha: CGFloat = 1
        chrome?.alpha = 0

        // The chevron has no finger, so the swap's fractions become keyframes on
        // the spring's own clock — the same schedule, the same empty beat, one
        // animation rather than two that could overlap.
        if let standIn {
            // The same schedule and the same curves the drag uses, on the
            // spring's clock. Two plain animations rather than keyframes,
            // because keyframes are linear between stops and the curves are
            // half the point — see `easeIn`/`easeOut`. This leg runs in an
            // ordinary animation context, so the blocks animate; the trap that
            // ate a timed fade before is specific to an interactive
            // transition's start.
            let shaping = standIn as? RevealStandInShaping
            // ⚠️ Against the spring's VISIBLE window, not its nominal duration.
            //
            // The fractions are a share of the window's travel, and the window
            // travels on a spring — which does nearly all of it in the first
            // half and spends the rest settling. Scheduled against the whole
            // duration, a leg that starts at 0.45 starts after the window has
            // already arrived: measured on a map marker, whose stand-in is a
            // glyph and nothing else, the glyph never appeared at all. The
            // card-shaped stand-ins hid it, because a card's fill lands at the
            // same moment the real row takes over.
            let total = transitionDuration(using: context) * RevealStage.springVisibleFraction
            // A carrier runs the short leading ramp instead of the fill's own
            // act — see `RevealStage.carryFadeEnd`. Not skipped, and not the
            // three acts either: it has to be solid before the window has
            // shrunk enough for two copies of the media to read as two.
            if geometry.pageFit.carriesPage {
                // One dissolve, late: the post is under it and opaque until the
                // very end. `setContentOpacity` is already 1 and stays there —
                // see `RevealStage.contentOpacity`.
                UIView.animate(
                    withDuration: total * (RevealStage.cardFadeEnd
                        - RevealStage.coveringFaceFadeStart),
                    delay: total * RevealStage.coveringFaceFadeStart,
                    options: [.curveEaseOut]
                ) {
                    standIn.alpha = 1
                }
            } else {
                UIView.animate(
                    withDuration: total * (RevealStage.pageFadeEnd - RevealStage.pageFadeStart),
                    delay: total * RevealStage.pageFadeStart,
                    options: [.curveEaseIn]
                ) {
                    standIn.alpha = 1
                }
            }
            UIView.animate(
                withDuration: total * (RevealStage.cardFadeEnd - RevealStage.cardFadeStart),
                delay: total * RevealStage.cardFadeStart,
                options: [.curveEaseOut]
            ) {
                shaping?.setContentOpacity(1)
            }
        }
        animator.addAnimations {
            RevealStage.apply(closed, mask: mask, page: fromView, standIn: standIn)
            // Back into the card's tone as the mask closes onto it, so the
            // last frame of the close and the row underneath are one colour.
            self.geometry.setDestinationGround(self.geometry.sourceFill)
            // …and back to showing only what the card shows, so the mask never
            // slices a sentence on its way home.
            self.geometry.setDestinationVeilOpacity(1)
            self.geometry.setDestinationAuthorBandOpacity(1)
            dim.alpha = 0
            presenting.transform = .identity
            chrome?.alpha = chromeAlpha
        }
        #if DEBUG
        // The WINDOW's own trajectory, sampled every frame — see
        // `RevealTrajectoryProbe` for why a reading taken at completion cannot
        // answer this.
        let probe = RevealTrajectoryProbe.begin("pop", tracking: mask, to: closed.mask)
        // And the STAND-IN's own, because that is the thing on screen: the
        // window can land perfectly while the card inside it does not.
        let cardProbe = standIn.flatMap {
            RevealTrajectoryProbe.begin("pop-card", tracking: $0, to: closed.mask)
        }
        #endif
        animator.addCompletion { _ in
            #if DEBUG
            probe?.finish()
            cardProbe?.finish()
            RevealStage.log("pop", "settled mask=\(NSCoder.string(for: mask.frame))"
                + " target=\(NSCoder.string(for: closed.mask))")
            #endif
            let cancelled = context.transitionWasCancelled
            // FIRST, and the order is the whole of it: the row and the window
            // are identical at the landing rect, so swapping them inside one
            // transaction is invisible — while restoring after the unwrap is a
            // frame of empty grid where the card should be. A cancelled close
            // leaves the page up, and the row stays hidden under it.
            self.geometry.setSourceConcealed(cancelled)
            standIn?.removeFromSuperview()
            RevealStage.unwrap(fromView, from: host, to: container, frame: pageFrame)
            dim.removeFromSuperview()
            presenting.transform = .identity
            ZoomFlight.clearRecededChrome(from: presenting)
            // The page is staying or going; either way it must carry no mask
            // into its life on the stack — the feed is retained and pushed
            // again.
            fromView.layer.mask = nil
            // A cancelled close leaves the page on screen, so it must own its
            // ground again; a committed one is leaving, and the retained feed
            // must not carry a borrowed colour into its next push.
            self.geometry.setDestinationGround(nil)
            self.geometry.installDestinationVeil(nil, nil)
            self.geometry.installDestinationAuthorBand(nil)
            chrome?.alpha = cancelled ? 0 : chromeAlpha
            self.geometry.dismissalDidEnd(!cancelled)
            context.completeTransition(!cancelled)
        }
        return animator
    }
}
