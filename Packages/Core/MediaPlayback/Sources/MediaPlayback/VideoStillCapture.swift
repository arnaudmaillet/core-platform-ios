import CoreImage
import CoreVideo
import UIKit

/// Turns the buffer a surface is currently displaying into a picture.
///
/// It exists so that "what is this video showing right now" has an answer that
/// costs nothing to ask. The renderer already retains that buffer — one frame,
/// kept to prime a joining surface — so there is no decode, no seek and no
/// second `AVPlayerItemVideoOutput` here: only the conversion.
///
/// ⚠️ THE CONTEXT IS SHARED AND CREATED ONCE. A `CIContext` allocates its own
/// GPU resources, and building one per call is the documented way to make a
/// cheap conversion expensive. It is thread-safe by contract, so one static is
/// enough.
enum VideoStillCapture {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Nil when the buffer cannot be rasterised, which is treated as "no
    /// picture" everywhere this is called — never as an error worth surfacing.
    static func image(from buffer: CVPixelBuffer) -> UIImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        guard let rendered = context.createCGImage(source, from: source.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    /// The same, scaled down so its longest side is at most `maxPixels`: a
    /// picture to keep, not to show once.
    static func image(from buffer: CVPixelBuffer, maxPixels: CGFloat) -> UIImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let longest = max(source.extent.width, source.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxPixels / longest)
        let scaled = scale < 1 ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : source
        guard let rendered = context.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
