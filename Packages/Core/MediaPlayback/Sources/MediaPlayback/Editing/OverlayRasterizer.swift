import CoreGraphics
import CoreImage
import CoreText
import UIKit

/// Draws overlays: text and emoji into pictures, and every overlay onto a
/// finished frame.
///
/// ⚠️ **ONE RASTERISER FOR THE EXPORT, THE PHOTO BAKE AND THE EDITOR'S VIEWS.**
/// The editor shows overlays as views over the page rather than burning them
/// into its preview — so they can move at 60fps under a finger — and those views
/// draw the image `image(for:outputWidth:scale:)` returns. What the author drags
/// is therefore the very picture that gets published.
///
/// ⚠️ **CORE TEXT, NOT UIKit TEXT DRAWING.** It runs on the compositor's queue
/// and on detached photo renders; nothing here may need the main actor. `UIFont`
/// is used only to FIND a face (it is `Sendable`, and toll-free a `CTFont`).
///
/// ⚠️ **EVERY SIZE IS A FRACTION OF THE FINISHED FRAME'S WIDTH.** A text is set
/// at `textSize` of the width, an emoji or a sticker is `artSize` of it, both
/// times the placement's scale — so an overlay placed on a 390-point canvas
/// covers the same share of a 1080-pixel export, and of a 4032-pixel photograph.
public enum OverlayRasterizer {
    /// A text's point size, in pixels, per pixel of frame width at scale 1.
    static let textSize = 0.06
    /// The side of an emoji or a sticker, per pixel of frame width at scale 1.
    static let artSize = 0.18
    /// How wide a text runs before it wraps, per pixel of frame width at
    /// scale 1.
    ///
    /// ⚠️ **SCALED WITH THE TEXT, SO A PINCH NEVER RE-WRAPS.** The wrap width
    /// grows with the placement's scale exactly as the letters do, so a
    /// paragraph keeps its lines at every size and only its bigness changes.
    static let wrapWidth = 0.8
    /// The longest side a single overlay picture is drawn at.
    ///
    /// ⚠️ **A LARGER ASK IS DRAWN SMALLER AND STRETCHED BACK** (`Raster.density`).
    /// A paragraph pinched up on a 4K frame would otherwise be a bitmap of
    /// hundreds of megabytes for pixels the frame then crops away.
    static let longestSide = 4096.0
    /// What a box background is filled with: black at 60%.
    static let boxInk = OverlayColour(r: 0, g: 0, b: 0, a: 0.6)

    /// One drawn overlay picture.
    struct Raster: Sendable {
        let image: CGImage
        /// Pixels of `image` per pixel of the frame it was drawn for: 1, unless
        /// the picture would have been longer than `longestSide`.
        let density: Double
    }

    /// `overlays` drawn over `image` in array order — the last on top — at
    /// `time` seconds into the film (a photograph passes 0). Stickers come from
    /// `artwork`; one it cannot supply is skipped and everything else is drawn.
    ///
    /// The result keeps `image`'s extent: an overlay pushed past an edge is cut
    /// there. With nothing to draw, it is `image` itself — the same object.
    ///
    /// ⚠️ **`time` IS THE FILM'S, UNWRAPPED.** The artwork knows how long its
    /// loop is and wraps it (`OverlayArtwork`); this file does not.
    public static func composite(
        _ overlays: [FrameOverlay], over image: CIImage, time: Double,
        artwork: (any OverlayArtwork)?
    ) -> CIImage {
        composite(overlays, over: image, time: time, artwork: artwork, cache: .shared)
    }

    /// The picture of one text or emoji overlay, for a finished frame
    /// `outputWidth` pixels wide, at placement scale `scale` — upright and
    /// unplaced, its centre the overlay's centre. Nil for a sticker, whose
    /// pictures come from `OverlayArtwork`, and for text with nothing to draw.
    ///
    /// ⚠️ **ONE IMAGE PIXEL IS ONE FRAME PIXEL** — up to `longestSide` (4096) on
    /// a side, past which the picture is drawn smaller. A view that sizes itself
    /// from this image's pixels therefore stays exact for any canvas-sized ask.
    public static func image(
        for content: FrameOverlay.Content, outputWidth: CGFloat, scale: Double
    ) -> CGImage? {
        raster(for: content, outputWidth: Double(outputWidth), scale: scale, cache: .shared)?.image
    }

