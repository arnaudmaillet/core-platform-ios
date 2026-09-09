import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Assembles cells into the exact asset `BACKEND_ANIMATED_PIN_ICONS.md` asks
/// for, so this tool is the reference implementation of that section rather than
/// an approximation of it.
///
/// Every invariant here is load-bearing and each one is in the document with its
/// reason: the 2px gutter (bilinear bleed between neighbouring cells when the
/// sheet is minified for a chat emote), the pre-baked circular alpha (a mask on
/// an animating layer costs an offscreen pass per marker per frame), row-major
/// order, and the frame cap.
enum AtlasWriter {

    static let gutter = 2

    /// Where cell `frame` goes in the canvas, ROW-MAJOR FROM THE TOP.
    ///
    /// ⚠️ A bare `CGContext` has its origin at the BOTTOM left, and the client
    /// indexes `contentsRect` from the TOP. Placing cell k at `y = row * cell`
    /// therefore writes the grid upside down: the client plays the last row
    /// first, then the second-to-last, and so on. Within a row the order is
    /// right, which is what makes it survive a glance at the sheet.
    ///
    /// It is worst on the row that is only partly used. A 5-frame GIF is a
    /// 4x2 grid whose second row holds one cell and three transparent ones —
    /// and that row is the one the client reads FIRST, so every loop opens with
    /// three blank frames. Reported as "the GIFs blink intermittently", which is
    /// exactly what it is.
    ///
    /// The bench's own baker never had this because it draws through
    /// `UIGraphicsImageRenderer`, which is already top-left. Two bakers, two
    /// coordinate conventions, one grid format between them.
    static func origin(frame: Int, columns: Int, rows: Int, cellPixels: Int) -> CGPoint {
        CGPoint(
            x: CGFloat((frame % columns) * cellPixels),
            y: CGFloat((rows - 1 - frame / columns) * cellPixels)
        )
    }

    /// Draws one frame into a cell: inset by the gutter, clipped to the disc,
    /// optionally over a plate.
    /// The silhouette a cell is clipped to.
    enum Shape {
        /// A disc — for a marker that reads as a rounded avatar.
        case disc
        /// The full square, artwork alpha only.
        ///
        /// This is what the map's animated pin icons use: the product asks for
        /// the artwork to own the whole box with no visible circle, unlike the
        /// avatar it replaces. Clipping to a disc here would cut the corners off
        /// artwork designed to fill them — and the client draws no ground
        /// behind it, so there would be nothing where the corners had been.
        case square
    }

    static func drawCell(
        _ image: CGImage?, into context: CGContext, at origin: CGPoint,
        cellPixels: Int, plate: CGColor?, shape: Shape = .disc
    ) {
        let art = CGRect(
            x: origin.x + CGFloat(gutter), y: origin.y + CGFloat(gutter),
            width: CGFloat(cellPixels - gutter * 2), height: CGFloat(cellPixels - gutter * 2)
        )
        context.saveGState()
        if shape == .disc {
            context.addEllipse(in: art)
        } else {
            context.addRect(art)
        }
        context.clip()
        if let plate {
            context.setFillColor(plate)
            context.fill(art)
        }
        if let image { context.draw(image, in: aspectFill(image, in: art)) }
        context.restoreGState()
    }

    /// The rect that makes `image` COVER `cell` at its own aspect, centred.
    ///
    /// ⚠️ `CGContext.draw(_:in:)` STRETCHES an image to the rect it is given. It
    /// has no content mode, and the caller above hands it a square — so every
    /// frame of a 16:9 clip was squeezed to 1:1 and baked anamorphic: 1.78x too
    /// narrow, permanently, in the asset. On screen that is a marker whose
    /// picture does not match the video it previews, which is exactly how it was
    /// reported. The cell is already clipped, so covering crops rather than
    /// bleeds — the same aspect-fill the marker and the page both draw media
    /// with, which is the point: the preview must be a crop of the SAME picture.
    ///
    /// A no-op for square artwork, so every Lottie icon bakes byte-identically.
    static func aspectFill(_ image: CGImage, in cell: CGRect) -> CGRect {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return cell }
        let scale = max(cell.width / width, cell.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: cell.midX - size.width / 2, y: cell.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    static func canvas(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    /// Is every cell the client will read actually populated?
    ///
    /// This exists because the row-flip above shipped, was seen, and was
    /// reported as "the GIFs blink intermittently" — a rendering complaint for
    /// a grid-layout bug. Nothing in the pipeline could have caught it: the
    /// sheet looked plausible, the frame count was right, the memory was right,
    /// and the only wrong thing was which cell held which frame.
    ///
    /// A fully transparent cell inside `frameCount` is never legitimate. Cells
    /// PAST `frameCount` are expected to be empty and are not checked.
    static func emptyCells(
        in sheet: CGImage, frameCount: Int, columns: Int, cellPixels: Int
    ) -> [Int] {
        let width = sheet.width, height = sheet.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            context.draw(sheet, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Read from the TOP, exactly as `contentsRect` does — checking in the
        // baker's own coordinate space would agree with the bug.
        return (0..<frameCount).filter { frame in
            let cx = (frame % columns) * cellPixels
            let cy = (frame / columns) * cellPixels
            for y in (cy + cellPixels / 3)..<(cy + cellPixels * 2 / 3) {
                for x in (cx + cellPixels / 3)..<(cx + cellPixels * 2 / 3) {
                    let p = (y * width + x) * 4
                    if p + 3 < pixels.count, pixels[p + 3] > 8 { return false }
                }
            }
            return true
        }
    }

    /// HEIC by default: measured at 30 frames it is 118 KB against PNG's 260 KB
    /// with alpha preserved, and HEVC decode is hardware on every target device.
    static func write(_ image: CGImage, to url: URL, heic: Bool) throws {
        let type = (heic ? UTType.heic : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type, 1, nil
        ) else { throw BakeError("cannot encode \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw BakeError("cannot finalise \(url.lastPathComponent)")
        }
    }

    /// The contract's frame-step ladder: {33, 50, 66, 83, 100} ms.
    ///
    /// 24 fps is deliberately absent — it is not a divisor of 60, so it judders
    /// 3:2 on a non-ProMotion panel. Snapping to the ladder rather than honouring
    /// the source exactly is what keeps every icon in the catalog on ONE clock,
    /// which is the entire basis of the quantised-tick argument.
    static let ladderMS = [33, 50, 66, 83, 100]

    static func snapToLadder(_ milliseconds: Double) -> Int {
        ladderMS.min(by: { abs(Double($0) - milliseconds) < abs(Double($1) - milliseconds) })!
    }
}
