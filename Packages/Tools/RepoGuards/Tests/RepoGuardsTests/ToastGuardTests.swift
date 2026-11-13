import Foundation
import Testing

/// One toast presenter, one host (#954, #2143). Moved from DesignSystem's
/// `FeedbackTests` (#2371).
struct ToastGuardTests {
    /// ⚠️ One host (#2143): the bar host and the positions are gone, and
    /// nothing brings them back — no `NavigationBarToasts`, no
    /// `ToastPosition`.
    @Test func noBarToastsLeft() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        let pattern = try Regex(#"\bNavigationBarToasts\b|\bToastPosition\b"#)
        var offenders: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"),
                      url.lastPathComponent != "ToastGuardTests.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains(pattern) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "the bar toasts are back in: \(offenders)")
    }

    /// ⚠️ The presenter only works if NOTHING bypasses it. Scans the app's and
    /// the packages' sources for `ToastView.present(` anywhere but `Feedback`
    /// and the scene overlay it draws through (#954), which only `Feedback`
    /// reaches.
    @Test func onlyFeedbackPresentsToasts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        let pattern = try Regex(#"\bToastView\s*\.\s*present\s*\("#)
        var offenders: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      !["Feedback.swift", "ToastOverlay.swift"].contains(url.lastPathComponent) else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains(pattern) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "ToastView.present called outside Feedback in: \(offenders)")
    }
}
