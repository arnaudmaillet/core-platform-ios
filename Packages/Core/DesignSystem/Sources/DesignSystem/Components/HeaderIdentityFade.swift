import CoreGraphics

/// How visible a header's identity block — the avatar, name and detail a
/// profile-shaped screen leads with — is for a given header position.
///
/// # What this used to be, and why only the fade is left
///
/// It was `DockThreshold`: the arithmetic of a selector changing HOMES, with a
/// speed-widened band (`isDocked`) and a speed limit on the crossfade
/// (`isAnimated`). Both existed to stop one symptom — a selector that doubled
/// and flashed when the header was flicked hard past the line where it docked,
/// measured at four consecutive frames with both copies fully legible.
///
/// ⚠️ **THE SYMPTOM CANNOT HAPPEN ANY MORE, WHICH IS WHY THE CODE IS GONE
/// RATHER THAN KEPT "IN CASE".** Nothing docks: every tab selector lives at the
/// foot of the screen for the whole of its screen's life — a `UITabAccessory`
/// where the tab bar is under it, the navigation controller's bottom toolbar
/// where it is not. There is no second copy to cross-fade into, no line to
/// cross, and no speed at which crossing it looks wrong. A band and a speed
/// limit with no docking left to govern are not a safety net; they are two
/// constants a future reader would try to reconcile with a screen that has no
/// docking in it.
///
/// The fade survives because the header still TRAVELS: the identity block still
/// has to be gone by the time the header meets the navigation bar.
public enum HeaderIdentityFade {
    /// How far before the dock line the identity block finishes fading out.
    ///
    /// Long enough to read as a fade rather than a blink; short enough that the
    /// block is at full strength for almost all of its travel, since it is the
    /// thing the viewer came to read.
    public static let distance: CGFloat = 90

    /// How visible the identity block should be for a given header position.
    ///
    /// ⚠️ **Driven by the SCROLL, not by a state change.** An alpha animated on
    /// a discrete event would still be running long after the block had
    /// travelled somewhere else, and at speed it would simply pop — the same
    /// mistake that made the selector double, in a second place. Read from the
    /// offset instead, the block is exactly as faded as its position says on
    /// every frame, at any speed, in either direction, with no state of its own
    /// to get out of step.
    ///
    /// It reaches zero exactly AT the dock line, which is what lets the host
    /// stop being hidden there: nothing is drawn, so nothing bleeds through the
    /// transparent navigation bar, and nothing has to pop to make that true.
    public static func alpha(travelled: CGFloat, dockLine: CGFloat) -> CGFloat {
        guard dockLine > 0, distance > 0 else { return 1 }
        let start = dockLine - distance
        let faded = (travelled - start) / distance
        return 1 - min(max(faded, 0), 1)
    }
}
