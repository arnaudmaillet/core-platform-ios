import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#2276), like `OwnedSymbolGuardTests`: every play
/// and pause is the owner's (`AppSymbol.play` / `.pause` /
/// `.playCircle`). The system's names spelled at a call site draw SF's
/// glyph beside the owner's — and renamed to a custom symbol without
/// changing the call, `UIImage(systemName:)` finds nothing and the control
/// draws nothing, silently.
///
/// `play.rectangle*` (settings, the video banner, the shop's item) and
/// LensLab's `play.square` are not play controls: they stay SF, and this
/// does not match them.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct PlayPauseSymbolGuardTests {
    static let names = ["\"play.fill\"", "\"pause.fill\"", "\"play.circle.fill\""]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    static func spellsASystemPlayOrPause(_ text: String) -> Bool {
        names.contains { text.contains($0) }
    }

    @Test func noSourceSpellsTheSystemsPlayOrPause() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.spellsASystemPlayOrPause(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(found.isEmpty, "draw it through AppSymbol.play / .pause / .playCircle: \(found.sorted())")
    }

    @Test func thePatternFindsTheShape() {
        #expect(Self.spellsASystemPlayOrPause(#"UIImage(systemName: "play.fill")"#))
        #expect(Self.spellsASystemPlayOrPause(#"paused ? "pause.fill" : "x""#))
        #expect(Self.spellsASystemPlayOrPause(#"systemName: "play.circle.fill","#))
        #expect(!Self.spellsASystemPlayOrPause(#"UIImage(systemName: "play.rectangle.fill")"#))
        #expect(!Self.spellsASystemPlayOrPause(#"("For You", "play.square")"#))
        #expect(!Self.spellsASystemPlayOrPause("AppSymbol.play.rawValue"))
        #expect(!Self.spellsASystemPlayOrPause(#""core.play.fill""#))
    }
}
