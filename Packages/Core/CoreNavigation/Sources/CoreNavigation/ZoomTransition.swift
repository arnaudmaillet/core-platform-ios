import UIKit

/// The two-sided contract for a hero/zoom transition: a thumbnail on one screen
/// expands to fill another, and drags back into the exact same spot on dismiss.
///
/// It lives in CoreNavigation — a module both the source and destination
/// features already depend on — so neither feature imports the other. The Maps
/// pin is the `ZoomTransitionSource`; the snap feed is the
/// `ZoomTransitionDestination`. The animator (owned by the presenting side)
/// reads geometry from both and never needs their concrete types.
@MainActor
public protocol ZoomTransitionSource: AnyObject {
    /// A detached, styled copy of the thing being expanded (e.g. the pin's
    /// thumbnail square) to fly across the screen. `nil` falls back to a plain
    /// cross-fade with no hero.
    func zoomHeroSnapshot() -> UIView?
    /// The on-screen rect the hero starts from (present) / returns to (dismiss),
    /// in `container`'s coordinate space. Recomputed at dismiss time, since the
    /// source may have moved (a panned map).
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect
    /// `true` when the source is currently on screen; a dismiss to an off-screen
    /// source falls back to a centered shrink-and-fade instead of flying to a
    /// rect that isn't visible.
    var zoomSourceIsOnScreen: Bool { get }
    /// The transition finished returning; un-hide the source view.
    func zoomSourceDidReturn()
}

@MainActor
public protocol ZoomTransitionDestination: AnyObject {
    /// The rect the hero lands on (present) / lifts from (dismiss): the active
    /// page's media view, in `container`'s coordinate space.
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect
    /// Hide the real media so only the flying hero is visible during the
    /// animation (avoids a double image).
    func prepareForZoomTransition()
    /// Restore the real media once the hero has landed / been removed.
    func zoomTransitionDidEnd()
    /// Whether an interactive downward drag should begin a dismissal now — true
    /// only when the active page is at its scroll-top boundary, so mid-feed
    /// scrolling is never hijacked.
    var isReadyForInteractiveDismissal: Bool { get }
    /// Freeze/unfreeze the feed's own scrolling while a grab-to-dismiss drives,
    /// so its rubber-band doesn't fight the shrinking hero.
    func setContentScrollEnabled(_ enabled: Bool)

    /// Present: animate the info overlay (author, caption, engagement) *expanding*
    /// into place over `duration`, so the metadata grows out of the pin alongside
    /// the flying media instead of fading in flat. Uses the animator's curve and
    /// start time; safe to call before content has loaded — the destination runs
    /// it as soon as its active page exists.
    func animateInfoOverlayExpandingIn(duration: TimeInterval)
    /// Dismiss: set the info overlay's collapsed state as a transform + alpha
    /// change (no relayout). Called *inside* the animator's animation block so it
    /// scrubs in lockstep with the interactive grab; `collapsed == true` shrinks
    /// it back toward the pin.
    func setInfoOverlayCollapsed(_ collapsed: Bool)

    /// Make the destination's opaque background canvas — its own view, its scroll
    /// view, and the active cell's content background — transparent for the
    /// duration of the flight, so the source (the map) stays visible *around* the
    /// growing cell instead of being curtained off by a full-screen cross-fade.
    /// Restore with `false`. The animator, not this view, owns any dimming.
    func setZoomCanvasTransparent(_ transparent: Bool)

    /// The tapped pin's rect (in this view's coordinate space), so the info
    /// overlay can emanate from — and collapse back toward — the same point the
    /// media hero grows out of, reading as one expanding unit. Set before the
    /// info animation each leg.
    func setZoomHeroAnchor(_ heroRect: CGRect)
}
