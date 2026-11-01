import UIKit

/// The Profile tab's avatar with the bar's unread dot cut into it (#2034):
/// the dot the glyph tabs wear (`TabGlyph`'s badge layer), the same size and
/// at the same height, on the avatar's rim.
///
/// ⚠️ MEASURED FROM THE GLYPHS, never a constant: the dot's diameter and its
/// height come from a badged glyph's own badge layer, so the avatar's dot
/// follows the glyphs if their art changes.
///
/// ⚠️ ONE BOX FOR BOTH STATES (the owner, 2026-10-15, as the glyphs have):
/// the avatar sits at the centre of a box padded to hold the dot, badged or
/// not, so it never moves or resizes as the dot comes and goes.
///
/// ⚠️ A TRUE CUTOUT, never a stroke in a guessed colour (#1912, the pill's
/// relation badge): the bar's glass shows through the ring round the dot.
public enum TabAvatarBadge {
    /// The avatar's side in the bar (`MainTabCoordinator.circularBarImage`).
    public static let avatarSide: CGFloat = 30
    /// The clear ring round the dot — the relation mark's cutout gap
    /// (`RelationMarkMetrics.cutoutGap`, #1912).
    public static let cutoutGap: CGFloat = 1.5

    /// A glyph's dot: its diameter, and its centre's height from the glyph
    /// image's vertical centre (negative: above it).
    public struct Dot: Equatable, Sendable {
        public let diameter: CGFloat
        public let centreOffsetY: CGFloat

        public init(diameter: CGFloat, centreOffsetY: CGFloat) {
            self.diameter = diameter
            self.centreOffsetY = centreOffsetY
        }
    }

    /// The Messages glyph's dot, measured from its badge layer alone.
    @MainActor public static let glyphDot: Dot = measureDot(of: TabGlyph.messages) ?? Dot(diameter: 7, centreOffsetY: -8)

    /// Measures `glyph`'s dot: the badged symbol drawn with its glyph layer
    /// clear and its badge layer opaque, at the bar's size, and the badge's
    /// pixels' bounds read back. Nil if the symbol has no badge pixels.
    @MainActor
    public static func measureDot(of glyph: TabGlyph) -> Dot? {
        let configuration = TabGlyph.symbolConfiguration
            .applying(UIImage.SymbolConfiguration(paletteColors: [.clear, .black]))
        guard let symbol = glyph.symbol(selected: false, badged: true).image(configuration) else { return nil }
        let scale: CGFloat = 4
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.draw(at: .zero)
        }
        guard let bounds = opaqueBounds(of: rendered) else { return nil }
        let diameter = max(bounds.width, bounds.height) / scale
        let centreY = bounds.midY / scale
        return Dot(diameter: diameter, centreOffsetY: centreY - symbol.size.height / 2)
    }

    /// The box both images are drawn in: the avatar centred, with room on
    /// every side for the dot and its gap wherever it sits on the rim.
    public static func boxSide(for dot: Dot) -> CGFloat {
        avatarSide + 2 * (dot.diameter / 2 + cutoutGap)
    }

    /// The dot's centre in the box: on the avatar's rim, at the glyphs' dot
    /// height (the box is centred in the item as the glyph is), on the
    /// trailing side. A height past the rim's reach pins it to the rim's top.
    public static func dotCentre(for dot: Dot) -> CGPoint {
        let side = boxSide(for: dot)
        let radius = avatarSide / 2
        let centre = side / 2
        let dy = min(max(dot.centreOffsetY, -radius), radius)
        let dx = (radius * radius - dy * dy).squareRoot()
        return CGPoint(x: centre + dx, y: centre + dy)
    }

    /// The tab's image: `avatar` (already circular, `avatarSide` across) in
    /// the box, and with `badged` the dot in its cutout. Original rendering,
    /// so the bar tints neither the photo nor the dot.
    @MainActor
    public static func image(avatar: UIImage, badged: Bool, dot: Dot = glyphDot) -> UIImage {
        let side = boxSide(for: dot)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let inset = (side - avatarSide) / 2
            avatar.draw(in: CGRect(x: inset, y: inset, width: avatarSide, height: avatarSide))
            guard badged else { return }
            let centre = dotCentre(for: dot)
            let cut = dot.diameter / 2 + cutoutGap
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: CGRect(x: centre.x - cut, y: centre.y - cut, width: cut * 2, height: cut * 2))
            context.cgContext.setBlendMode(.normal)
            TabGlyph.badgeTint.setFill()
            let r = dot.diameter / 2
            context.cgContext.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// The bounds, in pixels, of `image`'s pixels that are not clear.
    static func opaqueBounds(of image: UIImage) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // A bitmap context's first row in memory is the image's top row.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The alpha at `point` (in points) of `image`, for tests.
    static func alpha(of image: UIImage, at point: CGPoint) -> CGFloat {
        guard let cgImage = image.cgImage else { return 0 }
        let scale = image.scale
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return CGFloat(pixel[3]) / 255
    }
}
