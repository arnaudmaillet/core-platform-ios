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
    /// thumbnail square), embedded full-bleed as the flying card's media layer.
    /// `nil` flies the card without media (chrome over its black backing).
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
    /// The full rect the flying card lands on (present) / lifts from (dismiss),
    /// in `container`'s coordinate space — the active page's bounds.
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect

    /// A fresh, *inert*, full-bleed replica of the active page's UI chrome
    /// (scrim, author block, caption, engagement rail), configured from the
    /// post's data if it has already loaded. The animator embeds it in its
    /// flying card above the media, so chrome and media share one animated
    /// matrix and are geometrically incapable of drifting.
    ///
    /// The destination keeps a weak reference until `zoomTransitionDidEnd` and
    /// re-configures the replica if the post hydrates mid-flight (a cold tap):
    /// the scaffold's geometry is data-independent, so late text fills in
    /// without moving anything. Return `nil` to fly media-only.
    func zoomFlightChrome() -> UIView?

    /// The flight is over (landed, returned, or cancelled): release the flight
    /// chrome reference and any transition-scoped state.
    func zoomTransitionDidEnd()

    /// Whether an interactive downward drag should begin a dismissal now — true
    /// only when the active page is at its scroll-top boundary, so mid-feed
    /// scrolling is never hijacked.
    var isReadyForInteractiveDismissal: Bool { get }
    /// Freeze/unfreeze the feed's own scrolling while a grab-to-dismiss drives,
    /// so its rubber-band doesn't fight the shrinking card.
    func setContentScrollEnabled(_ enabled: Bool)
}
