import Testing
import UIKit
@testable import DesignSystem

/// The app's custom glyphs (#1128): every one resolves and draws, at every
/// weight and size it is asked for.
@MainActor
struct AppSymbolTests {
    /// The share of a glyph's square that it paints, light on white.
    private func inked(_ image: UIImage) -> CGFloat {
        let size = CGSize(width: 64, height: 64)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.withTintColor(.black, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
        }
        guard let cg = rendered.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        var dark = 0
        let stride = cg.bytesPerRow, step = cg.bitsPerPixel / 8
        for y in 0..<cg.height {
            for x in 0..<cg.width where bytes[y * stride + x * step] < 128 { dark += 1 }
        }
        return CGFloat(dark) / CGFloat(cg.width * cg.height)
    }

    /// ⚠️ A name that does not resolve draws nothing and errors nowhere.
    @Test(arguments: AppSymbol.allCases)
    func everyGlyphResolvesAndDraws(_ symbol: AppSymbol) throws {
        for weight in [UIImage.SymbolWeight.ultraLight, .regular, .black] {
            let image = try #require(symbol.image(AppSymbol.fixed(20, weight: weight)), "\(symbol) at \(weight)")
            #expect(image.isSymbolImage)
            let ink = inked(image)
            #expect(ink > 0.05 && ink < 0.9, "\(symbol) paints \(ink) of its square")
        }
    }

    /// A filled glyph paints more than its outline.
    @Test func theFilledGlyphsAreFilled() throws {
        for (outline, filled) in [(AppSymbol.like, AppSymbol.liked), (.save, .saved), (.comment, .commentFilled), (.gem, .gemFilled)] {
            let a = inked(try #require(outline.image(AppSymbol.fixed(20))))
            let b = inked(try #require(filled.image(AppSymbol.fixed(20))))
            #expect(b > a, "\(filled) (\(b)) is not fuller than \(outline) (\(a))")
        }
    }

    /// A glyph beside text grows with it, and stops at the ceiling.
    @Test func aTextGlyphFollowsItsText() throws {
        let small = try #require(AppSymbol.like.image(
            AppSymbol.textStyle(.body).applying(UIImage.SymbolConfiguration(
                font: .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .small))
            ))
        ))
        let large = try #require(AppSymbol.like.image(UIImage.SymbolConfiguration(
            font: .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge))
        )))
        #expect(large.size.height > small.size.height)
    }

    /// VoiceOver reads the star as Save, not as a favourite.
    @Test func theStarReadsAsSave() {
        #expect(AppSymbol.save.accessibilityLabel == "Save")
        #expect(AppSymbol.saved.accessibilityLabel == "Saved")
        #expect(AppSymbol.saved.image()?.accessibilityLabel == "Saved")
    }
}
