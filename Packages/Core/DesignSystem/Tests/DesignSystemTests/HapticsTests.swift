import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// Settings → App and Device → Playback and Sound → Haptics (#470).
@MainActor
@Suite(.serialized)
struct HapticsTests {
    @Test func onByDefaultAndStored() {
        let previous = HapticPreference.defaults
        defer { HapticPreference.defaults = previous }
        HapticPreference.defaults = UserDefaults(suiteName: "haptics-\(UUID().uuidString)")!
        #expect(HapticPreference.isOn)
        HapticPreference.isOn = false
        #expect(!HapticPreference.isOn)
    }

    /// Off, every role is silent: nothing prepared, nothing played.
    @Test func offIsSilentForEveryRole() {
        let previous = HapticPreference.defaults
        defer { HapticPreference.defaults = previous }
        HapticPreference.defaults = UserDefaults(suiteName: "haptics-\(UUID().uuidString)")!
        HapticPreference.isOn = false
        let recorder = HapticRecorder()
        Haptics.$recorder.withValue(recorder) {
            for role in Haptic.allCases {
                Haptics.prepare(role)
                Haptics.play(role)
            }
        }
        #expect(recorder.played.isEmpty)
        #expect(recorder.prepared.isEmpty)
    }
}
