import DesignSystem
import Testing
import UIKit
@testable import Profile

/// A settings choice is a `tick` (#1884); the choice already made, nothing.
@MainActor
struct SettingsChoiceHapticTests {
    @Test func aNewAppearanceTicksAndTheSameOneDoesNot() throws {
        let picker = AppearancePickerView(selection: .light)
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        let columns = buttons(in: picker)
        try #require(columns.count == AppearancePreference.allCases.count)
        let light = try #require(AppearancePreference.allCases.firstIndex(of: .light))
        let other = (light + 1) % columns.count
        let same = HapticRecorder.recording { columns[light].sendActions(for: .primaryActionTriggered) }
        #expect(same.isEmpty, "the chosen one played \(same)")
        let chosen = HapticRecorder.recording { columns[other].sendActions(for: .primaryActionTriggered) }
        #expect(chosen == [.tick])
    }
}
