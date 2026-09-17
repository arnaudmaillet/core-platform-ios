import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MediaPlayback

/// Where a look graph is drawn: the photo path's colour-managed context, or the
/// compositor's unmanaged one.
///
/// ⚠️ **A GRAPH IS ONLY `CIImage -> CIImage`; WHAT IT DRAWS DEPENDS ON THE
/// CONTEXT.** The same filter does its arithmetic on linear light under the
/// first and on encoded values under the second, so every pixel test here runs
/// on both — a stage checked under one alone says nothing about the other.
enum LookSurface: String, CaseIterable, CustomTestStringConvertible {
    case photo
    case video

    var context: CIContext {
        switch self {
        case .photo: EditingRenderContext.shared
        case .video: VideoCompositor.context
        }
    }

    /// What the bitmap is written in: sRGB for the photo path, whose output is
    /// sRGB; nothing for the compositor, which converts nothing.
    var space: CGColorSpace? {
        switch self {
        case .photo: CGColorSpace(name: CGColorSpace.sRGB)
        case .video: nil
        }
    }

    var testDescription: String { rawValue }

    /// `image` drawn over `rect` (its own extent when nil).
    func draw(_ image: CIImage, in rect: CGRect? = nil) -> PictureBitmap {
        let bounds = rect ?? image.extent
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        var bytes = [UInt8](repeating: 0, count: 4 * width * height)
        context.render(
            image, toBitmap: &bytes, rowBytes: 4 * width, bounds: bounds,
            format: .RGBA8, colorSpace: space
        )
        return PictureBitmap(width: width, height: height, bytes: bytes)
    }

    /// The alpha of every pixel of `image`, UNCLAMPED.
    ///
    /// ⚠️ **FLOATS, BECAUSE AN 8-BIT RENDER HIDES A BROKEN ALPHA.** An alpha of
    /// 3 is written as 255, and the picture looks right until the next blend
    /// divides by it.
    func alphas(of image: CIImage) -> [Float] {
        let bounds = image.extent
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        var values = [Float](repeating: 0, count: 4 * width * height)
        context.render(
            image, toBitmap: &values, rowBytes: 16 * width, bounds: bounds,
            format: .RGBAf, colorSpace: self == .photo ? CGColorSpace(name: CGColorSpace.extendedSRGB) : nil
        )
        return stride(from: 3, to: values.count, by: 4).map { values[$0] }
    }
}

/// Eight-bit RGBA pixels, read the way Core Image lays a picture out.
struct PictureBitmap {
    struct RGB: Equatable, CustomStringConvertible {
        let r: Int
        let g: Int
        let b: Int

        var description: String { "(\(r),\(g),\(b))" }

        /// The largest difference on any channel.
        func distance(to other: RGB) -> Int {
            max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
        }
    }

    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// The pixel `x` across and `y` UP from the bottom edge — Core Image's
    /// convention. ⚠️ The bitmap itself is written top row first (measured), so
    /// the row is flipped here and nowhere else.
    func rgb(_ x: Int, _ y: Int) -> RGB {
        let index = 4 * ((height - 1 - y) * width + x)
        return RGB(r: Int(bytes[index]), g: Int(bytes[index + 1]), b: Int(bytes[index + 2]))
    }

    var centre: RGB { rgb(width / 2, height / 2) }

    /// The mean of one channel (0 red, 1 green, 2 blue) over the whole picture.
    func mean(channel: Int = 0) -> Double {
        let values = stride(from: channel, to: bytes.count, by: 4).map { Double(bytes[$0]) }
        return values.reduce(0, +) / Double(values.count)
    }

    /// How far one channel spreads around its mean.
    func deviation(channel: Int = 0) -> Double {
        let mean = mean(channel: channel)
        let values = stride(from: channel, to: bytes.count, by: 4).map { Double(bytes[$0]) }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }

    /// The largest difference between the two pictures on any colour channel.
    func maxDistance(to other: PictureBitmap) -> Int {
        precondition(width == other.width && height == other.height, "compare pictures of one size")
        var worst = 0
        for index in bytes.indices where index % 4 != 3 {
            worst = max(worst, abs(Int(bytes[index]) - Int(other.bytes[index])))
        }
        return worst
    }

    /// The mean difference between the two pictures over every colour channel.
    func meanDistance(to other: PictureBitmap) -> Double {
        precondition(width == other.width && height == other.height, "compare pictures of one size")
        var total = 0
        var count = 0
        for index in bytes.indices where index % 4 != 3 {
            total += abs(Int(bytes[index]) - Int(other.bytes[index]))
            count += 1
        }
        return Double(total) / Double(count)
    }

    /// The share of pixels whose colour moved by more than `slack` on some
    /// channel.
    func shareChanged(from other: PictureBitmap, by slack: Int) -> Double {
        precondition(width == other.width && height == other.height, "compare pictures of one size")
        var changed = 0
        for pixel in 0..<(width * height) {
            let base = 4 * pixel
            let moved = (0..<3).contains { abs(Int(bytes[base + $0]) - Int(other.bytes[base + $0])) > slack }
            if moved { changed += 1 }
        }
        return Double(changed) / Double(width * height)
    }
}

/// Pictures with known pixels, built from bytes.
///
/// ⚠️ **BYTES, NOT GENERATORS.** An sRGB-tagged `CGImage` reaches both contexts
/// as the same encoded values (the managed one converts it to linear and back
/// on output). A `CILinearGradient` does not: it interpolates in the working
/// space, so the photo context and the video one draw different ramps before
/// any look is applied — measured, one pixel read (194,61,139) against
/// (164,59,91).
enum TestPicture {
    /// A picture of `width`×`height` whose colour at (`x`, `y`) — `y` UP from
    /// the bottom, as Core Image counts — is `colour(x, y)` in 0...255.
    static func make(
        width: Int, height: Int, _ colour: (Int, Int) -> (Int, Int, Int)
    ) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: 4 * width * height)
        for row in 0..<height {
            let y = height - 1 - row
            for x in 0..<width {
                let (r, g, b) = colour(x, y)
                let index = 4 * (row * width + x)
                bytes[index] = UInt8(clamping: r)
                bytes[index + 1] = UInt8(clamping: g)
                bytes[index + 2] = UInt8(clamping: b)
            }
        }
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4 * width, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return CIImage(cgImage: image)
    }

    static func flat(_ r: Int, _ g: Int, _ b: Int, width: Int = 64, height: Int = 64) -> CIImage {
        make(width: width, height: height) { _, _ in (r, g, b) }
    }

    /// Detail everywhere: colour ramps across and up, and a diagonal band
    /// pattern in blue, so a blur, a mosaic or a colour map all move pixels.
    static func detailed(width: Int = 96, height: Int = 64) -> CIImage {
        make(width: width, height: height) { x, y in
            (x * 255 / max(1, width - 1), y * 255 / max(1, height - 1), (x + y) % 16 < 8 ? 210 : 40)
        }
    }
}
