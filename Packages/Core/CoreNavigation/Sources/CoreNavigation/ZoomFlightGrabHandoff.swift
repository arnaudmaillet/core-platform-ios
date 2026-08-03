import CoreGraphics

/// The pure state of catching an in-flight hero transition and handing it to
/// the finger — extracted from the UIKit driver (`ZoomFlightInterruptor`) so
/// the interruption's state transitions and channel math are unit-testable
/// without a live transition.
///
/// Two channels, mirroring the grab-from-rest contract
/// (`ZoomDismissInteractionController`):
///
/// - **Progress** (1D): vertical travel over the container's height scrubs the
///   flight's own animation through the percent driver. `direction` maps
///   "down" per leg — down advances a dismissal home, down reverses a
///   present — so the gesture means "put it back" either way.
/// - **Free position** (2D): whatever of the finger's travel the scrub did NOT
///   spend moving the card along its rail becomes a rubber-banded transform
///   offset, so the card tracks the finger 1:1 near the grab point instead of
///   crawling along the baked path. `freeOffset` owns that arithmetic.
///
/// The phases are a one-way street: a flight is frozen at most once, caught at
/// most once, decided at most once, and a spent handoff refuses every further
/// event. The UIKit driver translates commands into `pause()` / `update(_:)` /
/// `finish()` / `cancel()` calls; nothing here touches a view.
struct ZoomFlightGrabHandoff {
    enum Phase: Equatable {
        /// The flight is animating on its own; nothing has touched it.
        case inFlight
        /// A finger is down and the animation is paused where it was — the
        /// freeze-on-contact. No drag yet.
        case frozen
        /// A pan owns the flight: progress scrubs, position floats.
        case grabbing
        /// Released or resumed; this handoff is spent.
        case decided
    }

    /// What the UIKit driver must do in response to an event.
    enum Command: Equatable {
        case pauseFlight
        case resumeTowardEnd
    }

    struct Release: Equatable {
        /// Whether the transition runs to its END (destination shown) — or
        /// back to its start.
        let completes: Bool
        /// The continuation spring's initial velocity, in UIKit's unit —
        /// remaining-distances per second toward the outcome's target.
        let springVelocity: CGFloat
    }

    private(set) var phase: Phase = .inFlight
    /// `+1` when a downward drag advances the transition (dismiss leg), `-1`
    /// when it reverses one (present leg).
    let direction: CGFloat
    /// The travel that maps to the whole flight — the container's height, so
    /// the gain does not change with the post's shape.
    let span: CGFloat
    /// `percentComplete` at the moment the flight was caught — the drag is
    /// measured from there, not from zero, or grabbing a half-flown card
    /// would snap it back to the start.
    private(set) var grabbedAt: CGFloat = 0

    /// Rubber-band caps on the free channel: tight off the progress axis,
    /// generous along it — the same shape as the grab-from-rest limits.
    var horizontalDriftLimit: CGFloat = 140
    var verticalDriftLimit: CGFloat = 320

    init(advancesOnDownwardDrag: Bool, span: CGFloat) {
        direction = advancesOnDownwardDrag ? 1 : -1
        self.span = max(span, 1)
    }

    // MARK: - Events

    /// A finger landed on a flying card. Pause only an untouched flight: a
    /// repeat (or a second finger) must not re-freeze machinery another phase
    /// already owns.
    mutating func touchDown() -> Command? {
        guard phase == .inFlight else { return nil }
        phase = .frozen
        return .pauseFlight
    }

    /// The finger lifted without ever dragging — a tap-hold. The flight
    /// resumes toward its end: holding was an inspection, not a veto.
    mutating func touchUp() -> Command? {
        guard phase == .frozen else { return nil }
        phase = .decided
        return .resumeTowardEnd
    }

    /// A pan claimed the flight, with the percent driver paused at `fraction`.
    /// Allowed from an untouched flight (the pan pauses on its own) or a
    /// frozen one (touch-down paused first); refused once anything has been
    /// decided.
    mutating func grabBegan(atFraction fraction: CGFloat) -> Bool {
        guard phase == .inFlight || phase == .frozen else { return false }
        phase = .grabbing
        grabbedAt = min(max(fraction, 0), 1)
        return true
    }