    // MARK: - Composite

    static func composite(
        _ overlays: [FrameOverlay], over image: CIImage, time: Double,
        artwork: (any OverlayArtwork)?, cache: OverlayRasterCache
    ) -> CIImage {
        let frame = image.extent
        guard !overlays.isEmpty, !frame.isInfinite, frame.width >= 1, frame.height >= 1 else {
            return image
        }
        // ⚠️ **BLENDED AS ENCODED, IN BOTH CONTEXTS.** See `encoded(_:)`.
        var written = encoded(image)
        var drew = false
        for overlay in overlays {
            guard let picture = picture(
                for: overlay, frameWidth: Double(frame.width), time: time, artwork: artwork, cache: cache
            ) else { continue }
            let placed = place(picture.image, stretch: picture.stretch, at: overlay.placement, in: frame)
            written = encoded(placed).composited(over: written)
            drew = true
        }
        guard drew else { return image }
        return decoded(written).cropped(to: frame)
    }

    /// The overlay's picture, and how much it must be stretched to reach its
    /// size on the frame. Nil when there is nothing to draw.
    private static func picture(
        for overlay: FrameOverlay, frameWidth: Double, time: Double,
        artwork: (any OverlayArtwork)?, cache: OverlayRasterCache
    ) -> (image: CGImage, stretch: Double)? {
        let scale = overlay.placement.scale
        guard scale.isFinite, scale > 0 else { return nil }
        switch overlay.content {
        case .text, .emoji:
            guard let raster = raster(for: overlay.content, outputWidth: frameWidth, scale: scale, cache: cache)
            else { return nil }
            return (raster.image, 1 / raster.density)
        case .sticker(let id):
            let side = artSize * frameWidth * scale
            guard side >= 1, let artwork,
                  let still = artwork.sticker(
                      id, atSeconds: max(0, time), side: Int(min(side, longestSide).rounded())
                  ),
                  still.width > 0, still.height > 0
            else { return nil }
            // ⚠️ **FITTED TO ITS SIDE WHATEVER SIZE THE ARTWORK HANDS BACK.** A
            // strip is baked at a fixed size (StickerKit: 256 for the preview,
            // 384 for the export); the side asked for is a hint, and the size on
            // the frame is this file's decision, not the artwork's.
            return (still, side / Double(max(still.width, still.height)))
        }
    }

