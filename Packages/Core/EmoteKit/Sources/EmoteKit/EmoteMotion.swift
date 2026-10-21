import DesignSystem
import Foundation
import MediaCore
import UIKit

/// How an emote may move right now (`policy`): still under Reduce Motion
/// (iOS or the app's), Animate Emojis off, Power Saving, Low Power Mode and
/// overheating; at its own rate otherwise.
///
/// ⚠️ **ONE CONTRACT FOR EVERY ANIMATED EMOTE** (#1504, the owner
/// 2026-10-21): a skeleton while its art is on its way, the animation once
/// it is there, a still frame of its OWN art when animations are off or
/// power is saved (iOS Low Power Mode included, as the keyboard already
/// did), a still skeleton if no art comes — never the system glyph, in a
/// label, the composer or a tile.
///
/// ⚠️ **EMOTES IN TEXT PLAY THROUGH IDLE CALM** (#1072, the owner's
/// decision of 2026-10-13). Idle calm (#580/#650) rests the app's decoration
/// — the shimmer, the badge's breath, the record's spin — once nobody has
/// touched the app for a while; an emote in a caption or a comment is what
/// the viewer is reading, and froze while they simply watched. The keyboard
/// already played through it (#926); every EmoteKit surface now does, each
/// stating this policy on its player (`playbackPolicy`).
///
/// ⚠️ **THE MAP TOO, SINCE #1504.** Its emote markers rested with the
/// decoration (the owner's #1072, for their number); the owner reversed that
/// on 2026-10-21: a marker's emote face plays under this policy as well
/// (`EmoteMapIcons.playbackPolicy`), Animate Emojis included.
@MainActor
enum EmoteMotion {
    /// What every emote surface plays under: a label, the composer, a tile
    /// that is not the keyboard's. `AnimatedIconView.forcedPolicy` (a debug
    /// override) still wins, held still when emotes may not animate at all.
    static var policy: AnimatedIconView.MotionPolicy {
        let now = conditions()
        if let forced = AnimatedIconView.forcedPolicy { return now.animatesEmotes ? forced : .still }
        return policy(for: now)
    }

    /// The policy for `conditions`. Idle calm is read into them only so a
    /// test can say it does NOT count.
    static func policy(for conditions: Conditions) -> AnimatedIconView.MotionPolicy {
        // Low Power is still, not `.reduced` (#1504): the same answer as the
        // keyboard's, so an emote never moves in one place and rests in the
        // next.
        if conditions.reducesMotion || conditions.lowPower || !conditions.animatesEmotes || conditions.overheated {
            return .still
        }
        return .full
    }

    /// Where every surface but the keyboard reads its conditions. Swappable
    /// for tests, which must not flip process-wide settings under suites
    /// running beside them.
    static var conditions: @MainActor () -> Conditions = { .current }

    /// The keyboard's name for the same conditions (#926).
    typealias KeyboardConditions = Conditions

    /// What the device says, for every emote's gate.
    struct Conditions: Equatable {
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

        static var current: Conditions {
            Conditions(
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
    /// they loop for as long as it shows — through idle calm, like every
    /// emote (#1072). Still under Reduce Motion and under Low Power Mode,
    /// which the owner named, and under what already stills every emote:
    /// Animate Emojis off, Power Saving, overheating.
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

    /// What the keyboard re-reads its policy on: the same as every emote
    /// surface (`policyNotifications`).
    static var keyboardPolicyNotifications: [Notification.Name] { policyNotifications }

    /// What every emote surface re-reads its policy on. Not
    /// `.decorativeMotionDidChange`: idle calm reaches none of them (#1072).
    static let policyNotifications: [Notification.Name] = [
        UIAccessibility.reduceMotionStatusDidChangeNotification,
        Notification.Name.NSProcessInfoPowerStateDidChange,
        Notification.Name.emoteAnimationPreferenceDidChange,
        ProcessInfo.thermalStateDidChangeNotification
    ]
}
