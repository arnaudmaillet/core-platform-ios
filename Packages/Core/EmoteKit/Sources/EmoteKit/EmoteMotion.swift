import DesignSystem
import MediaCore

/// How an emote may move right now: the device's answer (`AnimatedIconView`,
/// shared with the map's icons), held still when the viewer turned off
/// Animate Emojis or Power Saving is on (Settings → App and Device).
@MainActor
enum EmoteMotion {
    static var policy: AnimatedIconView.MotionPolicy {
        EmoteAnimationPreference.animatesEmotes ? AnimatedIconView.policy : .still
    }
}
