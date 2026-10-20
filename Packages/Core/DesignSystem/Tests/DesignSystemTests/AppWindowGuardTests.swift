import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1145), like `StockSpinnerGuardTests`: every window
/// the app makes is an `AppWindow`, so every window carries the bar tap
/// shield (#562) with nothing to remember.
///
/// It scans every source file under `App/` and `Packages/` (tests excluded)
/// for a `UIWindow` built directly (`UIWindow(`) or subclassed
/// (`class Name: UIWindow`). Build or subclass `AppWindow` instead. A file
/// may keep one only with a reason on the list below.
///
/// CI only runs this in DesignSystem's lane, which a change elsewhere does
/// not select: adding a window anywhere, run DesignSystem's tests too.
struct AppWindowGuardTests {
    /// File name → why it makes a plain `UIWindow`.
    static let allowed: [String: String] = [
        "AppWindow.swift": "the one place a window is made: it installs the shield",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` builds or subclasses a plain `UIWindow` — outside
    /// comments.
    static func makesAPlainWindow(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return false }
            return code.contains("UIWindow(") || code.range(of: subclass, options: .regularExpression) != nil
        }
    }

    /// `class Name: UIWindow` — a parameter or a closure's `_: UIWindow` is not one.
    private static let subclass = #"class\s+\w+\s*:\s*UIWindow\b"#

    @Test func everyWindowIsAnAppWindow() {
        var found: Set<String> = []
        var scanned = 0
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                scanned += 1
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.makesAPlainWindow(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(scanned > 100, "the scan found no source at all: \(Self.root.path)")
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "make an AppWindow (or argue the case here): \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer make a plain UIWindow — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.makesAPlainWindow("let window = UIWindow(windowScene: scene)"))
        #expect(Self.makesAPlainWindow("final class LockWindow: UIWindow {"))
        #expect(Self.makesAPlainWindow("final class LockWindow: UIWindow, Sendable {"))
        #expect(!Self.makesAPlainWindow("let window = AppWindow(windowScene: scene)"))
        #expect(!Self.makesAPlainWindow("final class LockWindow: AppWindow {"))
        #expect(!Self.makesAPlainWindow("/// a `UIWindow(windowScene:)` would not carry the shield"))
        #expect(!Self.makesAPlainWindow("func place(in window: UIWindow) {"))
        #expect(!Self.makesAPlainWindow("init(window: UIWindow, appWindow: UIWindow) {"))
        #expect(!Self.makesAPlainWindow(") { [weak self] (_: UIWindow, _: UITraitCollection) in"))
    }
}
