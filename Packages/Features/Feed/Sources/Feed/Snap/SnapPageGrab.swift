import LaunchArguments
import Transitions
import UIKit

/// What the grab asks of its page (#2521): the content view it masks and
/// grounds, the media card it hides, and the two stages it moves.
@MainActor
protocol SnapPageGrabHost: AnyObject {
    var contentView: UIView { get }
    var mediaCard: SnapMediaCardView { get }
    var pageStage: UIView { get }
    var stages: [UIView] { get }
}

/// The live grab (#1915) and the engaged dismissal (#2362) on the full-screen
/// page, out of `SnapFeedCell` (#2521): the page following the card under a
/// window shaped like it, its interface fading only on the release, and the
/// page put back on either outcome.
///
/// ⚠️ CORE ANIMATION TIMING: `setEngagedDismissal` is called in the zoom
/// destination's turn, from inside the release's animation block on the
/// way home, so UIKit interpolates it on the card's spring. A held state
/// removes what a release left in flight and assigns the centre without
/// animation. The page's forwards are plain calls, so all of it runs where
/// it ran.
///
/// Shared with the page, borrowed at `beginLiveGrab` and handed back at
/// `endEngagedDismissal`: `mediaCard.alpha` (the sheet pose and the reuse
/// write it too), `contentView.backgroundColor` (also `configure`, the
/// reveal tint and the reuse), the stages' alpha — `columnStage.alpha`
/// with the sheet pose — centre, transform and touches, and
/// `contentView.mask`.
@MainActor
final class SnapPageGrab {
    private unowned let host: any SnapPageGrabHost

    init(host: any SnapPageGrabHost) {
        self.host = host
    }

    // The page's state, read where the cell's code read it.
    private var contentView: UIView { host.contentView }
    private var mediaCard: SnapMediaCardView { host.mediaCard }
    private var pageStage: UIView { host.pageStage }
    private var stages: [UIView] { host.stages }

    /// The window a masked-hero opening is seen through — see
    /// `beginMaskedRevealForFlight`. Non-nil only for the length of a flight.
    private(set) var flightMask: UIView?
    private var alphaForMaskedReveal: CGFloat = 1
    private var groundForMaskedReveal: UIColor?
    /// ⚠️ ITS OWN FLAG, not a re-read of `groundForMaskedReveal`.
    ///
    /// The opening and the dismissal borrow the same two preparations — the
    /// media hidden, the ground cleared — and the first version guarded the
    /// dismissal on the stored ground being nil. A masked OPENING leaves that
    /// ground stored, so the dismissal that followed it declined to run and
    /// the thread stopped receding on exactly the pages that opened with one.
    private(set) var isEngagedDismissing = false
    /// Whether the grab moving the page is a live grab (#1915): the page's
    /// whole interface rides it, untouched until the release commits — not
    /// the engaged thread, which recedes with the finger.
    private(set) var isLiveGrab = false
    /// The grab's current mapping of page onto card — the scale, and the rect
    /// it is mapping onto — held so a layout pass cannot be the last word on
    /// where the page is.
    /// What each travelling layer's opacity was when the grab began — an
    /// abandoned one has to put back exactly that, and a starting one has to
    /// begin from it.
    private var restingAlphas: [CGFloat] = []

    /// **THE LIVE GRAB (#1915)**: the page follows the card as the engaged
    /// dismissal's does — one stage transform, under a window shaped like the
    /// card — with its whole interface on it, alive. Only the media leaves the
    /// page: the card carries it (the donated surface, still playing).
    ///
    /// - Nothing fades while the finger is down. On the release, a commit
    ///   fades the interface inside the release's spring, and a cancel
    ///   leaves it as it was (`setEngagedDismissal`).
    /// - The page takes no touch while held: the grab owns the finger.
    /// - The interface does not reflow under its transform: its insets are
    ///   the frozen ones (`applyChromeInsets`), never the stage's safe area.
    func beginLiveGrab() {
        guard !isEngagedDismissing else { return }
        isEngagedDismissing = true
        isLiveGrab = true
        // Alpha, never `isHidden`: a hidden surface stops feeding the card's
        // sibling surface (`beginEngagedDismissal`).
        alphaForMaskedReveal = mediaCard.alpha
        mediaCard.alpha = 0
        groundForMaskedReveal = contentView.backgroundColor
        contentView.backgroundColor = .clear
        restingAlphas = dismissalTravellers.map(\.alpha)
        stages.forEach { $0.isUserInteractionEnabled = false }
    }

