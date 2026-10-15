import UIKit
import Vision

/// Where a banner card crops a picture taller than itself (the owner,
/// 2026-10-15: no poster any more, so a portrait picture is cut into the
/// band). A centred cut kept the shoulders and lost the face.
///
/// ```
///   portrait picture        the card's cut
///   ┌──────────┐
///   │          │
///   │  (face)  │ ← focus   ┌──────────┐
///   │          │           │  (face)  │
///   │   body   │           └──────────┘
///   │          │
///   └──────────┘
/// ```
///
/// - A FACE, when Vision finds one: the cut is centred on the faces it
///   finds (their union), clamped to the picture.
/// - Otherwise THE PICTURE'S RATIO: a subject sits higher the taller the
///   picture — the centre for a square, a third of the way down for a 9:16
///   portrait, linear in between — and the cut is centred there.
enum BannerFocalCrop {
    /// The banner card's shape, width over height: near 35% of a phone's
    /// height, the card's width less its margins.
    static let bandAspect: CGFloat = 1.3

    /// Where the subject of a picture of `aspect` (width over height) sits,
    /// as a fraction of its height from the top, with no face to go by.
    static func focusY(aspect: CGFloat) -> CGFloat {
        let square: CGFloat = 1, tall: CGFloat = 9.0 / 16.0
        guard aspect < square else { return 0.5 }
        let t = min(1, max(0, (square - aspect) / (square - tall)))
        return 0.5 + (1.0 / 3.0 - 0.5) * t
    }

    /// The cut of `imageSize` at `targetAspect`, `focusY` of the picture's
    /// height landing `anchor` of the way down the cut — the middle of what
    /// the card SHOWS of it — inside the picture. The whole picture when it is already
    /// as wide as the cut.
    static func cropRect(
        imageSize: CGSize, targetAspect: CGFloat, focusY: CGFloat, anchor: CGFloat = 0.5
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, targetAspect > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let height = imageSize.width / targetAspect
        guard height < imageSize.height else { return CGRect(origin: .zero, size: imageSize) }
        let top = min(max(0, imageSize.height * focusY - height * anchor), imageSize.height - height)
        return CGRect(x: 0, y: top, width: imageSize.width, height: height)
    }

    /// `image` cut to `targetAspect` around `focusY`; the image itself when
    /// it needs no cut.
    static func cropped(
        _ image: UIImage, targetAspect: CGFloat = bandAspect, focusY: CGFloat, anchor: CGFloat = 0.5
    ) -> UIImage {
        let size = image.size
        let rect = cropRect(imageSize: size, targetAspect: targetAspect, focusY: focusY, anchor: anchor)
        guard rect.size != size, let cg = image.cgImage else { return image }
        let scale = CGFloat(cg.height) / size.height
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        guard let cut = cg.cropping(to: pixels) else { return image }
        return UIImage(cgImage: cut, scale: image.scale, orientation: .up)
    }

    /// The smallest side, in pixels, a picture needs for a face search.
    static let minimumFacePixels = 256

    /// Whether `image` is taller than the card, so a cut chooses what shows.
    static func needsCut(_ image: UIImage, targetAspect: CGFloat = bandAspect) -> Bool {
        image.size.height > 0 && image.size.width / image.size.height < targetAspect
    }

    /// The faces' centre in `image`, as a fraction of its height from the
    /// top — nil when Vision finds none. Off the main thread: a request is a
    /// few milliseconds on a decoded picture.
    static func faceFocusY(in image: UIImage) async -> CGFloat? {
        // A thumbnail-sized picture has no face worth a Vision pass (and the
        // test host's synthetic pictures would each pay for one).
        guard let cg = image.cgImage, min(cg.width, cg.height) >= minimumFacePixels else { return nil }
        return await Task.detached(priority: .utility) { () -> CGFloat? in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let faces = request.results, !faces.isEmpty else { return nil }
            // Vision's boxes are normalised with the origin at the bottom.
            let union = faces.map(\.boundingBox).reduce(faces[0].boundingBox) { $0.union($1) }
            return 1 - union.midY
        }.value
    }
}
