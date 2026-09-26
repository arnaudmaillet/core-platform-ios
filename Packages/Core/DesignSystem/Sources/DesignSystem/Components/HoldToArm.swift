import CoreGraphics
import Foundation

/// The arithmetic of a press-and-hold that has to be COMPLETED before letting
/// go does anything: a gauge that fills while the finger stays down, arms when
/// full, and fires only on a release while armed.
///
/// ```
///   recognised      filling (fillDuration)         armed         lifted
///   ──●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●───────────────●──▶ fire
///     └─ lifted before full ──▶ retract   drifted past `abandonDistance` ──▶ abandon
/// ```
///
/// A value type with no clock and no UIKit of its own: whoever owns the
/// gesture feeds it timestamps and finger positions, and acts on the
/// `Transition`s it hands back. That is what lets the whole decision — when
/// it arms, what a lift means, when a drift gives up — be tested to the
/// millisecond without a display link, a recogniser or a window.
///
/// ⚠️ **IT STARTS AT RECOGNITION, NOT AT TOUCH-DOWN.** The delay that keeps a
/// TAP from ever showing the gauge belongs to the recogniser
/// (`UILongPressGestureRecognizer.minimumPressDuration`), because only the
/// recogniser can tell the rest of the view hierarchy that the touch is
/// taken. Counting that delay again here would make the gauge arrive late and
/// fill for less time than it claims.
///
/// ⚠️ **ABANDONING IS FINAL FOR THE PRESS.** A finger that drifted off and
/// came back does not re-arm: the drift was the escape hatch, and one that
/// could be undone by wobbling back would fire a camera the viewer was
/// visibly trying to walk away from.
public struct HoldToArm: Equatable, Sendable {
    public enum Metrics {
        /// How long the gauge takes to fill once the hold is recognised.
        ///
        /// ⚠️ **LONG ENOUGH TO BE A DECISION, SHORT ENOUGH TO BE A SHORTCUT.**
        /// Added to the recogniser's own delay the whole gesture is under a
        /// second — the budget a shortcut has to beat the two taps it
        /// replaces (the "+", then Camera). Shorter than ~0.5 s and the ring
        /// is full before the eye has found it; the hold stops reading as
        /// something that was chosen.
        public static let fillDuration: TimeInterval = 0.6
        /// How far the finger may wander from where the hold was recognised
        /// before the hold is given up, in points.
        ///
        /// ⚠️ **WIDER THAN A TAB BUBBLE, NARROWER THAN THE WAY TO THE NEXT
        /// TAB.** A thumb held still still rolls ten or twenty points; the
        /// bubble is ~60pt across. Sixty points of drift is a finger that is
        /// deliberately leaving, not one that is resting.
        public static let abandonDistance: CGFloat = 60
    }

    /// Where the hold stands.
    public enum Phase: Equatable, Sendable {
        /// No press, or the last one has been dealt with.
        case idle
        /// Recognised at `since`; the gauge is filling.
        case filling(since: TimeInterval)
        /// Full: letting go now fires.
        case armed
        /// The finger drifted off. Nothing will fire for this press, whatever
        /// it does next; the press still has to END before a new one starts.
        case abandoned
    }

    /// What a call changed, for the owner to show.
    public enum Transition: Equatable, Sendable {
        /// The hold was recognised: show the gauge.
        case revealed
        /// The gauge filled: say so (the "ready" pop, a haptic).
        case armed
        /// Let go while armed: do the thing.
        case fired
        /// Let go too early, or cancelled by the system: put the gauge away.
        case retracted
        /// Drifted off while still pressing: put the gauge away now.
        case abandoned
    }

    public private(set) var phase: Phase = .idle
    public let fillDuration: TimeInterval
    public let abandonDistance: CGFloat
    private var origin: CGPoint = .zero

    public init(
        fillDuration: TimeInterval = Metrics.fillDuration,
        abandonDistance: CGFloat = Metrics.abandonDistance
    ) {
        self.fillDuration = fillDuration
        self.abandonDistance = abandonDistance
    }

    /// Whether a press is being tracked — anything but `.idle`.
    public var isEngaged: Bool { phase != .idle }

    /// The gauge's fill at `now`, 0...1. Full once armed; empty when idle or
    /// abandoned (the owner animates the retreat itself).
    public func progress(at now: TimeInterval) -> CGFloat {
        switch phase {
        case .idle, .abandoned:
            return 0
        case .armed:
            return 1
        case .filling(let since):
            guard fillDuration > 0 else { return 1 }
            return CGFloat(min(max((now - since) / fillDuration, 0), 1))
        }
    }

    /// The recogniser recognised the hold at `now`, with the finger at
    /// `location`. Ignored while a press is already tracked.
    public mutating func begin(at now: TimeInterval, location: CGPoint) -> Transition? {
        guard phase == .idle else { return nil }
        phase = .filling(since: now)
        origin = location
        return .revealed
    }

    /// Advances the clock. Arms once the gauge is full.
    public mutating func tick(at now: TimeInterval) -> Transition? {
        guard case .filling = phase, progress(at: now) >= 1 else { return nil }
        phase = .armed
        return .armed
    }

    /// The finger moved to `location` at `now`. Abandons the hold past
    /// `abandonDistance`; otherwise just advances the clock.
    public mutating func move(to location: CGPoint, at now: TimeInterval) -> Transition? {
        switch phase {
        case .filling, .armed:
            let distance = hypot(location.x - origin.x, location.y - origin.y)
            if distance > abandonDistance {
                phase = .abandoned
                return .abandoned
            }
            return tick(at: now)
        case .idle, .abandoned:
            return nil
        }
    }

    /// The finger lifted at `now`. Fires if armed — the clock is advanced
    /// first, so a lift in the very frame the gauge fills still counts.
    public mutating func end(at now: TimeInterval) -> Transition? {
        _ = tick(at: now)
        let was = phase
        phase = .idle
        switch was {
        case .armed: return .fired
        case .filling: return .retracted
        case .idle, .abandoned: return nil
        }
    }

    /// The system took the touch (a call, a presentation, the bar hiding).
    /// Never fires, even when armed: a cancel is not a decision.
    public mutating func cancel() -> Transition? {
        let was = phase
        phase = .idle
        switch was {
        case .filling, .armed: return .retracted
        case .idle, .abandoned: return nil
        }
    }
}
