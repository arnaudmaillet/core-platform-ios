import CoreImage
import Foundation
@testable import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **A PHOTOGRAPH AND A VIDEO CUT THE SAME WAY ARE THE SAME PICTURE.**
///
/// The photo path bakes a crop through `MediaCropRenderer` — the picture turned
/// upright, cut by `FrameCrop.applied(to:)`, rendered `from: extent` through
/// the colour-managed context. The video compositor will cut its upright frame
/// with the same graph and render it into `(0, 0, outputSize)` through its
/// unmanaged context, over black. Two renders of one graph can still disagree:
/// on the size (a rounding each side makes differently — the crop graph
/// before this suite baked 183×247 where the compositor renders 182×246), on
/// the place (a cut left a fraction of a pixel off the origin would be drawn
/// half-covered along its first column) and on colour (linear versus encoded
/// values). This suite renders both and compares every pixel.
///
/// ⚠️ **AT TEN DEGREES**, where the turned picture's box has fractional edges
/// and Core Image rounds its extent outwards — the case an upright cut never
/// exercises.
///
/// ⚠️ **A SMOOTH PATTERN, NOT A CHECKERBOARD.** Turning a picture resamples
/// it, and the managed context works in linear light while the compositor
/// works on encoded values, so across a hard black-to-white edge the two could
/// disagree with nothing wrong. Sine waves a dozen pixels long keep them
/// within a unit of each other (measured) while a one-pixel shift still moves
/// a pixel by up to forty.
struct MediaCropSharedGraphTests {
    /// Buffer 400×300, declared `.right`: drawn upright it is 300×400.
    private func sidewaysWaves() -> UIImage {
        let width = 400
        let height = 300
        var pixels = [UInt8](repeating: 255, count: 4 * width * height)
        func wave(_ position: Int, _ period: Double) -> UInt8 {
            UInt8((127.5 + 100 * sin(Double(position) * 2 * .pi / period)).rounded())
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = 4 * (y * width + x)
                pixels[index] = wave(x, 16)
                pixels[index + 1] = wave(y, 12)
                pixels[index + 2] = wave(x + y, 20)
            }
        }
        let buffer = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * width,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: buffer, scale: 1, orientation: .right)
    }

    /// Eight-bit RGBA, top row first.
    private func bytes(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 4 * image.width * image.height)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 4 * image.width, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    @Test func upturnedRectMatchesThePhotoRendererAt10Degrees() throws {
        let photograph = sidewaysWaves()
        let crop = MediaCrop(rect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.55), angle: 10)

        // The photo path, whole.
        let baked = try #require(MediaCropRenderer.apply(crop, to: photograph)?.cgImage)

        // The compositor's way: the same upright picture, cut by the same
        // graph, drawn into its render size from the origin, over black.
        let upright = try #require(CIImage(image: MediaCropRenderer.upturned(photograph)))
        #expect(upright.extent.size == CGSize(width: 300, height: 400), "guard: the turn is spent, \(upright.extent)")
        let renderSize = crop.outputSize(forUpright: upright.extent.size)
        let cut = try #require(crop.applied(to: upright))
        let frame = cut.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize)))
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        var video = [UInt8](repeating: 0, count: 4 * width * height)
        VideoCompositor.context.render(
            frame, toBitmap: &video, rowBytes: 4 * width,
            bounds: CGRect(origin: .zero, size: renderSize), format: .RGBA8, colorSpace: nil
        )

        #expect(baked.width == width && baked.height == height,
                "the photo baked \(baked.width)×\(baked.height), the compositor renders \(width)×\(height)")
        guard baked.width == width, baked.height == height else { return }

        let photo = bytes(of: baked)
        var worst = 0
        var worstAt = (0, 0)
        for row in 0..<height {
            for column in 0..<width {
                for channel in 0..<3 {
                    let index = 4 * (row * width + column) + channel
                    let difference = abs(Int(photo[index]) - Int(video[index]))
                    if difference > worst {
                        worst = difference
                        worstAt = (column, row)
                    }
                }
            }
        }
        #expect(worst <= 4, "the two renders differ by \(worst) at \(worstAt) (column, row from the top)")
    }
}
