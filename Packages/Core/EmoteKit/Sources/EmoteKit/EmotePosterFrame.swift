import CoreGraphics
import MediaCore

extension AnimatedIconArt {
    /// The frame a STILL emote shows: the first one at least `fullness` as
    /// covered as the fullest frame of the loop.
    ///
    /// Frame 0 is the answer for nearly everything, but not for all: a loop
    /// may open on nothing and pop its subject in. Measured on the bundled
    /// Lottie (`EmotePosterFrameTests`): Noto's 🎂 and ❣️ start blank (frame 0
    /// covers 0% of their fullest) and rest on frames 9 and 18; 😂 and the
    /// LMAO sticker rest on frame 0. A strip resting on frame 0 would show two
    /// empty tiles. Coverage is opacity summed over the frame
    /// (a mark's is its alpha × scale²), so a pop-in reads as empty and a
    /// face that only changes its expression reads as full from frame 0.
    ///
    /// Cheap: the sheet is drawn once into a few pixels a frame.
    func posterFrame(fullness: Double = 0.75) -> Int {
        let coverage = frameCoverage()
        guard let fullest = coverage.max(), fullest > 0 else { return 0 }
        return coverage.firstIndex { $0 >= fullest * fullness } ?? 0
    }

    /// How much of each frame is covered, in arbitrary units.
    func frameCoverage() -> [Double] {
        switch self {
        case .decomposed(let still):
            let track = still.track
            return (0..<track.frameCount).map { index in
                let scale = track.scales.indices.contains(index) ? track.scales[index] : 1
                let alpha = track.alphas.indices.contains(index) ? track.alphas[index] : 1
                return alpha * scale * scale
            }
        case .sheet(let sheet):
            return Self.coverage(of: sheet)
        }
    }

    private static func coverage(of sheet: AnimatedIconSheet) -> [Double] {
        let none = [Double](repeating: 1, count: sheet.frameCount)
        guard let image = sheet.sheet.cgImage, sheet.frameCount > 1 else { return none }
        // A few pixels per cell is plenty to tell a blank from a subject.
        let perCell = 12
        let rows = (sheet.frameCount + sheet.columns - 1) / sheet.columns
        let width = sheet.columns * perCell
        let height = rows * perCell
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return none }
        // Point samples: filtering would bleed a frame into its neighbour's
        // cell and make a blank frame read as faintly covered.
        context.interpolationQuality = CGInterpolationQuality.none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return none }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // A bitmap context's first row is the TOP of what was drawn, and
        // `frameRects` count from the top too.
        return sheet.frameRects.map { rect in
            let x0 = max(0, Int((rect.minX * CGFloat(width)).rounded(.down)))
            let x1 = min(width, Int((rect.maxX * CGFloat(width)).rounded(.up)))
            let y0 = max(0, Int((rect.minY * CGFloat(height)).rounded(.down)))
            let y1 = min(height, Int((rect.maxY * CGFloat(height)).rounded(.up)))
            var sum = 0
            for y in y0..<max(y0, y1) {
                for x in x0..<max(x0, x1) { sum += Int(pixels[(y * width + x) * 4 + 3]) }
            }
            return Double(sum)
        }
    }
}
