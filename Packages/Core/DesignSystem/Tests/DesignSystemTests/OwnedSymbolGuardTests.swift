import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1128), like `ScaledFontTests` for fonts: a verb or
/// currency the app draws as its OWN glyph (`AppSymbol`) is never spelled as
/// a system symbol name at a call site — the heart, the bookmark / save, the
/// gem, the comment and repost marks. Spelled, it draws the system's glyph
/// beside the app's, or nothing at all.
///
/// CI only runs this in DesignSystem's lane: touching icons anywhere, run
/// DesignSystem's tests too.
struct OwnedSymbolGuardTests {
    /// File name → why it may still spell one.
    static let allowed: [String: String] = [
        "EmoteComposing.swift": "the emote picker's \"symbols\" category tab, not the like verb",
        "MapSubFilterBarView.swift": "the map's Favorite places filter, not the like verb",
    ]

    static let names = [
        "\"heart\"", "\"heart.fill\"", "\"bookmark\"", "\"bookmark.fill\"", "\"star\"", "\"star.fill\"",
        "\"diamond\"", "\"diamond.fill\"", "\"ellipsis.message\"", "\"ellipsis.message.fill\"",
        "\"arrow.trianglehead.2.clockwise.rotate.90\"",
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

    static func spellsAnOwnedSymbol(_ text: String) -> Bool {
        names.contains { text.contains($0) }
    }

    @Test func noCallSiteSpellsAnOwnedSymbol() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.spellsAnOwnedSymbol(text) { found.insert(url.lastPathComponent) }
            }
        }
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "draw it through AppSymbol / UIImage.symbol(named:): \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer spell one — drop them from the list: \(stale.sorted())")
    }

    @Test func thePatternFindsTheShape() {
        #expect(Self.spellsAnOwnedSymbol(#"UIImage(systemName: "heart.fill")"#))
        #expect(!Self.spellsAnOwnedSymbol(#"UIImage(systemName: "heart.circle.fill")"#))
        #expect(!Self.spellsAnOwnedSymbol("AppSymbol.liked.rawValue"))
    }
}
