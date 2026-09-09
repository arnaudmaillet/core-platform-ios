import Testing
import UIKit
@testable import MediaCore

/// What a sheet's client is allowed to sample.
///
/// ⚠️ THE GUTTER IS INSIDE THE CELL, AND IT IS TRANSPARENT. `AtlasWriter` insets
/// every cell by a 2px margin so bilinear filtering at a cell's edge samples
/// emptiness rather than the neighbouring frame. Sampling the WHOLE cell carries
/// that margin into the picture and the host's background shows through it —
/// 0.65pt on a 56pt marker, invisible, and a 10pt BAND once the same image is
/// aspect-filled into a full-screen hero card. It was filmed as a white bar
/// across the top of the flying card, and reported as a sprite-sheet defect.
///
/// The arithmetic that turns one into the other: 2px of a 172px cell is 1.163%;
/// a square cell aspect-filled into a 402x874 card is scaled 874/172 = 5.08x,
/// so 2px becomes 10.2pt at the top and bottom (the sides are cropped away by
/// the fill).
struct AnimatedIconSheetGutterTests {
    /// A 4x2 sheet of 172px cells, matching the shipped map previews.
    private func sheet(frameCount: Int = 8, columns: Int = 4, cell: Int = 172) -> UIImage {
        let rows = Int(ceil(Double(frameCount) / Double(columns)))
        let size = CGSize(width: cell * columns, height: cell * rows)
        return UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("A sheet that declares no gutter samples the whole cell, exactly as before")
    func noGutterIsTheOldGeometry() {
        let art = AnimatedIconSheet(sheet: sheet(), frameCount: 8, columns: 4, frameDuration: 0.1)

        #expect(art.frameRects[0] == CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
        #expect(art.frameRects[5] == CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.5))
    }

    @Test("A declared gutter is sampled OUT, on every side of every cell")
    func theGutterIsInsetAway() {
        let art = AnimatedIconSheet(
            sheet: sheet(), frameCount: 8, columns: 4, frameDuration: 0.1, gutterPX: 2
        )
        // 2px of a 688px-wide, 344px-tall sheet.
        let insetX = 2.0 / 688, insetY = 2.0 / 344

        let first = art.frameRects[0]
        #expect(abs(first.minX - insetX) < 1e-9)
        #expect(abs(first.minY - insetY) < 1e-9)
        #expect(abs(first.width - (0.25 - insetX * 2)) < 1e-9)
        #expect(abs(first.height - (0.5 - insetY * 2)) < 1e-9)

        // And the LAST cell, so the inset is not merely subtracted from the
        // origin of the first: every cell is narrowed on both sides.
        let last = art.frameRects[7]
        #expect(abs(last.maxX - (1 - insetX)) < 1e-9)
        #expect(abs(last.maxY - (1 - insetY)) < 1e-9)
    }

    /// ⚠️ Sampling INSIDE the margin is what keeps the margin doing its job: the
    /// filter at the sampled edge reaches into transparency rather than into the
    /// next frame. A rect that grew instead of shrinking would reintroduce the
    /// bleed the gutter exists to prevent.
    @Test("The inset shrinks the sampled rect; it never grows it")
    func theInsetOnlyEverShrinks() {
        let plain = AnimatedIconSheet(sheet: sheet(), frameCount: 8, columns: 4, frameDuration: 0.1)
        let inset = AnimatedIconSheet(
            sheet: sheet(), frameCount: 8, columns: 4, frameDuration: 0.1, gutterPX: 2
        )
        for (a, b) in zip(plain.frameRects, inset.frameRects) {
            #expect(a.contains(b))
            #expect(b.width < a.width)
            #expect(b.height < a.height)
        }
    }
}
