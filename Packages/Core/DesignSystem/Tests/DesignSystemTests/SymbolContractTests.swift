import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// ⚠️ ONE CONTRACT PER GLYPH (#1190): the heart is `LikesSymbol`'s, the save
/// star `SaveStar`'s — every surface draws them from there, so none can pick
/// a colour of its own (the sound sheet's star had another gold). A
/// REPO-WIDE scan, like `RawHueGuardTests`: CI runs it in DesignSystem's lane
/// only, so touching a heart or a star anywhere, run DesignSystem's tests.
@MainActor
struct SymbolContractTests {
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

    /// The star's one gold, the full-screen post's (#1188), in both
    /// appearances; saved, the image carries it, at rest it takes the ink.
    @Test func theSaveStarIsOneGold() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            SaveStar.tint.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            #expect(Int((r * 255).rounded()) == 0xFF && Int((g * 255).rounded()) == 0xC5 && Int((b * 255).rounded()) == 0x3D)
        }
        #expect(SaveStar.image(saved: true)?.renderingMode == .alwaysOriginal)
        #expect(SaveStar.image(saved: false)?.renderingMode == .alwaysTemplate)
        #expect(SaveStar.symbol(saved: true) == AppSymbol.saved.rawValue)
    }

    /// A toast's heart is the Points pink, its star the save gold (#1190);
    /// a failure keeps its red, any other glyph the style's ink.
    @Test func aToastGlyphKeepsItsOwnColour() {
        #expect(ToastView.glyphTint(symbol: LikesSymbol.glyph, style: .confirmation) == LikesSymbol.tint)
        #expect(ToastView.glyphTint(symbol: SaveStar.glyph, style: .confirmation) == SaveStar.tint)
        #expect(ToastView.glyphTint(symbol: "bell.fill", style: .confirmation) == .label)
        #expect(ToastView.glyphTint(symbol: LikesSymbol.glyph, style: .failure) == .systemRed)
    }

    /// The selector's badges can wear a gradient (#1190).
    @Test func aSelectorBadgeWearsTheGradient() {
        let bar = PagedTabBar(titles: ["All", "Requests"], style: .navigationTitle)
        bar.setBadge(3, at: 0)
        #expect(bar.debugBadgeGradient(at: 0) == nil, "solid by default")
        bar.badgeGradient = Palette.accentGradient
        #expect(bar.debugBadgeGradient(at: 0) == Palette.accentGradient.map(\.cgColor))
        bar.badgeGradient = nil
        #expect(bar.debugBadgeGradient(at: 0) == nil)
    }
}
