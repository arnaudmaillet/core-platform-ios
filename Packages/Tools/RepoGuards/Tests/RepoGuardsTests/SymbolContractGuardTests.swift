import Foundation
import Testing

/// One contract per glyph (#1190): every heart and save star comes from
/// `LikesSymbol` and `SaveStar`. The scan half of DesignSystem's
/// `SymbolContractTests` (#2371).
struct SymbolContractGuardTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// The files that own the glyphs and their colours.
    static let owners: Set<String> = ["Palette.swift", "LikesSymbol.swift", "SaveStar.swift", "AppSymbol.swift"]

    /// A heart or star colour picked by hand, or a filled glyph named outside
    /// its contract. The DEBUG button gallery shows the raw cases.
    static let patterns = ["Palette.saveGold", "saveGoldOnMedia", "AppSymbol.saved", "AppSymbol.liked", "\"core.star.fill\"", "\"core.heart.fill\""]

    static let allowed: Set<String> = ["AppButtonGalleryViewController.swift", "LikesHeartView.swift", "AppIconButton.swift"]

    @Test func everyHeartAndStarComesFromItsContract() throws {
        var found: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let name = url.lastPathComponent
                guard !Self.owners.contains(name), !Self.allowed.contains(name) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for pattern in Self.patterns where text.contains(pattern) { found.append("\(name): \(pattern)") }
            }
        }
        #expect(found.isEmpty, "read the heart from LikesSymbol and the star from SaveStar: \(found)")
    }
}
