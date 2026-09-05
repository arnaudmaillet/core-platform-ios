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

    /// Draws one frame into a cell: inset by the gutter, clipped to the disc,
    /// optionally over a plate.
    static func drawCell(
        _ image: CGImage?, into context: CGContext, at origin: CGPoint,
        cellPixels: Int, plate: CGColor?
    ) {
        let art = CGRect(
            x: origin.x + CGFloat(gutter), y: origin.y + CGFloat(gutter),
            width: CGFloat(cellPixels - gutter * 2), height: CGFloat(cellPixels - gutter * 2)
        )
        context.saveGState()
        context.addEllipse(in: art)
        context.clip()
        if let plate {
            context.setFillColor(plate)
            context.fill(art)
        }
        if let image { context.draw(image, in: art) }
        context.restoreGState()
    }

    static func canvas(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
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
