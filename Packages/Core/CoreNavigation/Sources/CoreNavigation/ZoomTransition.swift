import UIKit

/// The two-sided contract for a hero/zoom transition: a thumbnail on one screen
/// expands to fill another, and drags back into the exact same spot on dismiss.
///
/// It lives in CoreNavigation — a module both the source and destination
/// features already depend on — so neither feature imports the other. Two pairs
/// use it today: a Maps pin and a For You grid tile are both
/// `ZoomTransitionSource`s, and the snap feed is the
/// `ZoomTransitionDestination` for each. The animator reads geometry from both
/// sides and never needs their concrete types.
@MainActor
public protocol ZoomTransitionSource: AnyObject {
    /// The on-screen rect the hero starts from (present) / returns to (dismiss),
    /// in `container`'s coordinate space. Recomputed at dismiss time, since the
    /// source may have moved (a panned map, a scrolled grid).
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect

    /// `true` when the source is currently on screen; a dismiss to an off-screen
    /// source falls back to a centered shrink-and-fade instead of flying to a
    /// rect that isn't visible.
    var zoomSourceIsOnScreen: Bool { get }

    /// The flying card: normally the same component the source renders at rest,
    /// configured from the same data, so the handshake is exact by
    /// construction rather than by agreement.
    func makeZoomFlightCard() -> any ZoomFlightCard

    /// Hide (`true`) the real source view while its twin is flying, and restore
    /// it (`false`) when the flight is over. Called inside the same transaction
    /// that installs or retires the card, so no frame can render both — or
    /// neither.
    func setZoomSourceHidden(_ hidden: Bool)

    /// The view the depth cue should recede, when it is not the presenter's
    /// whole view.
    ///
    /// The cue is a scale about the receding view's centre, so *everything*
    /// inside it both shrinks and drifts toward that centre. On a map that is
    /// exactly right — the map IS the content. On a screen that carries its own
    /// chrome, it is not: a filter tray pinned near the bottom edge visibly
    /// slides up and shrinks while the app's tab bar, which lives outside the
    /// presenter, stays nailed down — measured here at 17pt of travel and a 5%
    /// size change, against a tab bar that moved 0. Half the furniture drifting
    /// and half of it grounded reads as a glitch rather than as depth.
    ///
    /// Naming a narrower view puts the cue on the content and leaves the chrome
    /// alone. The chrome still cross-fades under the flight's dim, which is a
    /// pure opacity change and stays put. Default `nil` keeps the presenter's
    /// whole view, which is what a map wants.
    var zoomPresenterDepthView: UIView? { get }

    /// Last chance to move before a *dismissal* stages: the source may need to
    /// bring the landing target on screen (a grid scrolling a tile into view)
    /// or re-point at what the destination ended on. Called before the landing
    /// rect is read. Defaults to nothing — a map pin is wherever the map left it.
    func zoomSourceWillStageDismissal()

    /// Takes the flight card's live media view at LANDING, so this side is
    /// already rendering before the card is removed.
    ///
    /// Without it the card disappears and the target starts its own player,
    /// whose fresh layer is blank for ~100ms — the flash at the END of the
    /// flight. The view travels source -> card -> destination (and back on a
    /// dismissal) and is never re-created, so there is nothing to wait for.
    func zoomAdoptLiveMediaView(_ view: UIView)


    /// Whether the surface this side will show after landing is already
    /// rendering a decoded frame.
    ///
    /// The card is posed exactly over the source at landing and shows the same
    /// content, so it can be held for a few frames while the answer is false —
    /// which is what turns an unavoidable `isReadyForDisplay` dip into
    /// something the viewer never sees. Default true: a source with no live
    /// media has nothing to wait for.
    var zoomLandingMediaIsReady: Bool { get }

    /// Forces the landing target to finish its layout before the flight card
    /// is taken away.
    ///
    /// `zoomLandingMediaIsReady` answers about the SURFACE; this is about the
    /// cell around it. A cell can report a drawing surface while its own
    /// subview composition is still pending a layout pass, and unmounting the
    /// card into that gap is a one-frame flash at the very end of the landing.
    /// Default is nothing — a source whose landing needs no pass has none to
    /// force.
    func zoomFinalizeLanding()

    /// Takes the flight card's live surface and hosts it ABOVE the navigation
    /// controller for the duration of a dismissal, positioned at `rect`.
    ///
    /// A navigation controller removes non-top views from the window, so a
    /// surface left in the card — or in either screen — leaves the render tree
    /// and its layer re-acquires on the way back. Hosting it one level up means
    /// it never leaves, and the flight becomes pure geometry. Returns whether
    /// the source took it; `false` leaves the card flying it as before.
    /// `cornerRadius` is the radius the surface must START at — the page's
    /// display-corner radius — so it interpolates to the tile's radius on the
    /// same spring as the card. Hoisting without it left the surface at 0 while
    /// the card animated 55 -> 10: square corners over rounded ones for the
    /// whole flight, converging only at the very end, which reads as a snap.
    func zoomHoistLiveMedia(_ view: UIView, at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) -> Bool

