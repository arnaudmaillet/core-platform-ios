import CoreGraphics
import Foundation
import ImageIO
import MediaPlayback
import Synchronization
import UniformTypeIdentifiers

/// One sticker's baked loop: square PNG frames at a fixed rate, readable from
/// any thread.
///
/// ⚠️ **ONE DECODED FRAME AT A TIME.** The strip keeps its frames compressed
/// and decodes the one asked for, holding only the last decoded picture. A
/// compositor asks for the same frame for two or three output frames in a row
/// (a 30fps loop under a 60fps film), which the one-frame cache answers without
/// decoding again — and a strip never holds more than one bitmap.
public final class StickerStrip: Sendable {
    public let stickerID: String
    /// Pixels on each side of every frame.
    public let side: Int
    public let framesPerSecond: Int
    /// Seconds in one pass of the loop; 0 for a still.
    public let seconds: Double
    /// PNG bytes, in time order.
    public let frames: [Data]

    private struct Decoded {
        let index: Int
        let side: Int
        let image: CGImage
    }

    private let decoded = Mutex<Decoded?>(nil)
    private let decodeCount = Mutex(0)

    init(stickerID: String, side: Int, framesPerSecond: Int, seconds: Double, frames: [Data]) {
        self.stickerID = stickerID
        self.side = side
        self.framesPerSecond = framesPerSecond
        self.seconds = seconds
        self.frames = frames
    }

    /// Compressed bytes held, across every frame.
    public var byteCount: Int {
        frames.reduce(0) { $0 + $1.count }
    }

    /// The frame shown `seconds` into the film. The loop repeats for ever, both
    /// ways: any time maps into one pass.
    public func frameIndex(atSeconds seconds: Double) -> Int {
        guard frames.count > 1, self.seconds > 0, seconds.isFinite else { return 0 }
        var into = seconds.truncatingRemainder(dividingBy: self.seconds)
        if into < 0 { into += self.seconds }
        return min(frames.count - 1, Int(into * Double(framesPerSecond)))
    }

    /// The frame shown `seconds` into the film, `side` pixels square (the baked
    /// side when nil). Nil only when the bytes cannot be decoded.
    ///
    /// ⚠️ **ANOTHER SIDE IS A RESAMPLE, NOT A NEW BAKE.** A renderer sizes each
    /// sticker by its placement, so the side it asks for is rarely the baked
    /// one; the picture is scaled here so `OverlayArtwork`'s "`side` pixels
    /// square" holds. Bake at the side the render will mostly want.
    public func frame(atSeconds seconds: Double, side: Int? = nil) -> CGImage? {
        let index = frameIndex(atSeconds: seconds)
        let side = max(1, side ?? self.side)
        return decoded.withLock { cached in
            if let cached, cached.index == index, cached.side == side { return cached.image }
            guard let image = decode(index, side: side) else { return nil }
            cached = Decoded(index: index, side: side, image: image)
            return image
        }
    }

    /// How many frames have been decoded so far — the one-frame cache's test
    /// reads it.
    var decodes: Int {
        decodeCount.withLock { $0 }
    }

    private func decode(_ index: Int, side: Int) -> CGImage? {
        decodeCount.withLock { $0 += 1 }
        guard frames.indices.contains(index),
              let source = CGImageSourceCreateWithData(frames[index] as CFData, nil),
              // Decoded NOW, not on first draw: the caller is a render that
              // wants a bitmap, and the cache is what makes this once per frame.
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        guard side != image.width || side != image.height else { return image }
        return Self.resampled(image, side: side)
    }

    private static func resampled(_ image: CGImage, side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// `image` as PNG bytes. Runs on any thread.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Baked stickers, as the `OverlayArtwork` a render reads: the export, the
/// photo bake and anything else that draws `FrameOverlay.Content.sticker`.
///
/// Built by `StickerFrameBaker.artwork(for:side:motion:)` on the main actor,
/// then read from any thread.
public struct StickerArtwork: OverlayArtwork {
    /// Strips by sticker identifier.
    public let strips: [String: StickerStrip]

    public init(strips: [String: StickerStrip]) {
        self.strips = strips
    }

    public func sticker(_ id: String, atSeconds seconds: Double, side: Int) -> CGImage? {
        strips[id]?.frame(atSeconds: seconds, side: side)
    }
}