    /// ⚠️ A PURE FUNCTION OF THE FINGER, never an animation.
    ///
    /// The grab can be pushed forward, dragged back and abandoned; anything
    /// that animated towards a target here would be chasing a value that has
    /// already moved, and a cancelled grab would leave the page mid-flight.
    /// The dim and the toolbar recede on exactly these terms. (The RELEASE is
    /// the exception, and it is not one: the same call is made from inside the
    /// release's own animation block, so UIKit interpolates it on the card's
    /// spring rather than on a second one.)
    func setEngagedDismissal(_ state: ZoomDismissState) {
        guard isEngagedDismissing else { return }
        let settling = state.isSettling
        let t = min(max(state.progress, 0), 1)
        // The thread and its wash recede together, on one value — each from
        // where it already was. The photograph is the card's and is not this
        // method's business at all — see `beginEngagedDismissal`.
        //
        // A live grab's interface does not recede under the finger (#1915):
        // it is the page, held. It fades only on the release's way home, in
        // its spring — `t` is 1 there, and 0 on a cancel's.
        let fade = isLiveGrab ? (settling ? t : 0) : t
        for (view, resting) in zip(dismissalTravellers, restingAlphas) {
            view.alpha = resting * (1 - fade)
        }
        guard state.card.width > 0, state.card.height > 0 else { return }
        // ⚠️ THE PAGE OVERHANGS THE CARD BY A HAIR, and this is the answer to a
        // light leak rather than a cosmetic tweak.
        //
        // Nothing here can be exact. The page FOLLOWS the card — told its rect
        // on a channel, applied a hop later, from another view hierarchy — and
        // a follower can be made arbitrarily close and never identical. (Being
        // a passenger inside the card would be exact, and is not available: the
        // thread is a hosted child controller's view, and UIKit throws
        // `UIViewControllerHierarchyInconsistency` the moment such a view is
        // moved out of its parent's hierarchy. Tried; it crashes on the first
        // grab.)
        //
        // What a fraction of a point exposed was a BRIGHT edge: inside the
        // window the card's photograph carries the page's wash, outside it the
        // card is undimmed, so any gap read as a sliver of light on a dark
        // page. So the page is drawn a little larger than the card it covers.
        // The error is still there and now falls the other way — a hair of wash
        // over the dimmed feed.
        //
        // ⚠️ HALF A POINT, AND ONLY WHILE THE FINGER IS DOWN.
        //
        // Two points was visible on both counts: the wash overhung the
        // photograph on all four sides, and a cancelled grab animated to a page
        // two points too large and then snapped to its real size when the
        // gesture was torn down. A bleed exists to swallow SUB-PIXEL error —
        // fractional rects, one rounding — and half a point is already three
        // device pixels. Anything a bleed would have to be to hide a real lag
        // is a bleed you can see.
        //
        // The release carries none: `settling` means the card is going to a
        // known rect and the page must arrive exactly there, so a cancelled
        // grab lands on its own size and the teardown has nothing to correct.
        let card = settling
            ? state.card
            : state.card.insetBy(dx: -Self.dismissalBleed, dy: -Self.dismissalBleed)
        // ⚠️ FILL, NOT FIT — and it moves the THREAD now, which is all that is
        // left to move.
        //
        // The arithmetic is kept because it is why the photograph is no longer
        // here. Three mappings were tried while the page still drew its own:
        // by WIDTH it ended a different shape from the card (`x=0.776 y=0.495`
        // at the release — 57% too tall); by BOTH AXES the frames agreed and
        // the image was squashed; FILL kept the ratio and still re-cropped,
        // because a crop of a crop is not the crop. Only removing the second
        // copy settles it.
        //
        // Fill stays for the thread: it keeps the text's proportions while the
        // window takes the overflow.
        let fill = max(
            card.width / max(contentView.bounds.width, 1),
            card.height / max(contentView.bounds.height, 1)
        )
        // ⚠️ ONE VIEW, ONE TRANSFORM. Everything the page draws is inside
        // `pageStage`, so the mapping is applied once, about one centre, in one
        // assignment — and a layout pass cannot erase it, because nothing but
        // this cell writes that view's geometry.
        //
        // It was a transform per layer before, which is correct arithmetic (a
        // view transform is applied about its own centre, so each needed its
        // own translation) and a permanent source of one-frame disagreements: a
        // layout pass, a spring in flight and a gesture event are three
        // different moments, and four layers told the same thing at three
        // moments is four chances to be told late.
        // ⚠️ TWO CHANNELS, BECAUSE THE CARD HAS TWO — and folding them into one
        // transform is what put the page BEHIND the card.
        //
        // The flight's grab drives the card's POSITION directly on every pan
        // event and its SIZE on a spring (the detach dip). A single affine
        // carrying both meant the page's position was animating toward a centre
        // the card had already left: told inside the dip's block, it chased a
        // moving target and lagged it by the whole of the dip. On screen that
        // is the comments and the wash sitting a few dozen points behind the
        // photograph — the same numbers, arriving late.
        //
        // So the page is decomposed exactly as the card is: the centre is
        // assigned, live, and only the scale is left to whatever animation is
        // in flight.
        // ⚠️ AND THE CENTRE IS ASSIGNED OUTSIDE ANY ANIMATION while the finger
        // is down. Inside the dip's block it animated like everything else, so
        // it was interpolating toward a position the card had already left —
        // measured trailing it by 7pt across and 12pt down at a tenth of the
        // gesture, which is the comments and the wash sitting visibly behind
        // the photograph. The release is the one time it should spring, and
        // that is what `settling` says.
        let centre = CGPoint(x: card.midX, y: card.midY)
        // ⚠️ A HELD STATE DROPS WHAT A RELEASE LEFT IN FLIGHT (#2362). A grab
        // during a cancel's spring catches the card where it is and says so
        // here, as a held state, mid-spring: the stages and the window still
        // carry the release's animations — additive ones on position and
        // transform, which would keep adding what they had left onto the
        // caught pose, the page parting from the card until the spring ended.
        // A held grab animates nothing here, so whatever is in flight is the
        // release's; a layer without animations costs a nil check.
        if !settling {
            stages.forEach { if $0.layer.animationKeys() != nil { $0.layer.removeAllAnimations() } }
            if let mask = flightMask, mask.layer.animationKeys() != nil { mask.layer.removeAllAnimations() }
        }
        if settling {
            stages.forEach { $0.center = centre }
        } else {
            UIView.performWithoutAnimation { stages.forEach { $0.center = centre } }
        }
        stages.forEach { $0.transform = CGAffineTransform(scaleX: fill, y: fill) }
        // ⚠️ THE CARD'S RADIUS, HANDED OVER — never a second copy of the curve.
        //
        // The window computed its own interpolation from the display's corner
        // to the row's, which is the right shape and was not the card's: the
        // card held the display's radius flat for the whole drag, so the two
        // silhouettes were rounded differently for the length of the gesture.
        // The card interpolates now (`grabCornerRadius`) and passes the number
        // it used, so there is one curve and no way to disagree about it.
        let window = flightMask ?? makeDismissalWindow()
        window.frame = card
        window.layer.cornerRadius = state.cornerRadius
        #if DEBUG
        if LaunchArgument.grabLog.isPassed() {
            // The two rects that must be the same rect: where the window is,
            // and where the page actually landed after its transform. A gap
            // between them is the gap on screen, and nothing else can be.
            // The card's PRESENTATION frame beside the page's, in the same
            // space — the only comparison that can catch one lagging the
            // other. Comparing the window's rect to the page's proved nothing:
            // both are derived from the same converted number in the same
            // breath, so they agreed while the card was somewhere else.
            print(String(format: "[grab] t=%.2f fill=%.3f card=%@ stage=%@",
                         t, fill, NSCoder.string(for: card),
                         NSCoder.string(for: pageStage.layer.presentation()?.frame
                                            ?? pageStage.frame)))
        }
        #endif
    }