    /// `picture` stretched by `stretch`, turned and centred where `placement`
    /// says on `frame`.
    ///
    /// ⚠️ **SCALE, THEN TURN, THEN MOVE — ABOUT THE PICTURE'S OWN CENTRE.** The
    /// placement's centre is the overlay's centre at every scale and angle,
    /// which is what a pinch or a twist under two fingers keeps still.
    private static func place(
        _ picture: CGImage, stretch: Double, at placement: OverlayPlacement, in frame: CGRect
    ) -> CIImage {
        let width = CGFloat(picture.width)
        let height = CGFloat(picture.height)
        // ⚠️ **THE Y FLIP.** `placement.centre` measures down from the top;
        // Core Image measures up from the bottom. Taking `y` straight puts a
        // title at the foot of the picture — something drawn, not an error.
        let centre = CGPoint(
            x: frame.minX + placement.centre.x * frame.width,
            y: frame.minY + (1 - placement.centre.y) * frame.height
        )
        let source = CIImage(cgImage: picture)

        if placement.rotation == 0, stretch == 1 {
            // ⚠️ **WHOLE PIXELS WHEN NOTHING RESAMPLES.** A picture an odd number
            // of pixels wide, centred on a whole pixel, would land on a half one,
            // and linear sampling would blur every glyph edge by that half pixel.
            return source.transformed(by: CGAffineTransform(
                translationX: (centre.x - width / 2).rounded(), y: (centre.y - height / 2).rounded()
            ))
        }
        let k = CGFloat(stretch)
        let transform = CGAffineTransform(translationX: -width / 2, y: -height / 2)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            // ⚠️ **NEGATED.** `rotation` is clockwise as the viewer sees it, and
            // with Core Image's y axis pointing up a positive angle turns the
            // other way — the convention `FrameCrop.applied` states too.
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(placement.rotation)))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
        return source.transformed(by: transform, highQualityDownsample: k < 1)
    }

    /// `image`'s values as sRGB ENCODES them, in whatever working space the
    /// rendering context has.
    ///
    /// ⚠️ **THE BLEND IS DONE ON ENCODED VALUES, AS UIKit DOES IT — MEASURED.**
    /// The editor shows an overlay as a view, and Core Animation blends the
    /// display's encoded values: a 60% black box over white reads 102. The photo
    /// path renders through a colour-managed context whose working space is
    /// linear, where the same box came back 170 over white and 83 over mid-grey
    /// (51 expected) — the published photograph visibly lighter than the editor.
    /// Converting to encoded sRGB around the blend brings the managed context to
    /// 102 and 51. The compositor's unmanaged context has no working space to
    /// convert from, and there the conversion changes nothing: 102 and 51 with it
    /// and without it. `aBoxDrawsItsColourAtTheCentre` reads both contexts.
    private static func encoded(_ image: CIImage) -> CIImage {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        return image.matchedFromWorkingSpace(to: sRGB) ?? image
    }

    /// The inverse of `encoded(_:)`.
    private static func decoded(_ image: CIImage) -> CIImage {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        return image.matchedToWorkingSpace(from: sRGB) ?? image
    }

    // MARK: - Pictures

    static func raster(
        for content: FrameOverlay.Content, outputWidth: Double, scale: Double, cache: OverlayRasterCache
    ) -> Raster? {
        let unit = outputWidth * scale
        guard unit.isFinite, unit > 0 else { return nil }
        switch content {
        case .text(let text):
            let size = textSize * unit
            return cache.raster(for: .init(content, size: size)) {
                draw(text, pointSize: size, wrap: wrapWidth * unit)
            }
        case .emoji(let emoji):
            let side = artSize * unit
            return cache.raster(for: .init(content, size: side)) {
                draw(emoji: emoji, side: side)
            }
        case .sticker:
            return nil
        }
    }

    /// A bitmap `size` pixels big — shrunk to `longestSide` if need be — with
    /// its coordinates still in the pixels asked for, handed to `paint`.
    ///
    /// ⚠️ **PREMULTIPLIED sRGB, TRANSPARENT WHERE NOTHING IS DRAWN.** Core Image
    /// reads the colour space the picture carries, so the ink arrives at the
    /// frame as the author picked it in either kind of context.
    private static func bitmap(size: CGSize, paint: (CGContext) -> Void) -> Raster? {
        let longest = max(size.width, size.height)
        guard longest.isFinite, longest >= 1,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let density = min(1, longestSide / Double(longest))
        let width = max(1, Int((Double(size.width) * density).rounded(.up)))
        let height = max(1, Int((Double(size.height) * density).rounded(.up)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShouldAntialias(true)
        context.setShouldSubpixelPositionFonts(true)
        context.scaleBy(x: CGFloat(density), y: CGFloat(density))
        paint(context)
        return context.makeImage().map { Raster(image: $0, density: density) }
    }

    private static func cgColour(_ colour: OverlayColour) -> CGColor {
        let components = [colour.r, colour.g, colour.b, colour.a].map { CGFloat(min(max($0, 0), 1)) }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGColor(colorSpace: sRGB, components: components)
            ?? CGColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    // MARK: - Text

    /// The face `font` is set in, at `size`. Nil when this system has no such
    /// face — which `OverlayRasterizerTests` checks never happens here.
    ///
    /// ⚠️ **THE SYSTEM'S DESIGNS FOR ROUNDED, SERIF AND MONO; NAMES FOR THE
    /// REST.** The three designs follow the system (SF Rounded, New York, SF
    /// Mono) and have no stable name; the other four are faces iOS ships. A name
    /// that is not installed makes `UIFont(name:)` nil rather than a fallback —
    /// which is what lets a test notice.
    static func font(for font: OverlayFont, size: CGFloat) -> UIFont? {
        let system = UIFont.systemFont(ofSize: size, weight: .bold)
        func designed(_ design: UIFontDescriptor.SystemDesign) -> UIFont? {
            system.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) }
        }
        switch font {
        case .classic: return system
        case .rounded: return designed(.rounded)
        case .serif: return designed(.serif)
        case .mono: return designed(.monospaced)
        case .condensed: return UIFont(name: "AvenirNextCondensed-Bold", size: size)
        case .marker: return UIFont(name: "MarkerFelt-Wide", size: size)
        case .typewriter: return UIFont(name: "AmericanTypewriter-Bold", size: size)
        case .script: return UIFont(name: "SnellRoundhand-Bold", size: size)
        }
    }

    /// Black or white, whichever reads on `band`.
    static func contrasting(_ band: OverlayColour) -> OverlayColour {
        let luminance = 0.2126 * band.r + 0.7152 * band.g + 0.0722 * band.b
        return luminance > 0.6 ? .black : .white
    }

    /// One line of a laid-out paragraph, in the paragraph's own space: y up,
    /// the block's top edge at 0.
    private struct SetLine {
        let line: CTLine
        let origin: CGPoint
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// `text` set at `pointSize`, wrapped at `wrap` pixels.
    ///
    /// ⚠️ **LAID OUT LINE BY LINE, NOT BY A `CTFrame`.** A highlight needs each
    /// line's own width and baseline, and alignment is then a plain offset this
    /// file computes — rather than one a frame applies and does not report.
    ///
    /// ⚠️ **THE PICTURE IS CENTRED ON THE BLOCK, NOT ON THE INK.** Script faces
    /// reach past their advance; the bitmap grows to hold them on both sides
    /// alike, so the picture's centre stays the paragraph's centre and a
    /// placement means the same thing in every face.
    private static func draw(_ text: TextOverlay, pointSize: Double, wrap: Double) -> Raster? {
        let words = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let size = CGFloat(pointSize)
        let face = font(for: text.font, size: size) ?? UIFont.systemFont(ofSize: size, weight: .bold)
        let ink = text.background == .highlight ? contrasting(text.colour) : text.colour
        let attributed = NSAttributedString(string: words, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): face as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColour(ink)
        ])

        // Break into lines.
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        let fontAscent = CTFontGetAscent(face as CTFont)
        let fontDescent = CTFontGetDescent(face as CTFont)
        let fontLeading = CTFontGetLeading(face as CTFont)
        var broken: [(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)] = []
        var start = 0
        while start < length {
            let fits = CTTypesetterSuggestLineBreak(typesetter, start, wrap)
            let count = fits > 0 ? fits : length - start
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let width = max(0, advance - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
            broken.append((line, width, max(ascent, fontAscent), max(descent, fontDescent)))
            start += count
        }

        // Place the lines.
        let block = broken.map(\.width).max() ?? 0
        let flush: CGFloat = switch text.alignment {
        case .leading: 0
        case .centre: 0.5
        case .trailing: 1
        }
        var set: [SetLine] = []
        var top: CGFloat = 0
        for entry in broken {
            let x = ((block - entry.width) * flush).rounded()
            set.append(SetLine(
                line: entry.line, origin: CGPoint(x: x, y: top - entry.ascent),
                width: entry.width, ascent: entry.ascent, descent: entry.descent
            ))
            top -= entry.ascent + entry.descent + fontLeading
        }
        let blockRect = CGRect(x: 0, y: top, width: block, height: -top)

        // What is filled behind the ink.
        var shapes: [(rect: CGRect, radius: CGFloat)] = []
        let fill: OverlayColour?
        switch text.background {
        case .none:
            fill = nil
        case .highlight:
            fill = text.colour
            for entry in set where entry.width > 0 {
                shapes.append((CGRect(
                    x: entry.origin.x - 0.28 * size,
                    y: entry.origin.y - entry.descent - 0.08 * size,
                    width: entry.width + 0.56 * size,
                    height: entry.ascent + entry.descent + 0.16 * size
                ), 0.22 * size))
            }
        case .box:
            fill = boxInk
            shapes.append((blockRect.insetBy(dx: -0.5 * size, dy: -0.35 * size), 0.35 * size))
        }

        // The bitmap holds the block, its shapes and every glyph's reach,
        // symmetrically about the block's centre.
        var reach = shapes.reduce(blockRect) { $0.union($1.rect) }
        for entry in set {
            let ink = CTLineGetBoundsWithOptions(entry.line, .useGlyphPathBounds)
            guard !ink.isNull, !ink.isEmpty else { continue }
            reach = reach.union(ink.offsetBy(dx: entry.origin.x, dy: entry.origin.y))
        }
        let centre = CGPoint(x: blockRect.midX, y: blockRect.midY)
        let halfWidth = (max(centre.x - reach.minX, reach.maxX - centre.x) + 1).rounded(.up)
        let halfHeight = (max(centre.y - reach.minY, reach.maxY - centre.y) + 1).rounded(.up)

        return bitmap(size: CGSize(width: 2 * halfWidth, height: 2 * halfHeight)) { context in
            context.translateBy(x: halfWidth - centre.x, y: halfHeight - centre.y)
            if let fill {
                context.setFillColor(cgColour(fill))
                for shape in shapes {
                    let radius = min(shape.radius, shape.rect.width / 2, shape.rect.height / 2)
                    context.addPath(CGPath(
                        roundedRect: shape.rect, cornerWidth: radius, cornerHeight: radius, transform: nil
                    ))
                }
                // ⚠️ ONE FILL FOR EVERY BAND, SO WHERE TWO LINES' BANDS OVERLAP
                // A TRANSLUCENT COLOUR IS NOT LAID TWICE.
                context.fillPath(using: .winding)
            }
            context.textMatrix = .identity
            for entry in set {
                context.textPosition = entry.origin
                CTLineDraw(entry.line, context)
            }
        }
    }

    // MARK: - Emoji

    /// Apple's colour emoji face.
    static let emojiFace = "AppleColorEmoji"

    /// `emoji` drawn in Apple Color Emoji, in a square `side` pixels across.
    ///
    /// ⚠️ **THE FACE IS NAMED, NOT LEFT TO FALLBACK.** A system font would reach
    /// the emoji face through Core Text's cascade too, but at that font's
    /// metrics; naming it sizes the glyph by its own.
    private static func draw(emoji: String, side: Double) -> Raster? {
        guard !emoji.isEmpty, side >= 1 else { return nil }
        // Sized so the glyph's box — its advance by its line height — fills the
        // square: the metrics are linear in the point size, so measure once.
        let probe = line(emoji, pointSize: 100)
        let probeBox = box(of: probe)
        let largest = max(probeBox.width, probeBox.height)
        guard largest > 0 else { return nil }
        let square = CGFloat(side)
        let glyph = line(emoji, pointSize: 100 * square / largest)
        let glyphBox = box(of: glyph)

        return bitmap(size: CGSize(width: square, height: square)) { context in
            context.textMatrix = .identity
            context.textPosition = CGPoint(
                x: (square - glyphBox.width) / 2,
                y: (square - glyphBox.height) / 2 + glyphBox.descent
            )
            CTLineDraw(glyph, context)
        }
    }

    private static func line(_ string: String, pointSize: CGFloat) -> CTLine {
        let face = CTFontCreateWithName(emojiFace as CFString, pointSize, nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): face
        ]))
    }

    private static func box(of line: CTLine) -> (width: CGFloat, height: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return (width, ascent + descent, descent)
    }
}
