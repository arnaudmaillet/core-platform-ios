import Foundation

/// Whether the map may be touched, and whether it may open anything.
///
/// # Why this exists as a type
///
/// The rule was two booleans set in three branches and released from five
/// unrelated places, and nothing at all wrote the map's interaction. What
/// actually stopped a finger during a hero flight was a full-container shield
/// the ANIMATOR happens to install; the reveal route installs none, and is
/// covered only because its host view sits over the whole screen. Two accidents
/// with different coverage, neither of them the product rule.
///
/// The rule is one sentence: **while a transition owns the screen, the map is
/// inert.** Not scrolled by accident, not able to open a second post, not able
/// to push another screen onto the stack the flight is animating on. And the
/// hard half: it becomes live again on EVERY ending, including the ones nobody
/// thinks about.
///
/// ## The two endings that were wrong
///
/// - A **reversed present** — the flight caught mid-air and thrown back — had
///   no handler on the map at all. `activeTransition` stayed set, and since it
///   is both the lock and the state handle, every marker tap for the rest of
///   the session did nothing. On screen that reads as broken markers, not as a
///   stuck animation, which is why it could survive.
/// - The tap lock was released in `viewWillAppear`, which UIKit runs at
///   interactive-pop **begin**. From the first millimetre of a grab until it
///   was cancelled, the map believed nothing was open.
///
/// ## Pure on purpose
///
/// No `MKMapView`, no view controller, no UIKit. The truth table is the thing
/// worth pinning, and it is pinned headlessly — `MapsViewController` keeps one
/// instance and applies its two answers. Same doctrine as
/// `MapMarkerPresentation` and the place-page stack rules.
struct MapOpenGate: Equatable {

    /// How a post was opened, kept because the endings differ per route: the
    /// hero reports through the transition controller, the reveal through its
    /// origin's `dismissalDidEnd`, and a plain push only through appearance.
    enum Route: Equatable {
        case hero
        case reveal
        case plainPush
        /// The defensive branch: no hero seam, or no navigation controller.
        /// It set neither flag before, so two taps could present twice.
        case modalFallback
    }

    enum State: Equatable {
        case idle
        case presenting(Route)
        case open(Route)
        case dismissing(Route)
        /// Landed on an intermediate screen (the place page) rather than home.
        /// The map is behind it and will be reached by a further pop.
        case intermediate
    }

    private(set) var state: State = .idle

    /// Whether a tap may open a post.
    ///
    /// ⚠️ FALSE FOR THE WHOLE ROUND TRIP, dismissal included. A second open
    /// during a return is the same defect as a second open during a present:
    /// the first flight is still holding the source marker, the feed and the
    /// stack it is animating on.
    var canOpen: Bool { state == .idle }

    /// Whether the map view must refuse touches.
    ///
    /// One answer, not four (`isScrollEnabled`, `isZoomEnabled`, …), because it
    /// has to cover both halves at once: MapKit's own pan/pinch/rotate AND the
    /// per-marker instant-tap recognizer, which is attached to the annotation
    /// VIEW. Hit-testing never descends into a view that is not interactive, so
    /// one write starves both. Scroll-only flags would leave the marker
    /// recognizers live — which is exactly the second-post case.
    ///
    /// Programmatic `selectAnnotation` is unaffected, so the DEBUG openers and
    /// any future deep link still work.
    var mapIsInert: Bool { state != .idle }

    /// Whether the flow is resting on an intermediate screen — the place page.
    ///
    /// A legitimate ending, not a hang: the viewer is on a real screen and the
    /// map is one pop away. A harness that cannot tell the two apart reports a
    /// working route as a stuck one, which is what the first soak of this path
    /// did.
    var isAtIntermediate: Bool { state == .intermediate }

    /// The route currently owning the screen, if any.
    var route: Route? {
        switch state {
        case .idle, .intermediate: nil
        case .presenting(let route), .open(let route), .dismissing(let route): route
        }
    }

    // MARK: - Events

    /// A tap has been accepted and a presentation is starting.
    ///
    /// Returns false when the gate refuses — the caller must not open. This is
    /// the re-entrancy guard, and it is the gate's rather than the caller's so
    /// that every route is refused by the same rule.
    mutating func openBegan(_ route: Route) -> Bool {
        guard canOpen else { return false }
        state = .presenting(route)
        return true
    }

    /// The destination is on screen and the presentation animation is over.
    mutating func destinationShown() {
        if case .presenting(let route) = state { state = .open(route) }
    }

    /// The presentation was reversed — the card was caught and thrown back, so
    /// the map is frontmost again with nothing pushed.
    ///
    /// ⚠️ THE ENDING THAT HAD NO HANDLER. Without it the gate never reopens and
    /// the map is dead to taps for the life of the screen.
    mutating func presentationCancelled() {
        if case .presenting = state { state = .idle }
    }

    /// A dismissal has begun — a grab, the chevron, a pop.
    mutating func dismissalBegan() {
        if case .open(let route) = state { state = .dismissing(route) }
    }

    /// A dismissal finished. `committed == false` is the cancelled grab: the
    /// feed stays, so the gate goes back to open rather than idle.
    mutating func dismissalEnded(committed: Bool) {
        guard case .dismissing(let route) = state else { return }
        state = committed ? .idle : .open(route)
    }

    /// The dismissal landed on the place page rather than on the map.
    mutating func dismissedToIntermediate() {
        state = .intermediate
    }

    /// ⚠️ AND IT IS THE REVEAL ROUTE'S ORDINARY RELEASE, not only a backstop.
    /// Traced over six cycles: a reveal reports `idle -> presenting(reveal)`
    /// and then `presenting(reveal) -> idle`, never passing through `.open`,
    /// because that route has no "the destination is up" hook on the map's
    /// side. The gate is therefore COARSER there — it cannot tell presenting
    /// from open, so a cancelled reveal dismissal is a no-op rather than a
    /// return to `.open`.
    ///
    /// That coarseness is safe, and the reason is worth stating: every one of
    /// those states answers `canOpen == false` and `mapIsInert == true`, so the
    /// map is shut for the whole round trip either way, and the release still
    /// happens exactly once, here, when the map is genuinely frontmost. What
    /// the coarseness costs is diagnostic detail, not correctness.
    ///
    /// The map is frontmost and every animation is over — `viewDidAppear`,
    /// never `viewWillAppear`, which UIKit runs at interactive-pop begin.
    ///
    /// The backstop for endings nobody wired: a place page popping home, a
    /// multi-pop, a cross-tab return. Anything still holding the gate here is
    /// abandoned by definition.
    mutating func appearedAtRoot() {
        state = .idle
    }
}
