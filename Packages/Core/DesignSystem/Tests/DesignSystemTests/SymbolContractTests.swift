import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// ⚠️ ONE CONTRACT PER GLYPH (#1190): the heart is `LikesSymbol`'s, the save
/// star `SaveStar`'s — every surface draws them from there, so none can pick
/// a colour of its own (the sound sheet's star had another gold). A
/// Its scan half is a repository guard in `RepoGuards` (#2371), which every pull request runs.
@MainActor
struct SymbolContractTests {
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

    /// The selector's badges are the solid unread mark, never a gradient
    /// (#2062).
    @Test func aSelectorBadgeIsTheSolidMark() {
        let bar = PagedTabBar(titles: ["All", "Requests"], style: .navigationTitle)
        bar.setBadge(3, at: 0)
        #expect(bar.badgeTint == Palette.counter)
    }
}
