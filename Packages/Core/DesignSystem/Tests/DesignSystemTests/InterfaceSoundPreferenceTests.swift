import Foundation
import Testing
@testable import DesignSystem

/// Settings → App and Device → Playback and Sound → Interface Sounds (#471).
@MainActor
@Suite(.serialized)
struct InterfaceSoundPreferenceTests {
    @Test func onByDefaultAndStored() {
        let previous = InterfaceSoundPreference.defaults
        defer { InterfaceSoundPreference.defaults = previous }
        InterfaceSoundPreference.defaults = UserDefaults(suiteName: "sounds-\(UUID().uuidString)")!
        #expect(InterfaceSoundPreference.isOn)
        InterfaceSoundPreference.isOn = false
        #expect(!InterfaceSoundPreference.isOn)
    }

    /// Off, a play is a no-op that never reaches the player pool — so it
    /// can't build, warm or start anything.
    @Test func offPlaysNothing() {
        let previous = InterfaceSoundPreference.defaults
        defer { InterfaceSoundPreference.defaults = previous }
        InterfaceSoundPreference.defaults = UserDefaults(suiteName: "sounds-\(UUID().uuidString)")!
        InterfaceSoundPreference.isOn = false
        let before = UISound.players.debugDepth(of: .tap)
        UISound.tap.play()
        UISound.prepare()
        #expect(UISound.players.debugDepth(of: .tap) == before)
    }
}
