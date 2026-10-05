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

    /// Power Saving overrides the viewer's own choices while it is on, and
    /// gives them back untouched when it is off.
    @Test func powerSavingOverridesWithoutRewriting() {
        let previous = (MotionPreference.defaults, PowerSavingPreference.defaults, EmoteAnimationPreference.defaults)
        defer {
            MotionPreference.defaults = previous.0
            PowerSavingPreference.defaults = previous.1
            EmoteAnimationPreference.defaults = previous.2
        }
        MotionPreference.defaults = isolated()
        PowerSavingPreference.defaults = isolated()
        EmoteAnimationPreference.defaults = isolated()

        #expect(!PowerSavingPreference.isOn)
        #expect(EmoteAnimationPreference.isOn)
        #expect(EmoteAnimationPreference.animatesEmotes)

        PowerSavingPreference.isOn = true
        #expect(MotionPreference.reducesMotion)
        #expect(!EmoteAnimationPreference.animatesEmotes)
        // The viewer's own switches are untouched.
        #expect(!MotionPreference.appReducesMotion)
        #expect(EmoteAnimationPreference.isOn)

        PowerSavingPreference.isOn = false
        #expect(MotionPreference.reducesMotion == UIAccessibility.isReduceMotionEnabled)
        #expect(EmoteAnimationPreference.animatesEmotes)
    }

    @Test func animatedEmojisCanBeTurnedOffOnTheirOwn() {
        let previous = (PowerSavingPreference.defaults, EmoteAnimationPreference.defaults)
        defer {
            PowerSavingPreference.defaults = previous.0
            EmoteAnimationPreference.defaults = previous.1
        }
        PowerSavingPreference.defaults = isolated()
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

    /// Everything that honours Reduce Motion, and every emote, hears Power
    /// Saving change.
    @Test func togglingPowerSavingPostsTheMotionAndEmoteNotifications() {
        let previous = PowerSavingPreference.defaults
        defer { PowerSavingPreference.defaults = previous }
        PowerSavingPreference.defaults = isolated()
        var motion = 0
        var emotes = 0
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: nil) { _ in motion += 1 },
            center.addObserver(forName: .emoteAnimationPreferenceDidChange, object: nil, queue: nil) { _ in emotes += 1 },
        ]
        defer { observers.forEach(center.removeObserver) }
        PowerSavingPreference.isOn = true
        PowerSavingPreference.isOn = true
        PowerSavingPreference.isOn = false
        #expect(motion == 2)
        #expect(emotes == 2)
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
