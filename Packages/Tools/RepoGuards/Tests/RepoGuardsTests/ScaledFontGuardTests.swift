import Foundation
import Testing

/// The text size ceiling holds only if fonts are made at the app's size.
/// Moved from DesignSystem's `ScaledFontTests` (#2371).
struct ScaledFontGuardTests {
    /// ⚠️ The ceiling only holds if fonts are made at the app's size. Scans
    /// the app and every package that can see DesignSystem for a bare
    /// `preferredFont(forTextStyle:)` (no traits), which reads the iPhone's
    /// setting instead of the app's.
    @Test func noFontReadsTheIPhonesTextSizeDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        // Packages below DesignSystem can't call `appFont`.
        let exempt = ["/MediaPlayback/", "/StickerKit/"]
        let pattern = try Regex(#"preferredFont\(forTextStyle:\s*[^,)]+\)"#)
        var offenders: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      url.lastPathComponent != "ScaledFont.swift",
                      !exempt.contains(where: { path.contains($0) }) else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains(pattern) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "bare preferredFont(forTextStyle:) in: \(offenders)")
    }
}
