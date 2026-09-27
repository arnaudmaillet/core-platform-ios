import Accelerate
import AVFoundation
import UIKit

/// How a full-screen page draws ONE picture: edge to edge, or whole and fitted
/// on a backdrop.
///
/// Only the fullscreen post page ever asks for anything but `.fill` — grids,
/// cards, markers and profile tiles keep filling, and a `.card` carousel is
/// never told about framing at all. Which one a picture gets is a product rule
/// on its shape, owned by the feed (`SnapMediaAspect`); this is only the
/// vocabulary and the drawing it implies.
public enum MediaFraming: Equatable, Sendable {
    /// Aspect-fill: the picture covers the page and is cropped to it.
    case fill
    /// Aspect-fit, with the page around the picture filled by a stretched,
    /// heavily blurred, darkened copy of the picture itself
    /// (`MediaBackdrop.blurred`).
    case fitBlurred
    /// Aspect-fit on plain black bands.
    case fitBlack

    /// Whether the picture is drawn whole.
    public var fits: Bool { self != .fill }

    /// The content mode a still is drawn with.
    public var contentMode: UIView.ContentMode { fits ? .scaleAspectFit : .scaleAspectFill }

    /// The gravity a playback surface is drawn with.
    public var videoGravity: AVLayerVideoGravity { fits ? .resizeAspect : .resizeAspectFill }

    /// Where a picture of `aspect` sits when fitted into `area`: centred, as
    /// large as fits — the rect `.scaleAspectFit` and `.resizeAspect` draw
    /// into. `area` itself for a degenerate aspect.
    public static func fittedRect(aspect: CGSize, in area: CGRect) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / aspect.width, area.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// The blurred backdrop a `.fitBlurred` page draws around its picture.
///
/// ⚠️ ONE RENDITION, SHARED BY THE PAGE AND THE HERO. The flight that opens or
/// closes a fitted page flies this very image as its window's backdrop
/// (`ZoomPageFraming.Backdrop.picture`), and hands over to the page at full
/// screen. Two blurs of one photograph computed two ways — a system material
/// on one side, a filter on the other — differ by exactly the amount a viewer
/// reads as a flash at the hand-over; the same function over the same picture
/// cannot.
///
/// **How, and why it is cheap.** The picture is reduced to a few dozen pixels
/// on its long side, blurred there with two tent passes (≈ a gaussian) and
/// darkened, and the view stretches the result aspect-fill over the page with
/// bilinear filtering. At that size the blur is microseconds of vImage and the
/// upscale is free, so "heavily blurred" costs nothing per frame — the page
/// composites one static image. The reduction is also what makes the tile's
/// small cover and the page's full-resolution photo blur to the same thing:
/// both average down to the same few dozen pixels.
@MainActor
public enum MediaBackdrop {
    /// Long side of the reduced picture, in pixels. Small enough that the
    /// upscale to a full screen IS most of the blur, large enough to keep the
    /// picture's broad colour regions where they are.
    nonisolated static let reducedLongSide = 40
    /// Tent kernel (odd), applied twice.
    nonisolated static let kernel: UInt32 = 7
    /// How much black is laid over the blur — enough that white captions and
    /// the fitted picture's own edge read against it, not so much that the
    /// band reads as a black band with a tint.
    nonisolated static let darkening: CGFloat = 0.2

