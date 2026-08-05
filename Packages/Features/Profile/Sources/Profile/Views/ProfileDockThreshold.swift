import CoreGraphics

/// When the profile's selector changes homes, and whether that change is worth
/// animating.
///
/// Arithmetic, pulled out of the view controller, because the symptom it exists
/// to prevent is invisible in a screenshot and tedious to reproduce by hand: a
/// selector that doubles and flashes when the header is flicked hard past the
/// line where it docks.
enum ProfileDockThreshold {
    /// The band below the dock line inside which an already-docked selector
    /// stays docked.
    ///
    /// Only below. Docking happens exactly AT the line, because the line is
    /// where the inline selector reaches the navigation bar and a moment longer
    /// puts it behind the chrome. It is coming back that needs slack, so that a
    /// viewer resting a finger on the line does not watch the selector flicker
    /// between its two homes.
    static let restingBand: CGFloat = 12

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
    static let animationSpeedLimit: CGFloat = 14

    /// Whether the selector should be docked now.
    ///
    /// ⚠️ **The band widens with SPEED, and that is the whole fix.** A fixed
    /// band only has to out-measure the jitter of a resting finger. The state
    /// that actually flaps is a fast one, where a single callback carries the
    /// header further than the entire band and the next carries it back —
    /// deceleration overshoot and rubber-banding both do exactly this. A band
    /// narrower than one step is not a band at all at the speed that needs one,
    /// so it is at least two steps wide.
    static func isDocked(
        travelled: CGFloat, dockLine: CGFloat, step: CGFloat, wasDocked: Bool
    ) -> Bool {
        guard wasDocked else { return travelled >= dockLine }
        return travelled > dockLine - max(restingBand, abs(step) * 2)
    }

    /// Whether the hand-over at this speed should be animated or simply made.
    static func isAnimated(step: CGFloat) -> Bool {
        abs(step) < animationSpeedLimit
    }
}
