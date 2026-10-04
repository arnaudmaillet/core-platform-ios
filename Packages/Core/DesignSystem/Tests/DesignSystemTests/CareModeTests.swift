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
        // A larger iPhone setting wins, up to the app's XXXL ceiling.
        #expect(CareModePreference.contentSize(system: .extraExtraLarge, isOn: true) == .extraExtraLarge)
        #expect(CareModePreference.contentSize(system: .accessibilityLarge, isOn: true) == .extraExtraExtraLarge)
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
        // Through the non-recording path: the app-wide size other suites'
        // fonts are made at must stay untouched.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        CareModePreference.applyWeight(to: [window], isOn: true)
        TextSizeCeiling.apply(to: [window], system: .large, careMode: true, recordsCurrent: false)
        #expect(window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        #expect(window.traitOverrides.preferredContentSizeCategory == .extraLarge)
        #expect(window.traitOverrides.legibilityWeight == .bold)

        CareModePreference.applyWeight(to: [window], isOn: false)
        TextSizeCeiling.apply(to: [window], system: .large, careMode: false, recordsCurrent: false)
        #expect(!window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        #expect(!window.traitOverrides.contains(UITraitLegibilityWeight.self))

        // Above the ceiling the override caps it, Care Mode or not.
        TextSizeCeiling.apply(to: [window], system: .accessibilityLarge, careMode: false, recordsCurrent: false)
        #expect(window.traitOverrides.preferredContentSizeCategory == .extraExtraExtraLarge)
    }
}
