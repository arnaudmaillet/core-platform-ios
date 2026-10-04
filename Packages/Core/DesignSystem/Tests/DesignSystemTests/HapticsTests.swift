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

    /// Off, every wrapper call is a no-op (no crash, nothing fires).
    @Test func offIsSilentForEveryKind() {
        let previous = HapticPreference.defaults
        defer { HapticPreference.defaults = previous }
        HapticPreference.defaults = UserDefaults(suiteName: "haptics-\(UUID().uuidString)")!
        HapticPreference.isOn = false
        HapticImpact(style: .light).prepare()
        HapticImpact(style: .rigid).impactOccurred()
        HapticImpact().impactOccurred(intensity: 0.5)
        HapticSelection().selectionChanged()
        HapticNotification().notificationOccurred(.success)
    }

    /// ⚠️ The switch only works if NOTHING bypasses it. Scans the app's and
    /// the packages' sources for a direct UIKit feedback generator anywhere
    /// but `Haptics.swift`.
    @Test func noFeedbackGeneratorBypassesTheWrappers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        let pattern = try Regex(#"\bUI(Impact|Selection|Notification)FeedbackGenerator\s*\("#)
        var offenders: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      url.lastPathComponent != "Haptics.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains(pattern) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "direct feedback generators in: \(offenders)")
    }
}
