import Testing
import UIKit
@testable import DesignSystem

/// A bar symbol is drawn for the WINDOW's appearance, not iOS's (#1501).
@MainActor
struct BarSymbolTests {
    /// The traits of a view in a hidden window of `style` — off a window, the
    /// test host ignores an override (the ink suites' trap).
    private func traits(in style: UIUserInterfaceStyle) -> (UITraitCollection, AppWindow) {
        let window = AppWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.overrideUserInterfaceStyle = style
        window.isHidden = true
        let view = UIView()
        window.addSubview(view)
        window.layoutIfNeeded()
        return (view.traitCollection, window)
    }

    /// The mean brightness, 0…1, of the bitmap's opaque pixels.
    private func inkBrightness(of image: UIImage) throws -> CGFloat {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum: CGFloat = 0, count: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 240 {
            sum += (CGFloat(pixels[index]) + CGFloat(pixels[index + 1]) + CGFloat(pixels[index + 2])) / (3 * 255)
            count += 1
        }
        try #require(count > 0, "the bitmap drew nothing")
        return sum / count
    }

    private var labelBell: UIImage? {
        UIImage(systemName: "bell.fill", withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.label]))
    }

    /// In a window set to Dark — whatever iOS is — the label's ink is light;
    /// in a window set to Light, dark. Both are asked, so the device's own
    /// appearance cannot make either pass by itself.
    @Test func aBarSymbolTakesTheWindowsAppearance() throws {
        let symbol = try #require(labelBell)
        let (dark, darkWindow) = traits(in: .dark)
        let (light, lightWindow) = traits(in: .light)
        #expect(dark.userInterfaceStyle == .dark)
        #expect(light.userInterfaceStyle == .light)
        #expect(try inkBrightness(of: BarSymbol.baked(symbol, traits: dark)) > 0.8)
        #expect(try inkBrightness(of: BarSymbol.baked(symbol, traits: light)) < 0.2)
        withExtendedLifetime((darkWindow, lightWindow)) {}
    }

    /// One bitmap, kept as drawn: the bar may not swap it for another
    /// appearance's variant.
    @Test func aBarSymbolIsOneOriginalBitmap() throws {
        let symbol = try #require(labelBell)
        let (dark, window) = traits(in: .dark)
        let baked = BarSymbol.baked(symbol, traits: dark)
        #expect(baked.renderingMode == .alwaysOriginal)
        #expect(!baked.isSymbolImage)
        let other = baked.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .light))
        #expect(other == nil || other?.cgImage === baked.cgImage, "a light variant rides along")
        withExtendedLifetime(window) {}
    }
}
