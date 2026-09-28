import CoreGraphics

/// The arithmetic of the side drawer, apart from any view: how wide it is, how
/// a finger's travel becomes progress, how far a drag past "open" may stretch,
/// and whether a release lands open or closed.
///
/// Pure on purpose. `SideDrawerContainerViewController` feeds it translations
/// and velocities and applies what comes back, so every rule the gesture obeys
/// is a function a test can call with numbers — no touches, no window.
///
/// Progress is the drawer's openness: 0 = closed (the main screen covers the
/// whole display), 1 = open (the main screen has slid right by `drawerWidth`,
/// leaving a sliver). Values above 1 are the rubber band; values below 0 never
/// occur — there is nothing to the LEFT of a closed main screen to reveal.
public enum SideDrawerMotion {
    /// The drawer's share of the container's width — the reference apps (the
    /// Claude and ChatGPT iOS sidebars) leave a sliver of the main screen of
    /// roughly a sixth, wide enough to read as "the screen you came from" and
    /// to be an easy target for the tap that closes.
    public static let widthFraction: CGFloat = 0.84

    /// A ceiling for large screens and landscape, where 84% of the width would
    /// be a list with lines too long to scan.
    public static let maximumWidth: CGFloat = 380

    /// How far past fully open a drag may stretch, as a fraction of the drawer
    /// width — the limit the rubber band approaches and never reaches.
    public static let overshootLimit: CGFloat = 0.07

    /// Release velocity (points per second along x) above which the flick's
    /// direction decides, whatever the progress. Below it, the projected
    /// resting point does.
    public static let flickVelocity: CGFloat = 450

    /// How much of the release velocity to project into the resting point.
    /// UIScrollView's normal deceleration rate travels about v × 0.2 s before
    /// stopping; the same projection is used here so a drag behaves like a
    /// scroll the viewer already knows.
    public static let projectionTime: CGFloat = 0.2

    /// The drawer's width in a container `containerWidth` wide.
    public static func drawerWidth(forContainerWidth containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        return min((containerWidth * widthFraction).rounded(), maximumWidth)
    }

    /// The progress for a finger that has travelled `translation` points to
    /// the right since a drag began at `startProgress`.
    ///
    /// Tracks the finger one-to-one up to fully open, stretches with
    /// resistance beyond it, and stops dead at closed.
    public static func progress(
        startProgress: CGFloat, translation: CGFloat, drawerWidth: CGFloat
    ) -> CGFloat {
        guard drawerWidth > 0 else { return startProgress }
        let raw = startProgress + translation / drawerWidth
        return rubberBanded(raw)
    }

    /// Clamps below at 0 and applies the rubber band above 1.
    ///
    /// The band is UIScrollView's shape — `(1 − 1 / (x·c / d + 1)) · d` — which
    /// starts at the finger's own slope (so there is no kink at 1) and
    /// flattens toward `overshootLimit`, never past it.
    public static func rubberBanded(_ raw: CGFloat) -> CGFloat {
        if raw <= 0 { return 0 }
        if raw <= 1 { return raw }
        let overshoot = raw - 1
        let limit = overshootLimit
        let coefficient: CGFloat = 0.55
        let stretched = (1 - 1 / (overshoot * coefficient / limit + 1)) * limit
        return 1 + stretched
    }

    /// Whether a release at `progress`, moving at `velocity` points per second
    /// along x (positive = rightward, toward open), should settle open.
    ///
    /// A flick decides by its direction; anything slower settles wherever its
    /// projected resting point is nearer, so a slow drag past halfway opens and
    /// a slow drag short of it falls back.
    public static func shouldOpen(progress: CGFloat, velocity: CGFloat, drawerWidth: CGFloat) -> Bool {
        if velocity >= flickVelocity { return true }
        if velocity <= -flickVelocity { return false }
        guard drawerWidth > 0 else { return progress >= 0.5 }
        let projected = progress + velocity * projectionTime / drawerWidth
        return projected >= 0.5
    }

    /// The spring's initial velocity for a settle, in the unit UIKit's spring
    /// animations take: the fraction of the REMAINING distance covered per
    /// second. Zero when there is no distance left (a divide-by-zero would
    /// launch the animation at infinity).
    public static func initialSpringVelocity(
        from progress: CGFloat, to target: CGFloat, velocity: CGFloat, drawerWidth: CGFloat
    ) -> CGFloat {
        let remaining = (target - progress) * drawerWidth
        guard abs(remaining) > 0.5 else { return 0 }
        // Only a velocity heading TOWARD the target carries into the spring; a
        // release against it (a flick back that still lands on the far side of
        // halfway) starts the spring from rest instead of backwards.
        let relative = velocity / remaining
        return max(0, min(relative, 12))
    }
}
