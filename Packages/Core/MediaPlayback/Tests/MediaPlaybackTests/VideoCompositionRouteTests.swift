import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import MediaPlayback

/// **THE SDK FORK THE VIDEO EDITOR HAS TO BE BUILT AROUND, MEASURED RATHER THAN
/// READ.**
///
/// Cropping a clip and putting a look on it sound like one feature. In
/// AVFoundation they are two different constructors, and on iOS 26 neither does
/// both:
///
/// - `AVVideoComposition(applyingFiltersTo:applier:)` runs Core Image, and its
///   header says the returned composition's "properties are private and support
///   only CIFilter-based operations… If rotations or other transformations are
///   desired, they must be accomplished via the application of CIFilters", with
///   a `renderSize` derived from the source track.
/// - `AVVideoComposition.Configuration` exposes `renderSize`, `instructions` and
///   `customVideoCompositorClass` — and **no** Core Image slot.
///
/// ⚠️ **THESE TESTS ASSERT APPLE'S BEHAVIOUR, NOT OURS, AND THAT IS THE POINT.**
/// The whole shape of crop-plus-filter for video rests on the fork; if a future
/// SDK closes it, this suite is what says so, and the answer would be "the
/// design can be simplified" rather than a silent lost opportunity. They are
/// cheap — half a second of synthesised clip each.
///
/// Recorded in `dev/IOS_VIDEO_CAPTURE_UPLOAD.md` §5 P4.
@Suite(.exclusiveMediaWork)
struct VideoCompositionRouteTests {
    private func clip(width: Int, height: Int) async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: 0.5)
            .playableURL(for: URL(string: "mock://video/route-\(width)x\(height)?w=\(width)&h=\(height)")!)
    }

    private func exportedSize(
        of source: URL, composition: AVVideoComposition?, preset: String
    ) async throws -> CGSize {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-\(UUID().uuidString).mp4")
        let session = try #require(
            AVAssetExportSession(asset: AVURLAsset(url: source), presetName: preset)
        )
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = composition
        await session.export()
        #expect(session.status == .completed, "export failed: \(String(describing: session.error))")
        let track = try #require(
            try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
        )
        let natural = try await track.load(.naturalSize)
        let corrected = natural.applying(try await track.load(.preferredTransform))
        return CGSize(width: abs(corrected.width), height: abs(corrected.height))
    }

    /// ⚠️ **A CI APPLIER CANNOT CROP — IT CAN ONLY LETTERBOX.** Returning a
    /// square image from a 4:3 source does not produce a square video: the
    /// export stays 160x120 and the square is placed inside it. So "cut the clip
    /// to this rectangle" is not expressible through the filter route at all,
    /// and a design that assumed otherwise would publish a clip with bars baked
    /// into the pixels.
    @Test func theFilterRouteCannotChangeTheOutputRatio() async throws {
        let source = try await clip(width: 160, height: 120)

        let filtered = try await AVVideoComposition(applyingFiltersTo: AVURLAsset(url: source)) {
            parameters in
            AVCIImageFilteringResult(
                resultImage: parameters.sourceImage.cropped(
                    to: CGRect(x: 0, y: 0, width: 120, height: 120)
                )
            )
        }

        #expect(filtered.renderSize == CGSize(width: 160, height: 120),
                "the render size is the source's, not the applier's: \(filtered.renderSize)")

        let exported = try await exportedSize(
            of: source, composition: filtered, preset: AVAssetExportPresetHighestQuality
        )
        #expect(exported == CGSize(width: 160, height: 120),
                "a square applier result still exported \(exported)")
    }

    /// The other arm of the fork, and the witness for the line above: a size
    /// change IS expressible — just not on the constructor that runs filters.
    @Test func theConfigurationRouteSetsAnArbitraryRenderSize() {
        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = CGSize(width: 120, height: 120)
        configuration.frameDuration = CMTime(value: 1, timescale: 30)

        let composition = AVVideoComposition(configuration: configuration)

        #expect(composition.renderSize == CGSize(width: 120, height: 120))
    }
}