    /// Poses the hosted surface. Called inside the flight's animation block, so
    /// it interpolates on the same spring as the card.
    func zoomPoseHoistedMedia(at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat)

    /// Un-hoists the dismissal's live surface and hands it back, for a flight
    /// the viewer REVERSED.
    ///
    /// A hoisted surface is parented above the navigation controller and is no
    /// longer reachable through `zoomLiveMediaSurface` — a card poses only
    /// media it still contains. Without this a cancelled dismissal left it
    /// hosted, drawing at the grid cell's rect over the feed that just came
    /// back. `nil` when nothing is hosted.
    func zoomReleaseHoistedMedia() -> UIView?
}

public extension ZoomTransitionSource {
    var zoomPresenterDepthView: UIView? { nil }
    func zoomSourceWillStageDismissal() {}
    func zoomAdoptLiveMediaView(_ view: UIView) {}
    var zoomLandingMediaIsReady: Bool { true }
    func zoomFinalizeLanding() {}
    /// `cornerRadius` is the radius the surface must START at — the page's
    /// display-corner radius — so it interpolates to the tile's radius on the
    /// same spring as the card. Hoisting without it left the surface at 0 while
    /// the card animated 55 -> 10: square corners over rounded ones for the
    /// whole flight, converging only at the very end, which reads as a snap.
    func zoomHoistLiveMedia(_ view: UIView, at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) -> Bool { false }
    func zoomPoseHoistedMedia(at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) {}
    func zoomReleaseHoistedMedia() -> UIView? { nil }
}

@MainActor
public protocol ZoomTransitionDestination: AnyObject {
    /// Whether the destination has content to reveal yet.
    ///
    /// A pushed screen whose data has not arrived has nothing to lay out, so
    /// removing the flight card exposes its background — measured at 1000ms
    /// injected latency as the feed sitting empty for 2.18s after the flight
    /// began, against a flight that lasts 0.42s. The card is a full-bleed
    /// cover of the very post being opened, so holding it there is both
    /// truthful and better-looking than the alternative.
    ///
    /// Defaults to `true`: a destination that is ready the moment it is pushed
    /// (anything not network-backed) opts out by saying nothing.
    var zoomDestinationContentIsReady: Bool { get }

    /// Whether the destination fades ITSELF in over the flight instead of
    /// being revealed at landing.
    ///
    /// The default is the original contract: the destination is hidden for the
    /// whole flight and the card stands in for all of it, which is right when
    /// the card can BE the destination — a media page is its media, and the
    /// card carries the same pixels full-bleed, so the swap is invisible.
    ///
    /// It is wrong when the card cannot be the destination. A text page is its
    /// COMMENTS, and a row card has no comments in it; standing in for them
    /// meant photographing the page and flying the photo, which put every
    /// failure on the same fault line — the photograph taken a moment too
    /// early, or of a page not yet mounted, or of glass that does not survive
    /// `layer.render(in:)`. Fading the real thing in has nothing to photograph
    /// and nothing to keep in sync: what arrives IS the destination.
    ///
    /// The card still flies, and still carries what IS continuous (a text
    /// row's caption). It simply stops pretending to be the rest.
    var zoomCrossfadesDuringFlight: Bool { get }

    /// Where the destination will show the post's caption, in its own view's
    /// coordinates, or nil if it shows none.
    ///
    /// A hero is only continuous for the elements that exist at BOTH ends. A
    /// caption does — the source row has one and the page has one — so the
    /// card lands its copy on the page's, and the page fading in underneath
    /// takes over without anything moving. Left alone, the card's caption sat
    /// where the ROW puts one and the page's appeared somewhere else, which
    /// reads as two captions rather than one.
    var zoomFlightCaptionFrame: CGRect? { get }

    /// Whether the destination's active page is actually COMPOSITING its
    /// media area — a drawing surface, or a poster/cover in place.
    ///
    /// `zoomDestinationContentIsReady` answers about DATA, and data is not
    /// pixels: a page can have its post and still have nothing in its media
    /// area for a beat (a surface whose first composite lags, a poster still
    /// decoding). The present landing reveals the destination and retires
    /// the card in one commit, so gating that on data alone swapped the card
    /// for a black media area — measured on device as a flash at the exact
    /// end of the present. Defaults to `true`: a destination with no media
    /// area has nothing to wait for.
    var zoomDestinationMediaIsRendering: Bool { get }
    /// The full rect the flying card lands on (present) / lifts from (dismiss),
    /// in `container`'s coordinate space — the active page's bounds.
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect

