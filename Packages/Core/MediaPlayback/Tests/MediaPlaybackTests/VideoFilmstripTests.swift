import AVFoundation
import Foundation
import Testing
import UIKit
@testable import MediaPlayback

@MainActor
struct VideoFilmstripTests {
    private func clip(seconds: Double = 2) async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: seconds)
            .playableURL(for: URL(string: "mock://video/strip-\(seconds)?w=160&h=120")!)
    }

    /// A row of 8 samples across the picture, as bytes — enough to tell two
    /// frames of a clip with a sweeping band apart, and cheap.
    private static func row(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 8 * 4)
        guard let context = CGContext(
            data: &pixels, width: 8, height: 1, bitsPerComponent: 8, bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 1))
        return pixels
    }

    private static func fingerprint(_ image: UIImage) -> String? {
        row(image).map { $0.map(String.init).joined(separator: ",") }
    }

    // MARK: - Asking by time

    @Test func everyMomentAskedForComesBackUnderItsOwnKey() async throws {
        let wanted = [0.2, 0.7, 1.2, 1.7]

        let frames = await VideoFilmstrip().frames(
            of: try await clip(), atSourceSeconds: wanted, height: 40, spacing: 0.5
        )

        #expect(Set(frames.keys) == Set(wanted), "got \(frames.keys.sorted())")
        #expect(frames.values.allSatisfy { $0.size.height > 0 })
    }

    /// ⚠️ **THE TRAP THIS SAMPLER EXISTS TO AVOID, AND THIS REPO HAS PAID FOR IT
    /// TWICE.** `AVAssetImageGenerator` defaults to INFINITE tolerance both ways
    /// and answers every request with the nearest keyframe. `IconBaker`'s
    /// `VideoDocument` records a 24-frame sample coming back as three images
    /// repeated eight times; measured again on a 10-minute clip with a 2s GOP,
    /// 600 requests one second apart returned 300 distinct frames.
    ///
    /// Every structural assertion — the right keys, real `UIImage`s — passes on
    /// a strip of identical pictures. Only reading the pixels can tell a
    /// filmstrip from a wallpaper.
    @Test func theFramesAreDifferentPicturesAndNotOneRepeated() async throws {
        let wanted = [0.2, 0.7, 1.2, 1.7]

        let frames = await VideoFilmstrip().frames(
            of: try await clip(), atSourceSeconds: wanted, height: 40, spacing: 0.5
        )

        let prints = frames.values.compactMap { Self.fingerprint($0) }
        #expect(prints.count == wanted.count, "guard: every frame could be read")
        #expect(Set(prints).count >= 3,
                "only \(Set(prints).count) distinct pictures across \(prints.count) frames")
    }

    /// ⚠️ **KEYED BY THE REQUEST, NOT BY WHERE THE GENERATOR LANDED.** Two
    /// requests can settle on one frame, and keying by `actualTime` would collapse
    /// them into a single entry — a hole in the strip that reads as a decode
    /// failure. Asking for two moments a long way apart and getting two keys back
    /// is the cheap version of that assertion; the picture test above is the
    /// expensive one.
    @Test func twoMomentsAreTwoEntriesEvenWhenTheyShareAKeyframe() async throws {
        let frames = await VideoFilmstrip().frames(
            of: try await clip(), atSourceSeconds: [0.30, 0.34], height: 40, spacing: 0.04
        )

        #expect(frames.count == 2, "got \(frames.keys.sorted())")
    }

    @Test func askingForNothingReturnsNothing() async throws {
        let frames = await VideoFilmstrip().frames(
            of: try await clip(), atSourceSeconds: [], height: 40, spacing: 1
        )
        #expect(frames.isEmpty)
    }

    /// A file with no clip behind it answers empty rather than throwing at a
    /// strip that is only decoration.
    @Test func anUnreadableFileAnswersEmpty() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-clip-\(UUID().uuidString).mp4")
        let frames = await VideoFilmstrip().frames(
            of: missing, atSourceSeconds: [0.1, 0.2], height: 40, spacing: 0.1
        )
        #expect(frames.isEmpty)
    }

    // MARK: - Tolerance (charter T5)

    /// ⚠️ **JUST UNDER HALF THE SPACING, AND BOTH CONSTANTS ARE WRONG.** Measured
    /// on a 10-minute 1080p30 clip with a 2-second GOP: tolerance strictly below
    /// half the sampling interval is fully distinct at ~8.5 ms a frame; tolerance
    /// at or above the interval snaps to keyframes at ~1.5 ms — six times
    /// cheaper, and a strip that repeats itself. Deriving it from the spacing
    /// buys distinctness always and the cheap path automatically, because a
    /// coarse strip's half-spacing window is wide enough to hold a keyframe.
    @Test func theToleranceIsAlwaysUnderHalfTheSpacing() {
        for spacing in [0.04, 0.5, 1.0, 2.0, 30.0] {
            let tolerance = VideoFilmstrip.tolerance(forSpacingSeconds: spacing)
            #expect(tolerance < spacing / 2,
                    "at \(spacing)s spacing a tolerance of \(tolerance)s repeats frames")
            #expect(tolerance > 0, "at \(spacing)s spacing the generator pays full price")
        }
    }

    /// And it GROWS with the spacing — a constant would be either wrong or
    /// needlessly exact at one end of the range.
    @Test func aCoarserStripBuysACheaperTolerance() {
        let tight = VideoFilmstrip.tolerance(forSpacingSeconds: 0.1)
        let loose = VideoFilmstrip.tolerance(forSpacingSeconds: 10)

        #expect(loose > tight * 10, "the tolerance is effectively a constant")
    }

    @Test func aSpacingThatMeansNothingAsksExactly() {
        #expect(VideoFilmstrip.tolerance(forSpacingSeconds: 0) == 0)
        #expect(VideoFilmstrip.tolerance(forSpacingSeconds: -1) == 0)
        #expect(VideoFilmstrip.tolerance(forSpacingSeconds: .nan) == 0)
    }
}
