import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// Settings → App and Device → Display (#468): the app-level Reduce Motion
/// every animation reads, and the stored appearance.
@MainActor
@Suite(.serialized)
struct DisplayPreferencesTests {
    private func isolated() -> UserDefaults {
        UserDefaults(suiteName: "display-\(UUID().uuidString)")!
    }

    @Test func theAppSwitchReducesMotionOnTopOfIOS() {
        let previous = MotionPreference.defaults
        defer { MotionPreference.defaults = previous }
        MotionPreference.defaults = isolated()
        #expect(!MotionPreference.appReducesMotion)
        #expect(MotionPreference.reducesMotion == UIAccessibility.isReduceMotionEnabled)
        MotionPreference.appReducesMotion = true
        #expect(MotionPreference.reducesMotion)
    }

    /// Code already listening for the iOS change hears the app switch too.
    @Test func togglingTheAppSwitchPostsTheIOSNotificationOncePerChange() {
        let previous = MotionPreference.defaults
        defer { MotionPreference.defaults = previous }
        MotionPreference.defaults = isolated()
        var notices = 0
        let observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: nil
        ) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        MotionPreference.appReducesMotion = true
        MotionPreference.appReducesMotion = true
        MotionPreference.appReducesMotion = false
        #expect(notices == 2)
    }

    /// The four combinations of the switch and iOS (#1808): the effect only
    /// with both — and the viewer's own choices are overridden, never
    /// rewritten.
    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func lowPowerModeSavesBatteryOnlyWhenFollowed(followed: Bool, systemOn: Bool) {
        let previous = (MotionPreference.defaults, LowPowerMode.defaults, EmoteAnimationPreference.defaults, LowPowerMode.system)
        defer {
            MotionPreference.defaults = previous.0
            LowPowerMode.defaults = previous.1
            EmoteAnimationPreference.defaults = previous.2
            LowPowerMode.system = previous.3
            LowPowerMode.resetAnnounced()
        }
        MotionPreference.defaults = isolated()
        LowPowerMode.defaults = isolated()
        EmoteAnimationPreference.defaults = isolated()
        LowPowerMode.system = { systemOn }

        #expect(LowPowerMode.isFollowed, "the switch is not on by default")
        LowPowerMode.isFollowed = followed
        let saves = followed && systemOn
        #expect(LowPowerMode.savesBattery == saves)
        #expect(EmoteAnimationPreference.animatesEmotes == !saves)
        if saves { #expect(MotionPreference.reducesMotion) }
        // The viewer's own switches are untouched.
        #expect(!MotionPreference.appReducesMotion)
        #expect(EmoteAnimationPreference.isOn)
    }

    @Test func animatedEmojisCanBeTurnedOffOnTheirOwn() {
        let previous = (LowPowerMode.system, EmoteAnimationPreference.defaults)
        defer {
            LowPowerMode.system = previous.0
            EmoteAnimationPreference.defaults = previous.1
        }
        LowPowerMode.system = { false }
        EmoteAnimationPreference.defaults = isolated()
        var notices = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .emoteAnimationPreferenceDidChange, object: nil, queue: nil
        ) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        EmoteAnimationPreference.isOn = false
        EmoteAnimationPreference.isOn = false
        #expect(!EmoteAnimationPreference.animatesEmotes)
        #expect(notices == 1)
    }

    /// Everything that honours Reduce Motion, every emote and every
    /// effect's reader hears the effect change — once per real change, on
    /// main, and never while the switch is off (#1808).
    @Test func theEffectsChangePostsTheThreeNotificationsOnlyWhenItChanges() {
        let previous = (LowPowerMode.defaults, LowPowerMode.system)
        defer {
            LowPowerMode.defaults = previous.0
            LowPowerMode.system = previous.1
            LowPowerMode.resetAnnounced()
        }
        LowPowerMode.defaults = isolated()
        var systemOn = false
        LowPowerMode.system = { systemOn }
        LowPowerMode.resetAnnounced()
        LowPowerMode.reportIfChanged()
        var motion = 0, emotes = 0, effect = 0
        var onMain = true
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: nil) { _ in motion += 1 },
            center.addObserver(forName: .emoteAnimationPreferenceDidChange, object: nil, queue: nil) { _ in emotes += 1 },
            center.addObserver(forName: .lowPowerModeEffectDidChange, object: nil, queue: nil) { _ in
                effect += 1
                onMain = onMain && Thread.isMainThread
            },
        ]
        defer { observers.forEach(center.removeObserver) }

        systemOn = true
        LowPowerMode.reportIfChanged()
        LowPowerMode.reportIfChanged()
        #expect((motion, emotes, effect) == (1, 1, 1), "iOS entering Low Power Mode, followed, is one change")
        LowPowerMode.isFollowed = false
        #expect(effect == 2, "turning the switch off lifts the effect")
        systemOn = false
        LowPowerMode.reportIfChanged()
        systemOn = true
        LowPowerMode.reportIfChanged()
        #expect(effect == 2, "with the switch off, Low Power Mode posted")
        LowPowerMode.isFollowed = true
        #expect(effect == 3, "turning the switch on in Low Power Mode applies it")
        #expect(onMain)
    }

    /// Power Saving's stored switch is forgotten, and a stored `true` has no
    /// effect (#1808).
    @Test func powerSavingsStoredSwitchIsForgotten() {
        let previous = (LowPowerMode.defaults, LowPowerMode.system)
        defer {
            LowPowerMode.defaults = previous.0
            LowPowerMode.system = previous.1
        }
        let defaults = isolated()
        defaults.set(true, forKey: LowPowerMode.powerSavingKey)
        LowPowerMode.defaults = defaults
        LowPowerMode.system = { false }
        #expect(!LowPowerMode.savesBattery, "a stored Power Saving still applied")
        LowPowerMode.forgetPowerSaving()
        #expect(defaults.object(forKey: LowPowerMode.powerSavingKey) == nil)
    }

    @Test func appearanceDefaultsToSystemAndMapsToInterfaceStyles() {
        let previous = AppearancePreference.defaults
        defer { AppearancePreference.defaults = previous }
        AppearancePreference.defaults = isolated()
        #expect(AppearancePreference.current == .system)
        AppearancePreference.current = .dark
        #expect(AppearancePreference.current == .dark)
        #expect(AppearancePreference.system.interfaceStyle == .unspecified)
        #expect(AppearancePreference.light.interfaceStyle == .light)
        #expect(AppearancePreference.dark.interfaceStyle == .dark)
    }

    @Test func applyingSetsEveryWindowsOverride() {
        let previous = AppearancePreference.defaults
        defer { AppearancePreference.defaults = previous }
        AppearancePreference.defaults = isolated()
        AppearancePreference.current = .light
        let windows = [UIWindow(), UIWindow()]
        AppearancePreference.apply(to: windows)
        #expect(windows.allSatisfy { $0.overrideUserInterfaceStyle == .light })
    }
}
