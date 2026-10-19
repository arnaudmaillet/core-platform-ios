import Testing
import UIKit
@testable import DesignSystem

/// THE POINTS COIN IS A WHITE HEART ON THE PINK DISC (#1202). It was a palette
/// symbol, and the top bar's glass dropped the palette's pink: the disc came
/// out a like's red. The coin is baked, so it is a bitmap, and every pixel of
/// its disc is the pink.
@MainActor
struct LikesCoinTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theBadgesCoinIsAWhiteHeartOnThePinkDisc(_ style: UIUserInterfaceStyle) throws {
        let badge = WalletBadgeButton()
        badge.overrideUserInterfaceStyle = style
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(badge)
        badge.layoutIfNeeded()
        let coin = try #require(badge.drawnCoin)
        #expect(coin.isSymbolImage == false, "a symbol is re-rendered by the bar's glass")
        #expect(coin.renderingMode == .alwaysOriginal)

        let pink = Palette.tint.resolvedColor(with: badge.traitCollection)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        pink.getRed(&r, green: &g, blue: &b, alpha: &a)
        let pixels = try Self.opaquePixels(of: coin)
        let disc = pixels.filter { abs($0.r - r) < 0.03 && abs($0.g - g) < 0.03 && abs($0.b - b) < 0.03 }
        let white = pixels.filter { min($0.r, $0.g, $0.b) > 0.95 }
        #expect(disc.count > pixels.count / 2, "the disc is not the pink")
        #expect(white.count > 20, "no white heart")
        let red = pixels.filter { $0.r > 0.9 && $0.g < 0.35 && $0.b < 0.35 }
        #expect(red.isEmpty, "a red pixel on the coin")
        _ = window
    }

    private typealias Pixel = (r: CGFloat, g: CGFloat, b: CGFloat)

    /// Every pixel of `image` at least 90% opaque, un-premultiplied, in sRGB.
    private static func opaquePixels(of image: UIImage) throws -> [Pixel] {
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var pixels: [Pixel] = []
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] >= 230 {
            let alpha = CGFloat(bytes[index + 3])
            pixels.append((CGFloat(bytes[index]) / alpha, CGFloat(bytes[index + 1]) / alpha,
                           CGFloat(bytes[index + 2]) / alpha))
        }
        return pixels
    }
}
