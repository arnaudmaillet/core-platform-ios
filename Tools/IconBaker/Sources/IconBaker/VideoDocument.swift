import AVFoundation
import CoreGraphics
import Foundation

/// A video clip, sampled into frames — the publish-time half of a marker's
/// moving preview.
///
/// This is the rendition the backend would produce: not an MP4 the client plays
/// with a decoder, but a GRID of frames the client scrubs with a keyframe
/// animation. The difference is the whole point of the option — a sheet costs
/// **no decode session at all**, so the number of markers moving at once stops
/// being bounded by the device's media hardware and starts being bounded by
/// memory, which is a budget a product can choose.
///
/// Measured against the alternatives for the same 2 s / 132px clip: MP4 19.3 KB,
/// sheet 167 KB, GIF 226 KB — so a sheet is ~8.7x the video on the wire and a
/// GIF is ~11.7x, and only the sheet avoids both a decode session and a
/// 256-colour palette.
struct VideoDocument {

    let name: String
    let asset: AVURLAsset
    let duration: Double
    let naturalSize: CGSize

    static func load(_ url: URL) async throws -> VideoDocument {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw BakeError("\(url.lastPathComponent): no duration")
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BakeError("\(url.lastPathComponent): no video track")
        }
        let size = try await track.load(.naturalSize)
        return VideoDocument(
            name: url.deletingPathExtension().lastPathComponent,
            asset: asset, duration: duration, naturalSize: size
        )
    }

    /// `count` frames evenly spaced over `window` seconds from `start`.
    ///
    /// ⚠️ Tolerance is ZERO on both sides. `AVAssetImageGenerator` defaults to
    /// a tolerance of positive/negative infinity, which lets it return the
    /// nearest KEYFRAME instead of the frame asked for — on a clip with a two
    /// second GOP that collapses a 24-frame sample into three distinct images
    /// repeated eight times each, and the sheet looks like a stutter rather than
    /// a preview. Nothing errors; the frame count is right.
    func frames(count: Int, start: Double, window: Double, side: Int) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Ask for a square a little larger than the cell: the generator scales
        // to FIT, and the caller crops to fill.
        generator.maximumSize = CGSize(width: side * 2, height: side * 2)

        let span = min(window, max(0.1, duration - start))
        var images: [CGImage] = []
        images.reserveCapacity(count)
        for index in 0..<count {
            let seconds = start + span * Double(index) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            images.append(image)
        }
        return images
    }
}
