#if DEBUG
import Foundation
import Testing
import UIKit
@testable import DebugTools
@testable import DesignSystem

/// The haptics playground's screen (#2193): its sections, its menus, and a
/// tap on a sound. The candidates and the export it reads are DesignSystem's,
/// tested there (`HapticAuditionTests`).
@MainActor
@Suite(.serialized)
struct HapticPlaygroundTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "haptic-playground-\(UUID().uuidString)")!
    }

    /// Runs `body` with the app's switch on, whatever this simulator's
    /// preferences say.
    private func withHapticsOn(_ body: () throws -> Void) rethrows {
        let previous = HapticPreference.defaults
        defer { HapticPreference.defaults = previous }
        HapticPreference.defaults = freshDefaults()
        try body()
    }

    // MARK: - The screen

    @Test func everySectionHasItsRows() {
        let playground = HapticPlaygroundViewController(overrides: HapticOverrides(defaults: freshDefaults()))
        playground.loadViewIfNeeded()
        let rows = playground.rows
        #expect(Set(rows.keys) == Set(HapticPlaygroundViewController.Section.allCases))
        // The 12 roles, then "Reset all" and "Copy the catalog".
        #expect(rows[.roles]?.count == Haptic.allCases.count + 2)
        // 5 impact styles, the intensity slider, selection, 3 notifications.
        #expect(rows[.uikit]?.count == 10)
        // Intensity, sharpness, play.
        #expect(rows[.tap]?.count == 3)
        // Intensity, sharpness, duration, attack, decay, play.
        #expect(rows[.buzz]?.count == 6)
        #expect(rows[.patterns]?.count == HapticPattern.presets.count)
        #expect(rows[.vibration]?.count == 1)
        // Today's burst, the spacing slider, the spaced burst.
        #expect(rows[.pacing]?.count == 3)
        // The selection, a button, a toggle, a long press, the strip, the pull.
        #expect(rows[.context]?.count == 6)
    }

    /// Every role's "Try in the app" button keeps one width beside a title
    /// on one line or two: on the simulator it shrank unevenly, and to
    /// nothing beside `armed` and `boundary`.
    @Test(arguments: [CGFloat(375), 402, 440])
    func everyRolesMenuKeepsItsWidth(width: CGFloat) {
        let playground = HapticPlaygroundViewController(overrides: HapticOverrides(defaults: freshDefaults()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        defer { window.isHidden = true }
        window.addSubview(playground.view)
        playground.view.frame = window.bounds
        playground.view.layoutIfNeeded()
        #expect(playground.roleMenus.count == Haptic.allCases.count)
        for role in Haptic.allCases {
            let menu = playground.roleMenus[role]
            #expect(abs((menu?.bounds.width ?? 0) - HapticPlaygroundViewController.menuWidth) < 0.5,
                    "\(role)'s menu is \(menu?.bounds.width ?? 0) pt wide at \(width)")
        }
    }

    /// Without a Taptic Engine (the simulator), Core Haptics' rows are there
    /// but greyed out; with one, they play.
    @Test func coreHapticsIsGreyedOutWithoutATapticEngine() {
        let playground = HapticPlaygroundViewController(overrides: HapticOverrides(defaults: freshDefaults()))
        playground.loadViewIfNeeded()
        let coreHaptics = [HapticPlaygroundViewController.Section.tap, .buzz, .patterns].flatMap { playground.rows[$0] ?? [] }
        #expect(!coreHaptics.isEmpty)
        for row in coreHaptics {
            #expect(row.isUserInteractionEnabled == HapticPatternPlayer.supportsHaptics)
        }
        for row in playground.rows[.uikit] ?? [] {
            #expect(row.isUserInteractionEnabled)
        }
    }

    /// A tap on a sound plays it and makes it the selection.
    @Test func selectingASoundPlaysIt() {
        withHapticsOn {
            let playground = HapticPlaygroundViewController(overrides: HapticOverrides(defaults: freshDefaults()))
            playground.loadViewIfNeeded()
            let recorder = HapticRecorder()
            let rigid = HapticSound.recipe(.impact(.rigid, intensity: 0.4))
            Haptics.$recorder.withValue(recorder) {
                playground.select(rigid, from: .uikit)
            }
            #expect(recorder.auditioned == [rigid])
            #expect(playground.selection == rigid)
        }
    }
}
#endif
