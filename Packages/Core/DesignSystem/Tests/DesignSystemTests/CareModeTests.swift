import Testing
import UIKit
@testable import DesignSystem

/// Settings → App and Device → Display → Care Mode (#482).
@MainActor
@Suite(.serialized)
struct CareModeTests {
    @Test func itRaisesTheTextSizeButNeverLowersIt() {
        #expect(CareModePreference.contentSize(system: .medium, isOn: true) == .extraLarge)
        #expect(CareModePreference.contentSize(system: .large, isOn: true) == .extraLarge)
        #expect(CareModePreference.contentSize(system: .accessibilityLarge, isOn: true) == .accessibilityLarge)
        #expect(CareModePreference.contentSize(system: .small, isOn: false) == .small)
    }

    @Test func offByDefaultAndStored() {
        let previous = CareModePreference.defaults
        defer { CareModePreference.defaults = previous }
        CareModePreference.defaults = UserDefaults(suiteName: "care-\(UUID().uuidString)")!
        #expect(!CareModePreference.isOn)
        CareModePreference.isOn = true
        #expect(CareModePreference.isOn)
    }

    /// On, a window carries the larger size and bold text; off, the overrides
    /// are gone and the window follows the iPhone again.
    @Test func windowsGetAndLoseTheOverrides() {
        let previous = CareModePreference.defaults
        defer { CareModePreference.defaults = previous }
        CareModePreference.defaults = UserDefaults(suiteName: "care-\(UUID().uuidString)")!
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        CareModePreference.isOn = true
        CareModePreference.apply(to: [window])
        #expect(window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        #expect(window.traitOverrides.preferredContentSizeCategory >= .extraLarge)
        #expect(window.traitOverrides.legibilityWeight == .bold)

        CareModePreference.isOn = false
        CareModePreference.apply(to: [window])
        #expect(!window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        #expect(!window.traitOverrides.contains(UITraitLegibilityWeight.self))
    }
}