    /// A fresh, *inert*, full-bleed replica of the active page's chrome
    /// (scrim, caption, engagement rail — page content only, never navigation
    /// bar chrome, which stays real and static above the flight), configured
    /// from the post's data if it has already loaded. The animator embeds it
    /// in its flying card above the media, so chrome and media share one
    /// animated matrix and are geometrically incapable of drifting.
    ///
    /// The destination keeps a weak reference until `zoomTransitionDidEnd` and
    /// re-configures the replica if the post hydrates mid-flight (a cold tap):
    /// the scaffold's geometry is data-independent, so late text fills in
    /// without moving anything. Return `nil` to fly media-only.
    func zoomFlightChrome() -> UIView?

    /// Hide (`true`) or restore (`false`) the destination's *content* — its own
    /// view, not its navigation bar. During a flight the card impersonates the
    /// page while the presented container stays visible, so the real bar keeps
    /// its native screen-space layout from frame 0 and never pops or morphs;
    /// the card flies beneath it.
    func setZoomContentHidden(_ hidden: Bool)

    /// The flight is over (landed, returned, or cancelled): release the flight
    /// chrome reference and any transition-scoped state.
    func zoomTransitionDidEnd()

    /// A presentation is about to stage. Called before the destination is laid
    /// out, which is the only moment early enough to matter.
    ///
    /// The destination must not begin rendering media of its own while a card
    /// is flying its player: with several layers on one player, whichever
    /// attaches last is the one that displays, so a destination that starts
    /// playing mid-flight silently blanks the card. Implementations defer
    /// their own playback until `zoomTransitionDidEnd`.
    ///
    /// Default is nothing — a destination with no media has nothing to defer.
    func zoomTransitionWillBegin()

    /// Detaches the destination's live player and parks it for whoever plays
    /// the same asset next — the source it is flying home to. Called on the
    /// DISMISS leg once the card has taken over rendering.
    ///
    /// Without this the source starts a fresh item on landing and the video
    /// jumps back to zero exactly as the card settles. Returns whether
    /// anything was parked. Default is "nothing to hand over".
    @discardableResult
    func zoomParkLiveMediaForHandoff() -> Bool

    /// Hands over the destination's already-rendering media view, for the card
    /// to fly directly.
    ///
    /// Preferred over `zoomMirrorLiveMedia`, which builds a SECOND
    /// `AVPlayerLayer` — and a fresh layer has no decoded frame, reporting
    /// `isReadyForDisplay == false` for ~70ms while the destination is already
    /// hidden. That window is the flash at the start of a dismissal. Moving the
    /// live view has no such window. `nil` when nothing is playing.
    func zoomDonateLiveMediaView() -> UIView?

    /// Puts a donated view back and resumes rendering into it — the abandoned
    /// dismissal, where the destination stays on screen and must look untouched.
    func zoomReclaimLiveMediaView(_ view: UIView)

    /// Takes the flight card's live media view at LANDING, so this side is
    /// already rendering before the card is removed.
    ///
    /// Without it the card disappears and the target starts its own player,
    /// whose fresh layer is blank for ~100ms — the flash at the END of the
    /// flight. The view travels source -> card -> destination (and back on a
    /// dismissal) and is never re-created, so there is nothing to wait for.
    func zoomAdoptLiveMediaView(_ view: UIView)

    /// Attaches the destination's live media player — if its active page is
    /// playing one — onto `surface` as an additional render layer, so a
    /// dismissal flight carries the live video rather than a frozen cover.
    /// `surface` is typed loosely (`UIView`) to keep this module
    /// playback-agnostic; the destination downcasts to its own render-surface
    /// type and refuses gracefully. Defaults to "no live media".
    func zoomMirrorLiveMedia(onto surface: UIView) -> Bool

    /// Whether an interactive grab may begin a dismissal right now — false
    /// while the destination's own scrolling still owns the user's intent
    /// (e.g. a page-snap fling that hasn't settled).
    var isReadyForInteractiveDismissal: Bool { get }
    /// Freeze/unfreeze the feed's own scrolling while a grab-to-dismiss drives,
    /// so its rubber-band doesn't fight the shrinking card.
    func setContentScrollEnabled(_ enabled: Bool)
}

public extension ZoomTransitionDestination {
    var zoomDestinationContentIsReady: Bool { true }
    var zoomCrossfadesDuringFlight: Bool { false }
    var zoomFlightCaptionFrame: CGRect? { nil }
    var zoomDestinationMediaIsRendering: Bool { true }
    func zoomMirrorLiveMedia(onto surface: UIView) -> Bool { false }
    func zoomDonateLiveMediaView() -> UIView? { nil }
    func zoomReclaimLiveMediaView(_ view: UIView) {}
    func zoomAdoptLiveMediaView(_ view: UIView) {}
    func zoomTransitionWillBegin() {}
    @discardableResult
    func zoomParkLiveMediaForHandoff() -> Bool { false }
}
