import DesignSystem
import Foundation
import MediaCore
import UIKit

/// How an emote may move right now: the device's answer (`AnimatedIconView`,
/// shared with the map's icons), held still when the viewer turned off
/// Animate Emojis or Power Saving is on (Settings → App and Device).
@MainActor
enum EmoteMotion {
    static var policy: AnimatedIconView.MotionPolicy {
        EmoteAnimationPreference.animatesEmotes ? AnimatedIconView.policy : .still
    }

    /// What the device says, for the emote keyboard's gate.
    struct KeyboardConditions: Equatable {
        /// iOS Reduce Motion, or the app's own switch, or Power Saving
        /// (`MotionPreference.reducesMotion`).
        var reducesMotion = false
        /// iOS Low Power Mode.
        var lowPower = false
        /// The viewer's Animate Emojis switch, off under Power Saving too
        /// (`EmoteAnimationPreference.animatesEmotes`).
        var animatesEmotes = true
        /// Serious or critical thermal pressure.
        var overheated = false
        /// Nobody has touched the app for a while (`IdleCalm`). Read so that
        /// a test can say it does NOT count.
        var idleCalm = false

        static var current: KeyboardConditions {
            KeyboardConditions(
                reducesMotion: MotionPreference.reducesMotion,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                animatesEmotes: EmoteAnimationPreference.animatesEmotes,
                overheated: ProcessInfo.processInfo.thermalState.rawValue
                    >= ProcessInfo.ThermalState.serious.rawValue,
                idleCalm: IdleCalm.isCalm
            )
        }
    }

    /// The emote keyboard's policy (#926): its emotes ARE what it offers, so
    /// they loop for as long as it shows — through idle calm (#650), which
    /// rests the app's decoration and not this. Still under Reduce Motion and
    /// under Low Power Mode, which the owner named, and under what already
    /// stills every emote: Animate Emojis off, Power Saving, overheating.
    ///
    /// ⚠️ LOW POWER IS STILL HERE, NOT `.reduced`. Decoration only halves its
    /// rate under Low Power (`AnimatedIconView.devicePolicy`); a screen of
    /// sixty looping tiles is the keyboard's whole cost, so it stops.
    static func keyboardPolicy(for conditions: KeyboardConditions) -> AnimatedIconView.MotionPolicy {
        if conditions.reducesMotion || conditions.lowPower || !conditions.animatesEmotes || conditions.overheated {
            return .still
        }
        return .full
    }

    /// Where the keyboard reads its conditions. Swappable for tests, which
    /// must not flip process-wide settings under suites running beside them.
    static var keyboardConditions: @MainActor () -> KeyboardConditions = { .current }

    static var keyboardPolicy: AnimatedIconView.MotionPolicy {
        keyboardPolicy(for: keyboardConditions())
    }

    /// What the keyboard re-reads its policy on. Not
    /// `.decorativeMotionDidChange`: idle calm does not reach it.
    static let keyboardPolicyNotifications: [Notification.Name] = [
        UIAccessibility.reduceMotionStatusDidChangeNotification,
        Notification.Name.NSProcessInfoPowerStateDidChange,
        Notification.Name.emoteAnimationPreferenceDidChange,
        ProcessInfo.thermalStateDidChangeNotification
    ]
}
