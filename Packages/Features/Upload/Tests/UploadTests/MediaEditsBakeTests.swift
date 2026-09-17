import CoreGraphics
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **A PUBLISHED PHOTOGRAPH WEARS ITS TEXT AND ITS STICKERS.**
///
/// `MediaEdits.applied` is the one render a photograph gets before it is
/// uploaded; these read the pixels it hands back, AS DRAWN — through the
/// picture's orientation — at the places the placements name.
struct MediaEditsBakeTests {
    /// Sticker art with one sticker: "stamp", a red square at the side asked
    /// for.
    private final class Stamp: OverlayArtwork {
        func sticker(_ id: String, atSeconds seconds: Double, side: Int) -> CGImage? {
            guard id == "stamp", side > 0,
                  let context = CGContext(
                      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage()
        }
    }

    /// A blue photograph that DISPLAYS 400 by 300 — from a buffer turned a
    /// quarter when `orientation` says so.
    private func bluePhoto(orientation: UIImage.Orientation = .up) -> UIImage {
        let sideways = orientation == .right || orientation == .left
        let buffer = CGSize(width: sideways ? 300 : 400, height: sideways ? 400 : 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let upright = UIGraphicsImageRenderer(size: buffer, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: buffer))
        }
        return UIImage(cgImage: upright.cgImage!, scale: 1, orientation: orientation)
    }

    /// The picture as a viewer sees it, orientation spent: RGBA bytes, row 0 at
    /// the top.
    private struct Drawn {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init(_ image: UIImage) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let flat = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }.cgImage!
            width = flat.width
            height = flat.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let width = width, height = height
            bytes.withUnsafeMutableBytes { raw in
                CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!.draw(flat, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.bytes = bytes
        }

        subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        func isRed(_ x: Int, _ y: Int) -> Bool {
            let p = self[x, y]
            return p.r > 200 && p.g < 60 && p.b < 60
        }

        func isBlue(_ x: Int, _ y: Int) -> Bool {
            let p = self[x, y]
            return p.b > 200 && p.r < 60 && p.g < 60
        }

        /// Pixels of rows `rows` that read the 60% black box over blue.
        func boxed(rows: Range<Int>) -> Int {
            var count = 0
            for y in rows {
                for x in 0..<width {
                    let p = self[x, y]
                    if p.r < 30, p.g < 30, abs(p.b - 102) <= 10 { count += 1 }
                }
            }
            return count
        }
    }

    private static let overlays = [
        FrameOverlay(
            content: .text(TextOverlay(text: "HI", background: .box)),
            placement: OverlayPlacement(centre: CGPoint(x: 0.5, y: 0.2))
        ),
        FrameOverlay(content: .sticker(id: "stamp"), placement: OverlayPlacement(centre: CGPoint(x: 0.5, y: 0.8)))
    ]

    @Test func aPhotoCarriesItsTextAndItsSticker() {
        var edits = MediaEdits()
        edits.overlays = Self.overlays
        let photo = bluePhoto()

        let baked = edits.applied(to: photo, artwork: Stamp())
        let drawn = Drawn(baked)

        #expect(baked.size == photo.size, "the photograph keeps its size: \(baked.size)")
        // The sticker: 18% of 400 = 72 pixels, centred at (200, 240).
        #expect(drawn.isRed(200, 240), "the sticker is at the bottom: \(drawn[200, 240])")
        #expect(drawn.isRed(170, 210) && drawn.isRed(230, 270), "and 72 pixels across")
        #expect(drawn.isBlue(160, 240) && drawn.isBlue(240, 240), "and no more")
        // The text: a box behind "HI", centred at (200, 60).
        #expect(drawn.boxed(rows: 40..<80) >= 30, "the text's box is at the top")
        #expect(drawn.boxed(rows: 100..<300) == 0, "and nowhere else")
        #expect(drawn.isBlue(20, 150) && drawn.isBlue(200, 150), "the rest is the photograph")

        // The editor's own render leaves them out: its canvas shows overlays as
        // views.
        let canvas = Drawn(edits.applied(to: photo, artwork: Stamp(), includingOverlays: false))
        #expect(canvas.isBlue(200, 240), "the canvas's picture carries no sticker: \(canvas[200, 240])")
        #expect(canvas.boxed(rows: 40..<80) == 0, "and no text")
    }

    /// ⚠️ **A SIDEWAYS PHOTOGRAPH IS WRITTEN ON AS THE AUTHOR SAW IT.** The
    /// placements are fractions of the picture as drawn; `CIImage(image:)`
    /// reads the raw buffer, which for a `.right` photograph is turned a
    /// quarter. Written on unturned, the sticker "at the top" would land on the
    /// buffer's top — the drawn picture's RIGHT side.
    @Test func aSidewaysPhotoCarriesItsStickerWhereItWasPut() {
        var edits = MediaEdits()
        edits.overlays = [
            FrameOverlay(content: .sticker(id: "stamp"), placement: OverlayPlacement(centre: CGPoint(x: 0.25, y: 0.2)))
        ]
        let photo = bluePhoto(orientation: .right)
        let drawn = Drawn(edits.applied(to: photo, artwork: Stamp()))

        #expect(photo.size == CGSize(width: 400, height: 300), "guard: the photograph displays wide")
        #expect(drawn.width == 400 && drawn.height == 300, "the bake displays wide too")
        #expect(drawn.isRed(100, 60), "the sticker is top-left as placed: \(drawn[100, 60])")
        #expect(drawn.isBlue(300, 240) && drawn.isBlue(300, 60) && drawn.isBlue(100, 240),
                "and nowhere else")
    }
}
