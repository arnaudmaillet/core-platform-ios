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

    // MARK: - More than one piece, and rates other than as-shot

    /// ⚠️ **ASSERTED ON THE DURATION OF WHAT COMES OUT, BECAUSE THE FAILURE MODE
    /// IS SILENCE.** A segment list that is ignored, or that collapses to the
    /// first piece, produces a perfectly good file — it is simply the wrong film,
    /// and nothing errors. Two pieces of one second each must give two seconds.
    @Test func twoPiecesExportAsTheirSum() async throws {
        let source = try await longerClip()

        let exported = try await VideoExporter().export(VideoExportPlan(
            sourceURL: source,
            segments: [
                VideoExportSegment(start: 0.1, end: 0.7),
                VideoExportSegment(start: 1.6, end: 2.2)
            ]
        ))

        #expect(abs(exported.durationSeconds - 1.2) < 0.25,
                "got \(exported.durationSeconds)s for two six-tenths pieces")
    }

    /// The witness for the one above: the SAME two moments as a single span would
    /// be nearly three seconds. Without it, "two seconds" could be a coincidence
    /// of an exporter that ignored the list and trimmed once.
    @Test func thePiecesAreJoined_notSpanned() async throws {
        let source = try await longerClip()

        let spanned = try await VideoExporter().export(VideoExportPlan(
            sourceURL: source, segments: [VideoExportSegment(start: 0.1, end: 2.2)]
        ))

        #expect(spanned.durationSeconds > 1.8,
                "guard: the span really is longer than the two pieces: \(spanned.durationSeconds)")
    }

    /// ⚠️ **A RATE IS A CUT TOO.** The same frames, end to end, are a different
    /// video once they play at a different speed — and a `timeRange` cannot say
    /// it, which is the whole reason the composition route exists.
    @Test func aFasterPieceExportsShorter() async throws {
        let source = try await longerClip()

        let asShot = try await VideoExporter().export(VideoExportPlan(
            sourceURL: source, segments: [VideoExportSegment(start: 0, end: 2)]
        ))
        let doubled = try await VideoExporter().export(VideoExportPlan(
            sourceURL: source, segments: [VideoExportSegment(start: 0, end: 2, speed: 2)]
        ))
        #expect(asShot.durationSeconds > 1.7, "guard: the 1x export is a real two seconds")

        #expect(abs(doubled.durationSeconds - asShot.durationSeconds / 2) < 0.3,
                "\(asShot.durationSeconds)s at 1x became \(doubled.durationSeconds)s at 2x")
    }

    @Test func aSlowerPieceExportsLonger() async throws {
        let source = try await longerClip()

        let halved = try await VideoExporter().export(VideoExportPlan(
            sourceURL: source, segments: [VideoExportSegment(start: 0, end: 1, speed: 0.5)]
        ))

        #expect(halved.durationSeconds > 1.6, "got \(halved.durationSeconds)s for 1s at 0.5x")
    }

    /// ⚠️ **ONE PIECE AT 1x MUST NOT BUILD A COMPOSITION** — it is the trim every
    /// clip takes, and a composition there is a second reader and a second set of
    /// tracks for an identical result. Asserted through the only thing visible
    /// from outside: it still produces the same film as the `timeRange` spelling.
    @Test func onePieceAtOneRateMatchesTheRangeSpelling() async throws {
        let source = try await longerClip()

        let asSegment = try await VideoExporter().export(VideoExportPlan(
            sourceURL: source, segments: [VideoExportSegment(start: 0.5, end: 1.5)]
        ))
        let asRange = try await VideoExporter()
            .export(VideoExportPlan(sourceURL: source, timeRange: 0.5...1.5))

        #expect(abs(asSegment.durationSeconds - asRange.durationSeconds) < 0.2,
                "\(asSegment.durationSeconds) against \(asRange.durationSeconds)")
    }
}
