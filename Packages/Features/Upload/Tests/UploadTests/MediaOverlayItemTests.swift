import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// What one overlay's view draws, and what it says.
///
/// ⚠️ **THE RASTERISER IS FAKED HERE, ON PURPOSE.** Until the overlay slice (S3)
/// lands, `OverlayRasterizer.image(for:)` answers nil; what this view owns is
/// what it does with the picture it is handed — asked at the right width and
/// scale, shown the right way up, at the right size. A two-colour picture
/// answers all three: a flipped or mirrored one puts blue where red belongs.
@MainActor
struct MediaOverlayItemTests {
    /// 120×40 pixels: red on the left half, blue on the right.
    private static func twoTone(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    @MainActor
    private final class Asked {
        var calls: [(width: CGFloat, scale: Double)] = []
    }

    /// Reads one pixel of `view` rendered at `scale`, in the view's points.
    private static func pixel(of view: UIView, at point: CGPoint, scale: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let cg = image.cgImage!
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale - 1))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    private func layer(placement: OverlayPlacement, asked: Asked) -> MediaOverlayLayerView {
        let layer = MediaOverlayLayerView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        layer.rasterize = { _, width, scale in
            asked.calls.append((width, scale))
            let factor = scale
            return Self.twoTone(width: Int(120 * factor), height: Int(40 * factor))
        }
        layer.contentSize = CGSize(width: 300, height: 600)
        layer.fit = .fit
        layer.show([FrameOverlay(id: "a", content: .text(TextOverlay(text: "A")), placement: placement)])
        layer.layoutIfNeeded()
        return layer
    }

    @Test(arguments: [1.0, 2.0])
    func itemViewMatchesTheRasterizer(scale: Double) throws {
        let asked = Asked()
        let layer = layer(placement: OverlayPlacement(centre: CGPoint(x: 0.5, y: 0.25), scale: scale), asked: asked)
        let item = try #require(layer.item(for: "a"))
        let screen = layer.traitCollection.displayScale > 0 ? layer.traitCollection.displayScale : 1

        let call = try #require(asked.calls.last)
        #expect(call.width == 300 * screen, "asked for the picture's width in pixels")
        #expect(call.scale == scale, "asked at the placement's scale")

        // 120×40 pixels at scale 1 → 120/screen points wide on the page.
        let wide = 120 * CGFloat(scale) / screen
        let tall = 40 * CGFloat(scale) / screen
        #expect(abs(item.frame.width - wide) < 0.01 && abs(item.frame.height - tall) < 0.01,
                "on screen: \(item.frame.size), expected \(wide)×\(tall)")
        #expect(abs(item.center.y - 150) < 0.01, "a quarter of the way down")

        let left = Self.pixel(of: layer, at: CGPoint(x: item.frame.minX + wide / 4, y: item.center.y), scale: screen)
        let right = Self.pixel(of: layer, at: CGPoint(x: item.frame.maxX - wide / 4, y: item.center.y), scale: screen)
        #expect(left.r > 200 && left.b < 50, "red on the left: \(left)")
        #expect(right.b > 200 && right.r < 50, "blue on the right: \(right)")
    }

    /// While the rasteriser answers nil (S3 not landed), the words are lettered
    /// in UIKit — in the text's face, at the rasteriser's size rule.
    @Test func theFallbackLettersTheText() throws {
        let layer = MediaOverlayLayerView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        layer.rasterize = { _, _, _ in nil }
        layer.contentSize = CGSize(width: 300, height: 600)
        layer.show([FrameOverlay(
            id: "a", content: .text(TextOverlay(text: "Hello", font: .serif, background: .box))
        )])
        layer.layoutIfNeeded()
        let item = try #require(layer.item(for: "a"))

        let lettering = try #require(item.debugLettering)
        #expect(lettering.string == "Hello")
        let font = try #require(lettering.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(abs(font.pointSize - 0.06 * 300) < 0.001, "size: \(font.pointSize)")
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))

        // The box is drawn: dark behind the words.
        let corner = Self.pixel(of: layer, at: CGPoint(x: item.frame.minX + 3, y: item.center.y), scale: 2)
        #expect(corner.a > 100 && corner.r < 60, "box: \(corner)")
    }

    @Test func voiceOverSaysWhatItIsAndOffersTheActions() throws {
        let layer = MediaOverlayLayerView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        layer.rasterize = { _, _, _ in nil }
        layer.contentSize = CGSize(width: 300, height: 600)
        layer.show([FrameOverlay(id: "a", content: .text(TextOverlay(text: "Sale")))])
        let item = try #require(layer.item(for: "a"))

        #expect(item.accessibilityLabel == "Text, Sale")
        #expect(item.accessibilityCustomActions == nil, "inert: nothing offered")

        layer.isEditable = true
        #expect(item.accessibilityCustomActions?.map(\.name) == [
            "Edit", "Delete", "Bring to front", "Bigger", "Smaller", "Rotate left", "Rotate right",
            "Move up", "Move down", "Move left", "Move right"
        ])
    }

    @Test func anEmojiIsNamed() {
        let item = MediaOverlayItemView(overlay: FrameOverlay(content: .emoji("😀")), rasterize: { _, _, _ in nil })
        item.describe()
        #expect(item.accessibilityLabel == "Emoji, Grinning Face")
    }

    @Test func everyNamedFaceResolves() {
        for (font, name) in OverlayFont.namedFaces {
            #expect(UIFont(name: name, size: 12) != nil, "\(font) → \(name)")
        }
        #expect(OverlayFont.namedFaces.count == 4)
    }

    /// ⚠️ A NAME THAT DOES NOT RESOLVE DRAWS NOTHING AND NOTHING ERRORS.
    @Test func everySymbolExists() {
        var names = ["textformat", "trash", "square.3.layers.3d.top.filled"]
        names += TextBackground.allCases.map(MediaTextStyleBar.symbol(for:))
        names += OverlayTextAlignment.allCases.map(MediaTextStyleBar.symbol(for:))
        for name in names {
            #expect(UIImage(systemName: name) != nil, "\(name)")
        }
    }
}
