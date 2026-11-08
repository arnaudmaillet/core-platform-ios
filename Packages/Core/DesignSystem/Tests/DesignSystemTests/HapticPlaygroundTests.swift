import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The haptics playground (#2193): its sections, the candidates a role is
/// given to try in the app, and the exported catalog.
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

    // MARK: - Candidates

    /// A candidate given to a role is what `Haptics.play` plays; "Reset all"
    /// puts the role's recipe back.
    @Test func aCandidateIsWhatTheRolePlaysUntilReset() {
        withHapticsOn {
            let overrides = HapticOverrides(defaults: freshDefaults())
            let jelly = HapticSound.pattern(HapticPattern.presets[3])
            overrides[.armed] = jelly
            #expect(overrides.isAnyOn)
            #expect(overrides.roles == [.armed])

            var clock: TimeInterval = 0
            let recorder = HapticRecorder()
            recorder.overrides = overrides
            recorder.clock = { clock }
            Haptics.$recorder.withValue(recorder) {
                Haptics.play(.armed)
                Haptics.play(.held)
                clock += 1
                overrides.resetAll()
                Haptics.play(.armed)
            }
            #expect(recorder.played == [.armed, .held, .armed])
            #expect(recorder.sounds == [jelly, .recipe(Haptic.held.recipe), .recipe(Haptic.armed.recipe)])
            #expect(!overrides.isAnyOn)
        }
    }

    /// A candidate keeps the role's pacing: a `step` candidate played twice
    /// within the step spacing plays once.
    @Test func aCandidateKeepsTheRolesPacing() {
        withHapticsOn {
            let overrides = HapticOverrides(defaults: freshDefaults())
            overrides[.step] = .systemVibration
            let recorder = HapticRecorder()
            recorder.overrides = overrides
            recorder.clock = { 10 }
            Haptics.$recorder.withValue(recorder) {
                Haptics.play(.step)
                Haptics.play(.step)
            }
            #expect(recorder.sounds == [.systemVibration])
        }
    }

    /// The candidates survive a relaunch: a new instance on the same
    /// defaults reads them back, every kind of sound.
    @Test func candidatesSurviveANewInstance() {
        let defaults = freshDefaults()
        let sounds: [Haptic: HapticSound] = [
            .tick: .recipe(.selection),
            .step: .recipe(.impact(.soft, intensity: 0.35)),
            .success: .recipe(.notification(.warning)),
            .armed: .pattern(HapticPattern.presets[2]),
            .commit: .systemVibration,
        ]
        let first = HapticOverrides(defaults: defaults)
        for (role, sound) in sounds { first[role] = sound }

        let second = HapticOverrides(defaults: defaults)
        for role in Haptic.allCases {
            #expect(second[role] == sounds[role], "\(role)")
        }
        second.resetAll()
        #expect(!HapticOverrides(defaults: defaults).isAnyOn)
        #expect(defaults.object(forKey: HapticOverrides.key) == nil)
    }

    // MARK: - The export

    /// The exported text lists the 12 roles with their values, and says
    /// which are candidates.
    @Test func theExportListsEveryRoleWithItsValues() {
        let overrides = HapticOverrides(defaults: freshDefaults())
        overrides[.boundary] = .recipe(.impact(.heavy, intensity: 0.25))
        let text = HapticCatalogExport.text(overrides: overrides)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "Haptic catalog (12 roles)")
        #expect(lines.count == 1 + Haptic.allCases.count)
        for role in Haptic.allCases {
            #expect(lines.contains { $0.hasPrefix("- \(role): ") }, "\(role)")
        }
        #expect(lines.contains("- step: impact .light (today)"))
        #expect(lines.contains("- tick: selection (today)"))
        #expect(lines.contains("- boundary: CANDIDATE impact .heavy at 0.25 (today: impact .rigid at 0.50)"))
    }

    /// A pattern exports every event with its values.
    @Test func aPatternExportsItsEvents() {
        let summary = HapticSound.pattern(HapticPattern.presets[0]).summary
        #expect(summary == "Core Haptics \"Double tap\": tap at 0.00 s, intensity 1.00, sharpness 0.60; "
            + "tap at 0.12 s, intensity 1.00, sharpness 0.60")
    }

    /// Every ready pattern builds a valid Core Haptics pattern.
    @Test func everyPresetBuilds() throws {
        for pattern in HapticPattern.presets {
            _ = try pattern.makeCHPattern()
        }
        let buzz = HapticPattern(name: "Buzz", events: [.buzz(duration: 0.3, intensity: 0.8, sharpness: 0.3, attack: 0.2, decay: 0.4)])
        _ = try buzz.makeCHPattern()
    }
}
