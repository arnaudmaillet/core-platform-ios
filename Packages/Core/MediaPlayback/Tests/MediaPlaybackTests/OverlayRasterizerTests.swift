import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Synchronization
import Testing
import UIKit
@testable import MediaPlayback

/// **WHAT AN OVERLAY LOOKS LIKE IS WHAT IT DRAWS.**
///
/// Every assertion here reads pixels: of the picture `OverlayRasterizer.image`
/// hands the editor's views, or of a frame rendered after `composite` — never
/// the transforms or rectangles the rasteriser worked out on the way.
///
/// ⚠️ **ASYMMETRIC ON PURPOSE.** A placement near the top, a two-colour sticker,
/// two lines of different lengths: a flipped axis or a rotation spent the other
/// way still draws something, and only a picture that is not its own mirror
/// image can tell.
///
/// ⚠️ **SIZES ARE CHECKED AT TWO WIDTHS OR TWO SCALES** — a measured size that
/// happens to equal the expected one at a single input proves nothing about the
/// rule that produced it.
struct OverlayRasterizerTests {
    // MARK: - Fixtures

    /// Premultiplied sRGB bytes of a picture, row 0 at the TOP.
    private struct Bitmap {
        struct Pixel {
            let r: Int, g: Int, b: Int, a: Int

            var isRed: Bool { r > 180 && g < 90 && b < 90 && a > 200 }
            var isGreen: Bool { g > 150 && r < 90 && b < 90 && a > 200 }
            var isBlue: Bool { b > 180 && r < 90 && g < 90 && a > 200 }
            var isWhite: Bool { r > 200 && g > 200 && b > 200 && a > 200 }
            var isOpaque: Bool { a > 200 }
            var isClear: Bool { a == 0 }

            func isGrey(_ level: Int, within tolerance: Int = 6) -> Bool {
                abs(r - level) <= tolerance && abs(g - level) <= tolerance && abs(b - level) <= tolerance
            }
        }

        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let width = width, height = height
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.bytes = bytes
        }

        subscript(x: Int, y: Int) -> Pixel {
            let i = (y * width + x) * 4
            return Pixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
        }

