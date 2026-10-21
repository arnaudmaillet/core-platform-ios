import Testing
import UIKit
@testable import DesignSystem

/// ⚠️ A CUSTOM SYMBOL KEEPS A SIDE MARGIN (#1566, the owner 2026-10-22: "the
/// comment heart looks clipped"). Their SVGs had their margin guides ON the
/// outline's extents, so the outline's anti-aliased edge fell outside the
/// rendered image and was lost: at 12 pt the heart's lobes came out flat.
/// Apple's symbols keep a margin; ours now do.
@MainActor
struct SymbolMarginTests {
    /// Rows of ink on the image's first and last columns, rendered at 3×.
    private func edgeInk(_ image: UIImage) -> (left: Int, right: Int) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
        guard let cg = rendered.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0) }
        let bytesPerPixel = cg.bitsPerPixel / 8
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * cg.bytesPerRow + x * bytesPerPixel + 3] }
        var left = 0, right = 0
        for y in 0..<cg.height {
            if alpha(0, y) > 40 { left += 1 }
            if alpha(cg.width - 1, y) > 40 { right += 1 }
        }
        return (left, right)
    }

    @Test(arguments: AppSymbol.allCases)
    func noOutlineTouchesItsImagesSides(_ symbol: AppSymbol) throws {
        for weight in [UIImage.SymbolWeight.regular, .semibold] {
            let image = try #require(symbol.image(UIImage.SymbolConfiguration(pointSize: 12, weight: weight)))
            let ink = edgeInk(image)
            #expect(ink.left == 0 && ink.right == 0, "\(symbol.rawValue) at weight \(weight.rawValue) is clipped: \(ink)")
        }
    }
}
