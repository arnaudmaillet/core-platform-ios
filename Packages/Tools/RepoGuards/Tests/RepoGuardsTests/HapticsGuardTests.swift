import Foundation
import Testing

/// Haptics (#470, #1884): the role switch holds only if nothing names a
/// generator or a style. Moved from DesignSystem's `HapticsTests` (#2371).
struct HapticsGuardTests {
    /// ⚠️ A ROLE, NEVER A STYLE (#1884). The switch only works if NOTHING
    /// bypasses it, and a feel is tuned in one table only. Scans the app's
    /// and the packages' sources for a UIKit feedback generator, or one of
    /// the wrappers, named anywhere but `Haptics.swift`.
    @Test func noCallSiteNamesAGeneratorOrAStyle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        let pattern = try Regex(#"\b(UI(Impact|Selection|Notification)FeedbackGenerator|Haptic(Impact|Selection|Notification))\b"#)
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
        #expect(offenders.isEmpty, "a role, never a style: `Haptics.play(.role)` instead of a generator or a wrapper in \(offenders)")
    }
}