        /// The box and centre of every pixel `matches` accepts; nil when none
        /// does.
        func region(where matches: (Pixel) -> Bool) -> (box: CGRect, centre: CGPoint, count: Int)? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            var sumX = 0, sumY = 0, count = 0
            for y in 0..<height {
                for x in 0..<width where matches(self[x, y]) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    sumX += x; sumY += y; count += 1
                }
            }
            guard count > 0 else { return nil }
            return (
                CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                CGPoint(x: Double(sumX) / Double(count) + 0.5, y: Double(sumY) / Double(count) + 0.5),
                count
            )
        }
    }

    /// The two kinds of context the rasteriser's output is rendered through.
    enum Renderer: String, CaseIterable, Sendable {
        /// The photo path's: colour-managed, linear working space.
        case photo
        /// The compositor's: unmanaged, values passed through.
        case video

        var context: CIContext {
            switch self {
            case .photo: EditingRenderContext.shared
            case .video: VideoCompositor.context
            }
        }
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A flat frame `width` by `height`, from the origin, in grey `level`.
    private func frame(_ width: Int, _ height: Int, grey level: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level, alpha: 1, colorSpace: Self.sRGB)!)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func rendered(_ image: CIImage, through renderer: Renderer = .photo) throws -> Bitmap {
        let picture = try #require(renderer.context.createCGImage(
            image, from: image.extent, format: .RGBA8, colorSpace: Self.sRGB
        ))
        return Bitmap(picture)
    }

    private func picture(
        _ content: FrameOverlay.Content, width: CGFloat, scale: Double = 1,
        cache: OverlayRasterCache = OverlayRasterCache(budget: 64 << 20)
    ) throws -> Bitmap {
        let raster = try #require(OverlayRasterizer.raster(
            for: content, outputWidth: Double(width), scale: scale, cache: cache
        ))
        return Bitmap(raster.image)
    }

    private static let red = (r: UInt8(255), g: UInt8(0), b: UInt8(0))
    private static let green = (r: UInt8(0), g: UInt8(255), b: UInt8(0))
    private static let blue = (r: UInt8(0), g: UInt8(0), b: UInt8(255))

    /// An opaque square `side` pixels across: `top` over its upper half,
    /// `bottom` under it.
    private static func square(
        side: Int, top: (r: UInt8, g: UInt8, b: UInt8), bottom: (r: UInt8, g: UInt8, b: UInt8)? = nil
    ) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            let colour = y < side / 2 ? top : (bottom ?? top)
            for x in 0..<side {
                let i = (y * side + x) * 4
                bytes[i] = colour.r; bytes[i + 1] = colour.g; bytes[i + 2] = colour.b
            }
        }
        // Row 0 of a data provider is the picture's top.
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    /// Sticker art that draws whatever `draw` says and remembers every ask.
    private final class Art: OverlayArtwork {
        struct Ask: Equatable { let id: String; let seconds: Double; let side: Int }

        private let draw: @Sendable (String, Double, Int) -> CGImage?
        private let log = Mutex<[Ask]>([])

        init(_ draw: @escaping @Sendable (String, Double, Int) -> CGImage?) {
            self.draw = draw
        }

        var asks: [Ask] { log.withLock { $0 } }

        func sticker(_ id: String, atSeconds seconds: Double, side: Int) -> CGImage? {
            log.withLock { $0.append(Ask(id: id, seconds: seconds, side: side)) }
            return draw(id, seconds, side)
        }
    }

    /// A red square for the sticker "red", at the side asked for; nothing for
    /// any other.
    private static let redArt = Art { id, _, side in
        id == "red" ? square(side: max(side, 1), top: red) : nil
    }

    private func sticker(
        _ id: String = "red", at centre: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: Double = 1, rotation: Double = 0
    ) -> FrameOverlay {
        FrameOverlay(
            id: UUID().uuidString, content: .sticker(id: id),
            placement: OverlayPlacement(centre: centre, scale: scale, rotation: rotation)
        )
    }

    private func text(
        _ words: String, colour: OverlayColour = .white, background: TextBackground = .box,
        alignment: OverlayTextAlignment = .centre
    ) -> FrameOverlay.Content {
        .text(TextOverlay(text: words, colour: colour, background: background, alignment: alignment))
    }

    // MARK: - Backgrounds

    /// A box is black at 60% over whatever it covers. Over a mid-grey frame,
    /// ENCODED 128 × 0.4 = 51 — what Core Animation shows the author in the
    /// editor. A blend in linear light would read about 83, and a missing box
    /// 128.
    @Test(arguments: Renderer.allCases)
    func aBoxDrawsItsColourAtTheCentre(_ renderer: Renderer) throws {
        let base = frame(400, 300, grey: 0.5)
        let written = OverlayRasterizer.composite(
            [FrameOverlay(content: text("HI"))], over: base, time: 0, artwork: nil,
            cache: OverlayRasterCache(budget: 64 << 20)
        )
        let bitmap = try rendered(written, through: renderer)

        #expect(bitmap[5, 5].isGrey(128, within: 2), "guard: the frame is mid-grey, got \(bitmap[5, 5])")
        #expect(bitmap[200, 10].isGrey(128, within: 2),
                "above the box the frame is untouched: \(bitmap[200, 10])")

        var boxed: [Int] = []
        for x in 0..<bitmap.width where bitmap[x, 150].isGrey(51) { boxed.append(x) }
        let first = try #require(boxed.first, "no pixel of the centre row reads 60% black over grey")
        let last = try #require(boxed.last)
        #expect(boxed.count >= 20, "the box shows between and around the letters: \(boxed.count) pixels")
        #expect(abs(Double(first + last) / 2 - 200) <= 3, "the box is centred: it spans \(first)...\(last)")
        #expect(bitmap[first - 4, 150].isGrey(128, within: 2), "left of the box is the frame")
        #expect(bitmap[last + 4, 150].isGrey(128, within: 2), "right of the box is the frame")
    }

    /// And the picture the editor's view draws carries the box itself, at 60%.
    @Test func aBoxPictureIsBlackAtSixtyPercent() throws {
        let bitmap = try picture(text("HI"), width: 400)
        let edge = bitmap[4, bitmap.height / 2]

        #expect(edge.r == 0 && edge.g == 0 && edge.b == 0, "the box is black: \(edge)")
        #expect(abs(edge.a - 153) <= 2, "at 60%: \(edge)")
    }

    /// Two lines, the first long and the second short: each wears its own band
    /// in the text's colour — one unbroken run from end to end, as long as its
    /// line — and the letters are drawn over it in a colour that reads.
    @Test func highlightDrawsBehindEachLine() throws {
        let bitmap = try picture(
            text("WWWWWWWW\nii", colour: OverlayColour(r: 1, g: 0, b: 0), background: .highlight), width: 1000
        )
        func band(atRow y: Int) -> (first: Int, last: Int, unbroken: Bool)? {
            var first: Int?, last: Int?
            for x in 0..<bitmap.width where bitmap[x, y].isOpaque {
                first = first ?? x
                last = x
            }
            guard let first, let last else { return nil }
            return (first, last, (first...last).allSatisfy { bitmap[$0, y].isOpaque })
        }

        let upper = try #require(band(atRow: bitmap.height / 4), "nothing drawn on the first line's row")
        let lower = try #require(band(atRow: 3 * bitmap.height / 4), "nothing drawn on the second line's row")

        #expect(upper.unbroken, "the first line's band has holes: the letters are drawn on nothing")
        #expect(lower.unbroken, "the second line's band has holes — between the two i's, say")
        #expect(bitmap[upper.first + 2, bitmap.height / 4].isRed, "the first band is the text's red")
        #expect(bitmap[lower.first + 2, 3 * bitmap.height / 4].isRed, "the second band is the text's red")
        #expect(lower.last - lower.first < (upper.last - upper.first) / 2,
                "each band is as long as its own line: \(lower) under \(upper)")
        #expect(bitmap[2, 3 * bitmap.height / 4].isClear, "beside the short line there is no band")
        let row = bitmap.height / 4
        #expect((upper.first...upper.last).contains { bitmap[$0, row].isWhite },
                "red is dark, so the letters are white")
    }

    /// The short second line sits left, centred or right, and its ink goes with
    /// it — measured against the other alignments of the same words.
    @Test func leadingAlignmentMovesInkLeft() throws {
        func inkCentre(_ alignment: OverlayTextAlignment) throws -> (x: Double, width: Int) {
            let bitmap = try picture(text("WWWWWWWW\nI", background: .none, alignment: alignment), width: 1000)
            var sum = 0, count = 0
            for y in (bitmap.height / 2 + 2)..<bitmap.height {
                for x in 0..<bitmap.width where bitmap[x, y].a > 128 {
                    sum += x; count += 1
                }
            }
            try #require(count > 0, "no ink on the second line")
            return (Double(sum) / Double(count), bitmap.width)
        }
        let leading = try inkCentre(.leading)
        let centre = try inkCentre(.centre)
        let trailing = try inkCentre(.trailing)

        #expect(leading.width == centre.width && centre.width == trailing.width,
                "guard: the three pictures are the same block")
        #expect(abs(centre.x - Double(centre.width) / 2) < 10, "centred ink sits in the middle: \(centre)")
        #expect(leading.x < centre.x - 100, "leading moves the short line left: \(leading.x) vs \(centre.x)")
        #expect(trailing.x > centre.x + 100, "trailing moves it right: \(trailing.x) vs \(centre.x)")
    }

    // MARK: - Placement

    /// A placement counts from the TOP-LEFT of the frame; Core Image counts from
    /// the bottom. A tall frame and two asymmetric spots catch a missing flip
    /// on either axis.
    @Test func placementPutsTheInkWhereItSays() throws {
        let base = frame(200, 400)
        let cache = OverlayRasterCache(budget: 64 << 20)
        for (spot, expected) in [
            (CGPoint(x: 0.25, y: 0.2), CGPoint(x: 50, y: 80)),
            (CGPoint(x: 0.75, y: 0.8), CGPoint(x: 150, y: 320))
        ] {
            let written = OverlayRasterizer.composite(
                [sticker(at: spot)], over: base, time: 0, artwork: Self.redArt, cache: cache
            )
            let red = try #require(try rendered(written).region { $0.isRed }, "nothing red drawn at \(spot)")

            #expect(abs(red.centre.x - expected.x) <= 1.5 && abs(red.centre.y - expected.y) <= 1.5,
                    "placed at \(spot), the sticker's centre is at \(red.centre), not \(expected)")
        }
    }

    /// A wide box turned a quarter turn stands tall; and a sticker red on top
    /// turned a quarter turn CLOCKWISE has its red on the right.
    @Test func rotationTurnsTheInk() throws {
        let cache = OverlayRasterCache(budget: 64 << 20)
        func darkBox(rotation: Double) throws -> CGRect {
            let overlay = FrameOverlay(
                content: text("WWWWWW"), placement: OverlayPlacement(rotation: rotation)
            )
            let written = OverlayRasterizer.composite(
                [overlay], over: frame(600, 600), time: 0, artwork: nil, cache: cache
            )
            return try #require(try rendered(written).region { $0.r < 160 && $0.g < 160 }).box
        }
        let upright = try darkBox(rotation: 0)
        let turned = try darkBox(rotation: .pi / 2)

        #expect(upright.width > 2 * upright.height, "guard: the box lies wide: \(upright)")
        #expect(turned.height > 2 * turned.width, "a quarter turn stands it up: \(turned)")

        let art = Art { _, _, side in Self.square(side: side, top: Self.red, bottom: Self.blue) }
        func halves(rotation: Double) throws -> (red: CGPoint, blue: CGPoint) {
            let written = OverlayRasterizer.composite(
                [sticker(scale: 2, rotation: rotation)], over: frame(400, 400), time: 0, artwork: art, cache: cache
            )
            let bitmap = try rendered(written)
            let red = try #require(bitmap.region { $0.isRed }).centre
            let blue = try #require(bitmap.region { $0.isBlue }).centre
            return (red, blue)
        }
        let still = try halves(rotation: 0)
        let clockwise = try halves(rotation: .pi / 2)

        #expect(still.red.y < still.blue.y - 20, "guard: unturned, red is on top: \(still)")
        #expect(clockwise.red.x > clockwise.blue.x + 20,
                "turned clockwise the top goes right: red \(clockwise.red), blue \(clockwise.blue)")
        #expect(abs(clockwise.red.y - clockwise.blue.y) < 3, "and the halves sit side by side: \(clockwise)")
    }

    /// Text is set in proportion to the frame: twice the width, twice the
    /// picture; and a scale of 2 on a frame is the size of scale 1 on a frame
    /// twice as wide.
    @Test func scaleFollowsTheOutputWidth() throws {
        // ⚠️ THE BOX, NOT THE BITMAP: the bitmap carries a fixed pixel of margin
        // for antialiasing, which does not scale — and measured, put the small
        // picture's height at exactly 1.9 of the large one's.
        func box(width: CGFloat, scale: Double = 1) throws -> CGRect {
            try #require(try picture(text("Hello"), width: width, scale: scale).region { $0.a > 128 }).box
        }
        let narrow = try box(width: 320)
        let wide = try box(width: 640)
        let doubled = try box(width: 320, scale: 2)

        #expect(abs(wide.width - 2 * narrow.width) <= 3 && abs(wide.height - 2 * narrow.height) <= 3,
                "twice the frame, twice the box: \(narrow.size) then \(wide.size)")
        #expect(doubled.size == wide.size, "scale 2 at 320 is \(doubled.size), scale 1 at 640 is \(wide.size)")

        // And on the frame, a sticker is 18% of the width times its scale.
        let cache = OverlayRasterCache(budget: 64 << 20)
        for (width, scale, side) in [(400, 1.0, 72.0), (400, 2.0, 144.0), (800, 1.0, 144.0)] {
            let written = OverlayRasterizer.composite(
                [sticker(scale: scale)], over: frame(width, width), time: 0, artwork: Self.redArt, cache: cache
            )
            let red = try #require(try rendered(written).region { $0.isRed }).box
            #expect(abs(red.width - side) <= 2 && abs(red.height - side) <= 2,
                    "at \(width) wide and scale \(scale) the sticker is \(red.size), not \(side)")
        }
    }

    /// A sticker pushed half off the frame is cut at the edge: the frame keeps
    /// its size, which a photograph and a video buffer both depend on.
    @Test func anOverlayPastTheEdgeKeepsTheFrame() throws {
        let base = frame(300, 200)
        let written = OverlayRasterizer.composite(
            [sticker(at: CGPoint(x: 1, y: 0.5))], over: base, time: 0, artwork: Self.redArt,
            cache: OverlayRasterCache(budget: 64 << 20)
        )

        #expect(written.extent == base.extent, "the frame grew to \(written.extent)")
        let red = try #require(try rendered(written).region { $0.isRed })
        #expect(red.box.maxX == 300 && abs(red.box.width - 27) <= 2,
                "the half left of the edge is drawn: \(red.box)")
    }

    /// A picture is never drawn past 4096 pixels a side: a larger ask is drawn
    /// smaller, and stretched back on the frame to the size it was asked at.
    /// An emoji at scale 5 on a frame 6000 wide is a 5400-pixel square.
    ///
    /// ⚠️ **THE RED SPAN'S WIDTH, TO 2%, NOT ITS EDGES TO THE PIXEL.** The
    /// emoji's soft rim is upscaled from its small bitmap strike, and "red" over
    /// grey takes in more of that rim than "red" on a clear picture does —
    /// measured, 23 pixels a side at this size, the same on both sides. A
    /// picture left unstretched came out 23% short.
    @Test func aHugeAskIsDrawnSmallerAndStretchedBack() throws {
        let cache = OverlayRasterCache(budget: 256 << 20)
        let raster = try #require(OverlayRasterizer.raster(
            for: .emoji("🟥"), outputWidth: 6000, scale: 5, cache: cache
        ))
        #expect(raster.image.width == 4096 && raster.image.height == 4096,
                "drawn at \(raster.image.width)x\(raster.image.height)")
        #expect(abs(raster.density - 4096.0 / 5400) < 0.0001, "density \(raster.density)")

        func redSpan(_ bitmap: Bitmap, row: Int) -> ClosedRange<Int>? {
            guard let first = (0..<bitmap.width).first(where: { bitmap[$0, row].isRed }),
                  let last = (0..<bitmap.width).last(where: { bitmap[$0, row].isRed })
            else { return nil }
            return first...last
        }
        let picture = try #require(redSpan(Bitmap(raster.image), row: raster.image.height / 2))
        let asked = Double(picture.count) / raster.density

        let overlay = FrameOverlay(content: .emoji("🟥"), placement: OverlayPlacement(scale: 5))
        let bitmap = try rendered(OverlayRasterizer.composite(
            [overlay], over: frame(6000, 20, grey: 0.5), time: 0, artwork: nil, cache: cache
        ))
        let drawn = try #require(redSpan(bitmap, row: 10), "no red on the frame")

        #expect(abs(Double(drawn.count) / asked - 1) < 0.02,
                "the square is \(drawn.count) pixels wide on the frame; drawn smaller, it stands for \(asked)")
        #expect(abs(Double(drawn.lowerBound + drawn.upperBound + 1) / 2 - 3000) <= 2,
                "and it is centred: \(drawn)")
    }

    // MARK: - Emoji and stickers

    /// An emoji is drawn in colour, in a square 18% of the frame wide.
    @Test func emojiDrawsColour() throws {
        for width in [500.0, 1000.0] {
            let bitmap = try picture(.emoji("🟥"), width: width)
            let side = 0.18 * width

            #expect(abs(Double(bitmap.width) - side) <= 1 && abs(Double(bitmap.height) - side) <= 1,
                    "at \(width) wide the emoji is \(bitmap.width)x\(bitmap.height), not \(side)")
            #expect(bitmap[bitmap.width / 2, bitmap.height / 2].isRed,
                    "the red square is red: \(bitmap[bitmap.width / 2, bitmap.height / 2])")
            let red = try #require(bitmap.region { $0.isRed })
            #expect(Double(red.count) > 0.3 * Double(bitmap.width * bitmap.height),
                    "the square fills its picture: \(red.count) red pixels")
        }
    }

    /// Stickers move: the frame drawn is the one the film's time asks for.
    @Test func aStickerFrameIsChosenByTime() throws {
        let art = Art { _, seconds, side in
            Self.square(side: side, top: seconds < 1 ? Self.red : Self.green)
        }
        let cache = OverlayRasterCache(budget: 64 << 20)
        let base = frame(400, 400)
        let early = try rendered(OverlayRasterizer.composite(
            [sticker("dance")], over: base, time: 0.5, artwork: art, cache: cache
        ))
        let late = try rendered(OverlayRasterizer.composite(
            [sticker("dance")], over: base, time: 1.5, artwork: art, cache: cache
        ))

        #expect(early[200, 200].isRed, "half a second in, the first frame: \(early[200, 200])")
        #expect(late[200, 200].isGreen, "a second and a half in, the later frame: \(late[200, 200])")
        #expect(art.asks.map(\.seconds) == [0.5, 1.5], "the times asked: \(art.asks)")
    }

    /// The artwork may hand back any size — a strip is baked once — and the
    /// sticker still covers its own share of the frame.
    @Test func aStickerIsDrawnAtItsBaseSizeWhateverTheArtworkReturns() throws {
        let art = Art { _, _, _ in Self.square(side: 64, top: Self.red) }
        let cache = OverlayRasterCache(budget: 64 << 20)
        for (width, side) in [(500, 90.0), (250, 45.0)] {
            let written = OverlayRasterizer.composite(
                [sticker("any")], over: frame(width, width), time: 0, artwork: art, cache: cache
            )
            let red = try #require(try rendered(written).region { $0.isRed }).box

            #expect(abs(red.width - side) <= 2 && abs(red.height - side) <= 2,
                    "on a frame \(width) wide the sticker is \(red.size), not \(side)")
            #expect(art.asks.last?.side == Int(side), "the side asked for: \(String(describing: art.asks.last))")
        }
    }

    /// A sticker the artwork cannot draw is left out; the text under it and the
    /// sticker over it are still drawn.
    @Test func missingArtworkSkipsOnlyTheSticker() throws {
        let cache = OverlayRasterCache(budget: 64 << 20)
        let base = frame(400, 400)
        let overlays = [
            FrameOverlay(content: text("HI"), placement: OverlayPlacement(centre: CGPoint(x: 0.5, y: 0.2))),
            sticker("missing"),
            sticker("red", at: CGPoint(x: 0.5, y: 0.8))
        ]
        let bitmap = try rendered(OverlayRasterizer.composite(
            overlays, over: base, time: 0, artwork: Self.redArt, cache: cache
        ))
        let dark = try #require(bitmap.region { $0.r < 160 && $0.g < 160 && $0.b < 160 }, "the text is gone")
        let red = try #require(bitmap.region { $0.isRed }, "the known sticker is gone")

        #expect(dark.centre.y < 120, "the text's box is at the top: \(dark.centre)")
        #expect(bitmap[200, 200].isWhite, "where the missing sticker was, the frame: \(bitmap[200, 200])")
        #expect(abs(red.centre.y - 320) <= 2, "the known sticker is at the bottom: \(red.centre)")

        let noArt = try rendered(OverlayRasterizer.composite(
            overlays, over: base, time: 0, artwork: nil, cache: cache
        ))
        #expect(noArt.region { $0.r < 160 && $0.g < 160 } != nil, "with no artwork at all, the text still is")
        #expect(noArt.region { $0.isRed } == nil, "and no sticker is")
    }

    /// With nothing to draw, the frame comes back as the same object — which is
    /// how the photo bake knows it can hand back the untouched photograph.
    @Test func nothingToDrawReturnsTheSameImage() {
        let base = frame(100, 100)
        let cache = OverlayRasterCache(budget: 64 << 20)
        let nothing: [[FrameOverlay]] = [
            [],
            [FrameOverlay(content: text("  \n "))],
            [sticker("red")],   // and no artwork to draw it
            [FrameOverlay(content: .emoji("🟥"), placement: OverlayPlacement(scale: 0))]
        ]
        for overlays in nothing {
            #expect(OverlayRasterizer.composite(overlays, over: base, time: 0, artwork: nil, cache: cache)
                    === base, "\(overlays) drew something")
        }
    }

    // MARK: - Cache and faces

    /// A text on a video is one picture for every frame: drawn once per size.
    @Test func theCacheRendersOnce() {
        let cache = OverlayRasterCache(budget: 64 << 20)
        let words = FrameOverlay(content: text("Hello"))
        let small = frame(400, 300)
        let large = frame(800, 600)
        func write(_ overlays: [FrameOverlay], on base: CIImage) {
            _ = OverlayRasterizer.composite(overlays, over: base, time: 0, artwork: Self.redArt, cache: cache)
        }

        for _ in 0..<3 { write([words], on: small) }
        #expect(cache.renders == 1, "three frames, one text: \(cache.renders) drawings")

        write([words], on: large)
        write([words], on: small)
        #expect(cache.renders == 2, "a second size is a second drawing, and the first is kept: \(cache.renders)")

        write([FrameOverlay(content: .emoji("🟥")), sticker("red")], on: small)
        write([FrameOverlay(content: .emoji("🟥")), sticker("red")], on: small)
        #expect(cache.renders == 3, "an emoji is kept too, and a sticker's frames are not the cache's")

        let first = OverlayRasterizer.raster(for: words.content, outputWidth: 400, scale: 1, cache: cache)
        let again = OverlayRasterizer.raster(for: words.content, outputWidth: 400, scale: 1, cache: cache)
        #expect(first?.image === again?.image, "the kept picture is handed back")
    }

    /// Past its budget the cache drops what was used longest ago — not what was
    /// stored first.
    @Test func theCacheForgetsTheLeastRecentlyUsedPastItsBudget() {
        let square = Self.square(side: 10, top: Self.red)   // 400 bytes
        let cache = OverlayRasterCache(budget: 1000)
        let raster = OverlayRasterizer.Raster(image: square, density: 1)
        func ask(_ name: String) {
            _ = cache.raster(for: .init(.emoji(name), size: 10)) { raster }
        }

        ask("a"); ask("b")
        #expect(cache.renders == 2 && cache.cost == 800, "guard: two kept, \(cache.cost) bytes")
        ask("a")                   // a is now the fresher
        #expect(cache.renders == 2, "a is kept")
        ask("c")                   // over budget: b goes
        #expect(cache.cost == 800, "the budget holds: \(cache.cost) bytes")
        ask("a")
        #expect(cache.renders == 3, "a, used last, stayed")
        ask("b")
        #expect(cache.renders == 4, "b, used longest ago, was dropped")

        _ = cache.raster(for: .init(.emoji("huge"), size: 99)) {
            OverlayRasterizer.Raster(image: Self.square(side: 40, top: Self.red), density: 1)
        }
        #expect(cache.cost <= 1000, "a picture bigger than the budget is handed out, not kept")
    }

    /// Every typeface resolves to a face of its own on this system — a name
    /// that is not installed would quietly fall back to the classic face.
    @Test func everyOverlayFontResolves() throws {
        var names: [OverlayFont: String] = [:]
        for font in OverlayFont.allCases {
            let face = try #require(OverlayRasterizer.font(for: font, size: 40), "\(font) does not resolve")
            names[font] = face.fontName
        }
        #expect(Set(names.values).count == OverlayFont.allCases.count, "two typefaces share a face: \(names)")

        // And the text is drawn in it.
        var pictures: [OverlayFont: Data] = [:]
        for font in OverlayFont.allCases {
            let raster = try #require(OverlayRasterizer.raster(
                for: .text(TextOverlay(text: "Ag", font: font, background: .none)),
                outputWidth: 400, scale: 1, cache: OverlayRasterCache(budget: 64 << 20)
            ))
            let data = try #require(raster.image.dataProvider?.data) as Data
            pictures[font] = data + Data("\(raster.image.width)x\(raster.image.height)".utf8)
        }
        #expect(Set(pictures.values).count == OverlayFont.allCases.count,
                "two typefaces draw the same picture")
    }
}
