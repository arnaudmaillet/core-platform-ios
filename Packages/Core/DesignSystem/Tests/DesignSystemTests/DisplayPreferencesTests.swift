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
