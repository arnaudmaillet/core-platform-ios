import CoreGraphics
import Foundation
@testable import StickerKit

/// Pictures the tests make and read, in one known layout: RGBA, 8 bits,
/// premultiplied, sRGB, row 0 at the TOP.
enum TestPictures {
    struct RGBA: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

    /// A `side`-pixel square of one opaque colour.
    static func solid(red: CGFloat, green: CGFloat, blue: CGFloat, side: Int = 16) -> CGImage {
        let context = makeContext(side: side)
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    /// Every pixel of `image`, redrawn into the known layout.
    static func pixels(of image: CGImage) -> [RGBA] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map {
            RGBA(r: bytes[$0], g: bytes[$0 + 1], b: bytes[$0 + 2], a: bytes[$0 + 3])
        }
    }

    /// The pixel in the middle of `image`.
    static func centre(of image: CGImage) -> RGBA {
        pixels(of: image)[(image.height / 2) * image.width + image.width / 2]
    }

    /// How many pixels of `image` carry any ink at all.
    static func inkedPixels(in image: CGImage) -> Int {
        pixels(of: image).count { $0.a > 0 }
    }

    /// A strip whose frames are the given colours, shown `framesPerSecond`.
    static func strip(
        _ colours: [(CGFloat, CGFloat, CGFloat)], framesPerSecond: Int = 1, side: Int = 16
    ) -> StickerStrip {
        let frames = colours.map { StickerStrip.png(solid(red: $0.0, green: $0.1, blue: $0.2, side: side))! }
        return StickerStrip(
            stickerID: "test", side: side, framesPerSecond: framesPerSecond,
            seconds: Double(colours.count) / Double(framesPerSecond), frames: frames
        )
    }

    private static func makeContext(side: Int) -> CGContext {
        CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}

/// Waits until `condition` holds or `timeout` passes, whichever is first.
///
/// ⚠️ **RETURNS SILENTLY ON TIMEOUT.** Follow it with a `#require` on the
/// condition, or a test that never landed reads like one that did.
@MainActor
func settle(timeout: Duration = .seconds(10), until condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}
