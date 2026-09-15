import AVFoundation
import Foundation
import Testing
import UIKit
@testable import MediaPlayback

struct VideoExporterTests {
    /// A real source clip to export: synthesize one with the placeholder fetcher.
    private func sourceClip() async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: 1.0)
            .playableURL(for: URL(string: "mock://video/exp?w=240&h=320")!)
    }

    /// ⚠️ **A POSTER TAKEN AT EXACTLY ZERO IS BLACK FOR A GREAT DEAL OF REAL
    /// FILM.** This method asked for `CMTime(seconds: 0)` while its own doc
    /// called the result "the first ~clean frame". Content that fades in — which
    /// is most of it — hands back a black rectangle, and that rectangle becomes
    /// the post's `thumbnail_url`, where it is indistinguishable from the
    /// missing-thumbnail bug the poster exists to prevent.
    ///
    /// Found by putting real encodes behind the device-media mock: Big Buck
    /// Bunny's tile drew its forest and the Sintel trailer's drew pure black,
    /// both files being perfectly fine.
    ///
    /// Asked offline, against the synthesised clip's sweeping band: the frame a
    /// tenth of the way in is a DIFFERENT picture from the frame at zero, so if
    /// the poster still equalled frame zero this could not pass. The tolerance
    /// matters as much as the offset — infinite in both directions lets the
    /// generator answer with the nearest keyframe, which on a short clip is
    /// frame zero again.
    @Test func thePosterIsNotTheVeryFirstFrame() async throws {
        let source = try await sourceClip()

        let poster = try #require(await VideoExporter().posterImage(for: source))

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let zero = UIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))

        #expect(Self.thumbBytes(poster) != Self.thumbBytes(zero),
                "the poster is still the frame at t=0")
        // And it is a picture, not an absence — the same reading that caught the
        // all-black fixture.
        let ink = try #require(Self.thumbBytes(poster))
        #expect(ink.reduce(0) { $0 + Int($1) } > 90, "the poster is black")
    }

    /// A 1x1 rendering of an image, as raw RGBA — small enough to compare two
    /// frames by value without caring about size or scale.
    private static func thumbBytes(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(pixel[0..<3])
    }

    @Test func exportProducesAPlayableMp4WithMetadata() async throws {
        let source = try await sourceClip()
        let exported = try await VideoExporter().export(source)

        #expect(FileManager.default.fileExists(atPath: exported.fileURL.path))
        #expect(exported.mimeType == "video/mp4")
        #expect(exported.byteSize > 0)
        #expect(exported.durationSeconds > 0)
        #expect(exported.pixelWidth > 0 && exported.pixelHeight > 0)
        #expect(exported.sha256Hex.count == 64)

        // The export is itself a valid, playable asset.
        let tracks = try await AVURLAsset(url: exported.fileURL).loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty)
    }

    @Test func posterImageIsGenerated() async throws {
        let source = try await sourceClip()
        let poster = await VideoExporter().posterImage(for: source)
        #expect(poster != nil)
        #expect((poster?.size.width ?? 0) > 0)
    }

    @Test func placeholderFetcherPassesThroughLocalFileURLs() async throws {
        // A local clip must play as-is (optimistic compose insert), not be synthesized over.
        let localClip = try await sourceClip()
        let resolved = try await PlaceholderVideoFetcher().playableURL(for: localClip)
        #expect(resolved == localClip)
    }
}