    /// The scrub channel: transition progress for a vertical translation,
    /// measured from where the flight was caught.
    func fraction(forVerticalTranslation translation: CGFloat) -> CGFloat {
        min(max(grabbedAt + direction * translation / span, 0), 1)
    }

    /// The free channel: the part of the finger's travel the scrub has not
    /// already spent moving the card along its rail, rubber-banded per axis.
    ///
    /// `railDelta` is how far the scrub itself has displaced the card since
    /// the grab began — presentation-layer truth, so it holds whatever the
    /// timing curve does. Near the grab point the residual passes ~1:1: rail
    /// plus offset equals the finger's translation, which is what "follows
    /// the finger" means. It firms up asymptotically at the caps, so the card
    /// keeps answering the hand without ever promising it has left.
    func freeOffset(translation: CGPoint, railDelta: CGPoint) -> CGPoint {
        CGPoint(
            x: ZoomTransitionGeometry.rubberBand(
                translation.x - railDelta.x, limit: horizontalDriftLimit
            ),
            y: ZoomTransitionGeometry.rubberBand(
                translation.y - railDelta.y, limit: verticalDriftLimit
            )
        )
    }

    /// The finger lifted mid-grab. Decides the outcome on the caught-flight
    /// release contract and converts the hand's velocity into the
    /// continuation spring's unit. Nil when no grab was in flight (a release
    /// the pan delivered after the decision was already made).
    mutating func released(
        verticalTranslation translation: CGFloat, verticalVelocity velocity: CGFloat
    ) -> Release? {
        guard phase == .grabbing else { return nil }
        phase = .decided
        let progress = fraction(forVerticalTranslation: translation)
        let completes = ZoomTransitionGeometry.caughtReleaseCompletes(
            progress: progress, velocityTowardEnd: direction * velocity
        )
        return Release(
            completes: completes,
            springVelocity: Self.continuationVelocity(
                rawVerticalVelocity: velocity, atProgress: progress,
                towardEnd: completes, direction: direction, span: span
            )
        )
    }

    /// The transition fraction the SCREEN is actually showing, recovered from
    /// the card's presentation-layer size against the flight's two endpoint
    /// poses.
    ///
    /// Needed because `UIPercentDrivenInteractiveTransition.pause()` syncs
    /// `percentComplete` from the animator's `fractionComplete`, and for a
    /// SPRING animator that number is time-based and wrong — measured as 0.00
    /// on a flight that was visibly half-flown. Scrubbing from the synced
    /// value snapped the card straight to the start pose (tile-sized, on a
    /// present) the instant a finger landed on it.
    ///
    /// Size is a faithful proxy for the whole pose: every property the flight
    /// animates follows an affine path between the two poses under one shared
    /// timing curve, so the visual state at any instant is a single scalar —
    /// and scrubbing the paused animator (linearly) to that scalar reproduces
    /// the exact geometry on screen. Solved on the axis with the longer
    /// travel; nil when the endpoints are effectively the same size, where
    /// no fraction is recoverable and the synced value is all there is.
    static func caughtFraction(presented: CGSize, start: CGSize, end: CGSize) -> CGFloat? {
        let widthTravel = end.width - start.width
        let heightTravel = end.height - start.height
        let fraction: CGFloat
        if abs(heightTravel) >= abs(widthTravel) {
            guard abs(heightTravel) > 1 else { return nil }
            fraction = (presented.height - start.height) / heightTravel
        } else {
            fraction = (presented.width - start.width) / widthTravel
        }
        return min(max(fraction, 0), 1)
    }

    /// The hand's points/second, projected onto transition progress and
    /// normalized to the remaining travel toward the outcome's target —
    /// UIKit's spring-velocity unit. Clamped so a wild flick cannot detonate
    /// the spring; the sign flips for a reversal, whose target is the START.
    static func continuationVelocity(
        rawVerticalVelocity raw: CGFloat, atProgress progress: CGFloat,
        towardEnd: Bool, direction: CGFloat, span: CGFloat
    ) -> CGFloat {
        let travel = towardEnd ? max(1 - progress, 0.001) : max(progress, 0.001)
        let towardTarget = (towardEnd ? 1 : -1) * direction * raw / (travel * max(span, 1))
        return min(max(towardTarget, -3), 3)
    }
}
