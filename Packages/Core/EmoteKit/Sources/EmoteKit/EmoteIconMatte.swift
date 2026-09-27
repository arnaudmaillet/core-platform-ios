import CoreGraphics
import MediaCore
import UIKit

/// Lifts a map icon's paper background off, so it sits on text like an emoji.
///
/// ⚠️ **THE MAP'S RASTER SHEETS ARE OPAQUE.** `Tools/IconBaker` baked them from
/// GIFs drawn on white, which is invisible inside a marker's face and a white
/// SQUARE in a line of text over a photograph (measured on the laugh sheet:
/// every frame's background opaque white; filmed in the caption). The matte is
/// a flood fill from each frame's border through near-white pixels: the paper
/// the drawing sits on goes, and white INSIDE an outline (teeth, eyes) stays,
/// because an outline is exactly what stops a fill.
///
/// Runs once per icon, off the main actor; the result is cached like a baked
/// sheet. Decomposed stills are left as they are — they carry real alpha.
enum EmoteIconMatte {
    /// A channel this bright counts as paper.
    static let paperThreshold: UInt8 = 225

    static func matted(_ art: AnimatedIconArt) -> AnimatedIconArt {
        guard case .sheet(let sheet) = art, let image = sheet.sheet.cgImage,
              let matted = matte(image, frameRects: sheet.frameRects)
        else { return art }
        return .sheet(AnimatedIconSheet(
            sheet: UIImage(cgImage: matted, scale: sheet.sheet.scale, orientation: .up),
            frameCount: sheet.frameCount, columns: sheet.columns,
            frameDuration: sheet.frameDuration,
            gutterPX: Int(((sheet.frameRects.first?.minX ?? 0) * CGFloat(image.width)).rounded())
        ))
    }

    /// `image` with the paper around each frame made transparent.
    static func matte(_ image: CGImage, frameRects: [CGRect]) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        func isPaper(_ index: Int) -> Bool {
            let offset = index * 4
            return pixels[offset + 3] > 0
                && pixels[offset] >= paperThreshold
                && pixels[offset + 1] >= paperThreshold
                && pixels[offset + 2] >= paperThreshold
        }

        var visited = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for unit in frameRects {
            // Unit rects are from the TOP; the bitmap's rows are too once
            // drawn (CGContext row 0 is the top of the image in memory).
            let minX = max(0, Int((unit.minX * CGFloat(width)).rounded(.down)))
            let maxX = min(width - 1, Int((unit.maxX * CGFloat(width)).rounded(.up)) - 1)
            let minY = max(0, Int((unit.minY * CGFloat(height)).rounded(.down)))
            let maxY = min(height - 1, Int((unit.maxY * CGFloat(height)).rounded(.up)) - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            for x in minX...maxX {
                stack.append(minY * width + x)
                stack.append(maxY * width + x)
            }
            for y in minY...maxY {
                stack.append(y * width + minX)
                stack.append(y * width + maxX)
            }
            while let index = stack.popLast() {
                guard !visited[index], isPaper(index) else { continue }
                visited[index] = true
                let offset = index * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 0
                let x = index % width, y = index / width
                if x > minX { stack.append(index - 1) }
                if x < maxX { stack.append(index + 1) }
                if y > minY { stack.append(index - width) }
                if y < maxY { stack.append(index + width) }
            }
        }
        return context.makeImage()
    }
}
