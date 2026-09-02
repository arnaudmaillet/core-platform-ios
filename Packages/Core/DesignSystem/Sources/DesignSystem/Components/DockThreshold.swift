import CoreGraphics

/// When a screen's leading selector changes homes, and whether that change is
/// worth animating.
///
/// Arithmetic, pulled out of the view controller, because the symptom it exists
/// to prevent is invisible in a screenshot and tedious to reproduce by hand: a
/// selector that doubles and flashes when the header is flicked hard past the
/// line where it docks.
///
/// ⚠️ **Two screens run this, and a viewer moving between them must not be able
/// to tell.** The profile and the place page dock the same selector out of the
/// same kind of header; the moment their numbers differ the hand-over is two
/// slightly different animations wearing one design, and the difference reads as
/// a fault in whichever screen is met second. That is why the arithmetic left
/// the Profile package. A screen that wants a different band changes it here,
/// for both — forking a constant is not a local tuning decision.
public enum DockThreshold {
    /// The band below the dock line inside which an already-docked selector
    /// stays docked.
    ///
    /// Only below. Docking happens exactly AT the line, because the line is
    /// where the inline selector reaches the navigation bar and a moment longer
    /// puts it behind the chrome. It is coming back that needs slack, so that a
    /// viewer resting a finger on the line does not watch the selector flicker
    /// between its two homes.
    public static let restingBand: CGFloat = 12

    /// How far the header may travel between two scroll callbacks and still get
    /// the animated hand-over.
    ///
    /// **A crossfade shows both selectors at once — that is what a crossfade
    /// IS.** At reading speed that is the point: the two overlap for a quarter
    /// of a second and the eye reads one control changing places. Past this
    /// speed it stops working, because the inline selector is still TRAVELLING
    /// while it fades, so the two are visibly separate objects sliding apart and
    /// the swap reads as a doubled, flashing bar.
    ///
    /// Measured on a hard flick at 30fps: four consecutive frames with both
    /// selectors fully legible, the inline one moving through all four.
    ///
    /// 14pt a callback is a little above a brisk read — an ordinary scroll moves
    /// the header 6–10pt a frame — so scrolling still gets the animation and only
    /// a flick skips it.
    public static let animationSpeedLimit: CGFloat = 14

    /// Whether the selector should be docked now.
    ///
    /// ⚠️ **The band widens with SPEED, and that is the whole fix.** A fixed
    /// band only has to out-measure the jitter of a resting finger. The state
    /// that actually flaps is a fast one, where a single callback carries the
    /// header further than the entire band and the next carries it back —
    /// deceleration overshoot and rubber-banding both do exactly this. A band
    /// narrower than one step is not a band at all at the speed that needs one,
    /// so it is at least two steps wide.
    public static func isDocked(
        travelled: CGFloat, dockLine: CGFloat, step: CGFloat, wasDocked: Bool
    ) -> Bool {
        guard wasDocked else { return travelled >= dockLine }
        return travelled > dockLine - max(restingBand, abs(step) * 2)
    }

    /// Whether the hand-over at this speed should be animated or simply made.
    public static func isAnimated(step: CGFloat) -> Bool {
        abs(step) < animationSpeedLimit
    }

    /// How far before the dock line the identity block finishes fading out.
    ///
    /// Long enough to read as a fade rather than a blink; short enough that the
    /// block is at full strength for almost all of its travel, since it is the
    /// thing the viewer came to read.
    public static let identityFadeDistance: CGFloat = 90

    /// How visible the identity block — the avatar, name and detail a header
    /// leads with — should be for a given header position.
    ///
    /// ⚠️ **Driven by the SCROLL, not by the docking state.** Docking is a
    /// discrete event that a flick can cross at 150pt a frame; an alpha animated
    /// on that event would still be running long after the block had travelled
    /// somewhere else, and at speed it would simply pop — which is the same
    /// mistake, in a second place, that made the selector double. Read from the
    /// offset instead, the block is exactly as faded as its position says it
    /// should be on every frame, at any speed, in either direction, with no
    /// state of its own to get out of step.
    ///
    /// It reaches zero exactly AT the dock line, which is what lets the host
    /// stop being hidden there: nothing is drawn, so nothing bleeds through the
    /// transparent navigation bar, and nothing has to pop to make that true.
    public static func identityAlpha(travelled: CGFloat, dockLine: CGFloat) -> CGFloat {
        guard dockLine > 0, identityFadeDistance > 0 else { return 1 }
        let start = dockLine - identityFadeDistance
        let faded = (travelled - start) / identityFadeDistance
        return 1 - min(max(faded, 0), 1)
    }
}
