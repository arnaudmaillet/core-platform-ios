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

    /// A longer source, so a trim has somewhere to cut.
    private func longerClip() async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: 2.5)
            .playableURL(for: URL(string: "mock://video/trim?w=160&h=120")!)
    }

    // MARK: - Trim

    /// ⚠️ **THE WHOLE FAILURE MODE IS THAT A TRIM LOOKS LIKE IT WORKED.** An
    /// ignored `timeRange` exports a perfectly good file at the full length: it
    /// plays, it uploads, it publishes. Only the DURATION says the cut never
    /// happened, which is why every assertion here is about seconds.
    @Test func aTrimmedExportIsOnlyTheKeptPart() async throws {
        let exported = try await VideoExporter()
            .export(VideoExportPlan(sourceURL: try await longerClip(), timeRange: 0.5...1.5))

        #expect(abs(exported.durationSeconds - 1) < 0.05,
                "expected about a second, got \(exported.durationSeconds)")
    }

    /// ⚠️ **BOTH EDGES, EXPLICITLY.** A range that starts at zero and one that
    /// runs to the exact duration are the two an off-by-one hides in: the first
    /// looks like "no trim" and the second like "past the end", and either can
    /// be silently widened back to the whole clip without anything erroring.
    @Test func aTrimFromTheVeryStartStillCuts() async throws {
        let exported = try await VideoExporter()
            .export(VideoExportPlan(sourceURL: try await longerClip(), timeRange: 0...1))

        #expect(abs(exported.durationSeconds - 1) < 0.05,
                "expected about a second, got \(exported.durationSeconds)")
    }

    @Test func aTrimRunningToTheVeryEndStillCuts() async throws {
        let source = try await longerClip()
        let whole = try await AVURLAsset(url: source).load(.duration).seconds

        let exported = try await VideoExporter()
            .export(VideoExportPlan(sourceURL: source, timeRange: (whole - 1)...whole))

        #expect(abs(exported.durationSeconds - 1) < 0.05,
                "expected about a second, got \(exported.durationSeconds)")
    }

    /// The witness for all three: with no range the clip comes back whole, so
    /// "about a second" above is the trim and not the exporter shortening
    /// everything it touches.
    @Test func anUntrimmedExportIsStillTheWholeClip() async throws {
        let source = try await longerClip()
        let whole = try await AVURLAsset(url: source).load(.duration).seconds

        let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: source))

        #expect(abs(exported.durationSeconds - whole) < 0.05,
                "expected \(whole), got \(exported.durationSeconds)")
    }

    /// A trim shortens the clip; it does not shrink its pictures. The dimensions
    /// are read from the SOURCE track for that reason.
    @Test func aTrimLeavesThePicturesTheSizeTheyWere() async throws {
        let source = try await longerClip()
        let whole = try await VideoExporter().export(VideoExportPlan(sourceURL: source))
        let cut = try await VideoExporter()
            .export(VideoExportPlan(sourceURL: source, timeRange: 0.5...1.5))

        #expect(cut.pixelWidth == whole.pixelWidth)
        #expect(cut.pixelHeight == whole.pixelHeight)
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
