import DesignSystem
import UIKit

/// Whether a post opens with a hero (or a reveal window) at all.
///
/// ⚠️ REDUCE MOTION GETS THE PLATFORM'S OWN PUSH (product decision,
/// 2026-10-03). A hero is a zoom with a depth cue, and a reveal is a window
/// growing out of a row: exactly the motion the setting asks to remove. The
/// replacement is the navigation stack's NATIVE push and pop rather than a
/// custom fade, for two reasons:
/// - it is the path text posts already take (`pushWithoutFlight`, For You's and
///   the map's plain push), so it is tested code rather than a new animator
///   with its own playback hand-offs to get right;
/// - UIKit honours "Prefer Cross-Fade Transitions" for its own pushes, so that
///   setting is respected without any code here.
///
/// The decision is the PRESENTER's, taken before anything is built. Returning
/// no animator from the transition controller would not do: it is built with
/// a `zoomTransitionWillBegin` that tells the page a flight is coming, and the
/// page would defer its playback for a landing that never happens.
@MainActor
public enum HeroMotionPolicy {
    /// The system setting, read when asked. Replaceable in tests.
    public static var reducesMotion: () -> Bool = {
        #if DEBUG
        // `-hero-reduce-motion`: the same route without toggling the setting.
        if ProcessInfo.processInfo.arguments.contains("-hero-reduce-motion") { return true }
        #endif
        return MotionPreference.reducesMotion
    }

    /// True when posts should open with the stack's ordinary push.
    public static var prefersNativePush: Bool { reducesMotion() }
}