    /// The views the grab moves and fades: the two stages, the whole page —
    /// its media already handed to the card (#1915).
    var dismissalTravellers: [UIView] { stages }

    /// How far the page overhangs the card it covers. Small enough to be
    /// invisible where it spills, large enough to swallow a follower's error.
    private static let dismissalBleed: CGFloat = 0.5

    /// The dismissal's window, made on the first event that has a card to
    /// follow rather than at `begin` — a mask installed at a rect nobody has
    /// computed yet is a blank page.
    private func makeDismissalWindow() -> UIView {
        let mask = UIView()
        // Opaque: a mask reads its alpha channel, so a clear view masks
        // everything away — a blank screen rather than a clipped one.
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        contentView.mask = mask
        flightMask = mask
        return mask
    }

    /// Puts the page back, on either outcome. An abandoned grab returns to a
    /// page that must be exactly what it was.
    func endEngagedDismissal() {
        guard isEngagedDismissing else { return }
        isEngagedDismissing = false
        stages.forEach {
            $0.transform = .identity
            $0.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        }
        for (view, resting) in zip(dismissalTravellers, restingAlphas) {
            view.alpha = resting
        }
        restingAlphas = []
        if isLiveGrab {
            isLiveGrab = false
            stages.forEach { $0.isUserInteractionEnabled = true }
        }
        // The wash comes back with everything else: an abandoned grab returns
        // to a page that has to be readable again.
        contentView.mask = nil
        flightMask = nil
        mediaCard.alpha = alphaForMaskedReveal
        contentView.backgroundColor = groundForMaskedReveal
        groundForMaskedReveal = nil
    }
}

extension SnapFeedCell: SnapPageGrabHost {}