    private static let cache: NSCache<UIImage, UIImage> = {
        let cache = NSCache<UIImage, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    /// The backdrop for `image`, cached per image object. Nil for an image
    /// with no pixels.
    ///
    /// Synchronous by design: a hero builds its window in the turn the tap
    /// lands, and a backdrop that arrived a turn later would be a window
    /// flying on black and then flashing its blur in.
    public static func blurred(_ image: UIImage) -> UIImage? {
        if let cached = cache.object(forKey: image) { return cached }
        guard let result = render(image) else { return nil }
        cache.setObject(result, forKey: image)
        return result
    }

    private static func render(_ image: UIImage) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let reducedSize = reducedSize(for: size)
        // Area-averaged reduction: `.high` interpolation, so a 1440px photo and
        // its 300px tile cover reduce to the same pixels.
        let reduced = UIGraphicsImageRenderer(size: reducedSize, format: rendererFormat)
            .image { context in
                context.cgContext.interpolationQuality = .high
                image.draw(in: CGRect(origin: .zero, size: reducedSize))
            }
        guard let cgImage = reduced.cgImage else { return nil }
        return finish(reduced: cgImage)
    }

    /// The pixel size a picture of `size` is reduced to before it is blurred:
    /// `reducedLongSide` on its long side, in its own shape, never under 2×2.
    nonisolated static func reducedSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 2, height: 2) }
        let scale = CGFloat(reducedLongSide) / max(size.width, size.height)
        return CGSize(width: max(Int((size.width * scale).rounded()), 2),
                      height: max(Int((size.height * scale).rounded()), 2))
    }

    /// The second half of the backdrop, blur then darkening, over a picture
    /// ALREADY reduced to `reducedSize`.
    ///
    /// ⚠️ SHARED BY THE STILL AND THE LIVE BAND (`LiveMediaBackdrop`), which is
    /// why it is a function of its own. A playing clip's band is made from its
    /// decoded frames, reduced by VideoToolbox instead of by a context draw, and
    /// then finished HERE. So a poster and the frame that replaces it go
    /// through the same blur and the same darkening, and the hand-over from
    /// one to the other cannot change the look.
    ///
    /// Nonisolated: the live band finishes its frames off the main thread, and
    /// `UIGraphicsImageRenderer` and vImage are both safe there.
    nonisolated static func finish(reduced cgImage: CGImage) -> UIImage? {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        guard size.width > 0, size.height > 0 else { return nil }
        let blurred = tentBlur(cgImage) ?? cgImage
        return UIGraphicsImageRenderer(size: size, format: rendererFormat)
            .image { context in
                UIImage(cgImage: blurred).draw(in: CGRect(origin: .zero, size: size))
                // ⚠️ `.normal`, stated: the renderer's plain `fill` is
                // `UIRectFill`, which COPIES — a translucent black copied over an
                // opaque canvas is solid black, and every backdrop came out as
                // plain black bands until a spec read the pixels.
                UIColor.black.withAlphaComponent(darkening).setFill()
                context.fill(CGRect(origin: .zero, size: size), blendMode: .normal)
            }
    }

    /// One pixel per point, opaque, standard range: the backdrop is a handful
    /// of pixels stretched over a page, and nothing about it is wide colour.
    nonisolated private static var rendererFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return format
    }

    /// Two tent passes over the reduced picture, edges extended so the border
    /// does not darken toward transparent.
    nonisolated private static func tentBlur(_ image: CGImage) -> CGImage? {
        // An explicit 8-bit format, never the image's own: an ARGB8888
        // convolution reads bytes, and a picture decoded wide (16-bit half
        // floats) would be convolved as garbage.
        guard let format = vImage_CGImageFormat(
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue)
              ),
              var source = try? vImage_Buffer(cgImage: image, format: format)
        else { return nil }
        defer { source.free() }
        guard var scratch = try? vImage_Buffer(
            width: Int(source.width), height: Int(source.height), bitsPerPixel: format.bitsPerPixel
        ) else { return nil }
        defer { scratch.free() }
        let flags = vImage_Flags(kvImageEdgeExtend)
        guard vImageTentConvolve_ARGB8888(&source, &scratch, nil, 0, 0, kernel, kernel, nil, flags)
                == kvImageNoError,
              vImageTentConvolve_ARGB8888(&scratch, &source, nil, 0, 0, kernel, kernel, nil, flags)
                == kvImageNoError
        else { return nil }
        return try? source.createCGImage(format: format)
    }
}
