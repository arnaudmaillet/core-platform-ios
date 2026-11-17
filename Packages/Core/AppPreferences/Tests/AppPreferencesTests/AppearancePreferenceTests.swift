import Foundation
import Testing
import UIKit
@testable import AppPreferences

/// Settings → App and Device → Display (#468): the stored appearance, and
/// the windows it is applied to.
@MainActor
@Suite(.serialized)
struct AppearancePreferenceTests {
    private func isolated() -> UserDefaults {
        UserDefaults(suiteName: "appearance-\(UUID().uuidString)")!
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
