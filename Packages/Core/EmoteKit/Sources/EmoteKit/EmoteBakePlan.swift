import Foundation

/// How one Lottie becomes one sprite sheet: the cell, the frames, the grid.
///
/// A pure value, so every limit below is testable without drawing anything.
///
/// ## The budget, and why it is a BYTE budget
///
/// A sheet is `pitch² × 4` bytes a frame, resident while any label shows it.
/// At the text-size bucket (64 px) a two-second loop at 30 fps is 60 frames and
/// about 1.1 MB. What must not happen is the tail — Noto's longest loop is
/// 5.75 s, and the 128 px bucket costs four times the 64 px one — so frames are
/// capped by a count AND by bytes, and a capped loop keeps its full duration at
/// a lower rate rather than being cut short.
struct EmoteBakePlan: Equatable, Sendable {
    /// The side the art is drawn at, in pixels.
    let side: Int
    /// The transparent margin around each frame, in pixels, so bilinear
    /// sampling at a frame's edge reads emptiness rather than the neighbour
    /// frame — the same contract as `Tools/IconBaker`'s atlas
    /// (`AnimatedIconSheet.gutterPX`).
    let gutter: Int
    let frameCount: Int
    let columns: Int
    /// Seconds each frame is shown; `frameCount × frameDuration` is the
    /// source's loop.
    let frameDuration: Double

    /// The rate a loop is baked at when nothing caps it. Noto is authored at
    /// 60; text-size emotes read as smooth at 30, for half the memory.
    static let framesPerSecond = 30.0
    /// The most frames any sheet holds.
    static let maxFrames = 90
    /// The most bytes any sheet holds (decoded, 4 bytes a pixel).
    static let maxBytes = 2_500_000
    static let defaultGutter = 2

    var pitch: Int { side + 2 * gutter }
    var rows: Int { (frameCount + columns - 1) / columns }
    var pixelWidth: Int { columns * pitch }
    var pixelHeight: Int { rows * pitch }
    var byteCost: Int { pixelWidth * pixelHeight * 4 }

    /// The plan for a loop of `seconds` drawn at `side` pixels. `still` asks
    /// for the first frame alone (Reduce Motion).
    static func make(seconds: Double, side: Int, still: Bool = false) -> EmoteBakePlan {
        let side = max(1, side)
        let gutter = defaultGutter
        let pitch = side + 2 * gutter
        let wanted: Int
        if still || !(seconds > 0) {
            wanted = 1
        } else {
            // Rounded UP with a hair of slack: a 1.9833 s loop needs its 60th
            // frame, and 2.0 × 30 computed from a frame count may land a hair
            // above 60 and must not become 61 (the same rule as StickerKit's).
            wanted = max(1, Int((seconds * framesPerSecond - 1e-6).rounded(.up)))
        }
        var frames = min(wanted, maxFrames)
        var columns = columnCount(for: frames)
        // The GRID is what costs, empty cells included, so the byte cap is
        // checked on the grid rather than on the frames alone.
        while frames > 1, gridBytes(frames: frames, columns: columns, pitch: pitch) > maxBytes {
            frames -= 1
            columns = columnCount(for: frames)
        }
        let duration = frames > 1 ? seconds / Double(frames) : max(seconds, 0)
        return EmoteBakePlan(side: side, gutter: gutter, frameCount: frames, columns: columns, frameDuration: duration)
    }

    static func columnCount(for frames: Int) -> Int {
        max(1, Int(Double(frames).squareRoot().rounded(.up)))
    }

    static func gridBytes(frames: Int, columns: Int, pitch: Int) -> Int {
        let rows = (frames + columns - 1) / columns
        return columns * rows * pitch * pitch * 4
    }

    /// Where frame `index` is drawn, in pixels from the sheet's TOP-left: row
    /// major from the top, which is what `AnimatedIconSheet.frameRects` reads.
    func origin(ofFrame index: Int) -> (x: Int, y: Int) {
        ((index % columns) * pitch + gutter, (index / columns) * pitch + gutter)
    }

    /// Seconds into the source at which frame `index` is sampled.
    func time(ofFrame index: Int) -> Double {
        Double(index) * frameDuration
    }
}
