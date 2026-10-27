import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1769): no "Loading…", "Checking…" or "Measuring…"
/// in shipping UI. A loading row is drawn as the row it stands for, redacted
/// (`SettingsSkeletonRowConfiguration`, the screens' skeletons), never as a
/// sentence saying it is loading. Accessibility labels may still say so —
/// VoiceOver has no bones to see.
///
/// CI only runs this in DesignSystem's lane: adding a loading state anywhere,
/// run DesignSystem's tests too.
struct LoadingTextGuardTests {
    static let literals = ["\"Loading…\"", "\"Loading...\"", "\"Checking…\"", "\"Measuring…\"", "Checking your account…"]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` writes a loading sentence into its UI — outside
    /// comments and accessibility labels.
    static func saysLoading(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.contains("accessibilityLabel") else { return false }
            return literals.contains { code.contains($0) }
        }
    }

    @Test func noScreenSaysItIsLoading() {
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
                if Self.saysLoading(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(scanned > 100, "the scan found no source at all: \(Self.root.path)")
        #expect(found.isEmpty, "draw the row redacted (SettingsSkeletonRowConfiguration, a skeleton), not a loading sentence: \(found.sorted())")
    }

    @Test func theScanFindsTheShape() {
        #expect(Self.saysLoading(#"content.text = "Loading…""#))
        #expect(Self.saysLoading(#"case .loading: return "Checking…""#))
        #expect(!Self.saysLoading(#"cell.accessibilityLabel = "Loading…""#))
        #expect(!Self.saysLoading(#"// a "Loading…" row"#))
    }
}
