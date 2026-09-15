import AVFoundation
import Foundation
import Testing
import UIKit
@testable import MediaPlayback

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

    @Test func itReturnsAsManyFramesAsAskedFor() async throws {
        let frames = await VideoFilmstrip().frames(of: try await clip(), count: 6, height: 40)
        #expect(frames.count == 6, "got \(frames.count)")
        #expect(frames.allSatisfy { $0.size.height > 0 })
    }

    /// ⚠️ **THE TRAP THIS SAMPLER EXISTS TO AVOID, AND THIS REPO HAS PAID FOR IT
    /// ONCE ALREADY.** `AVAssetImageGenerator` defaults to INFINITE tolerance in
    /// both directions and will happily answer every request with the nearest
    /// keyframe. `IconBaker`'s `VideoDocument` records the result: a 24-frame
    /// sample came back as **three images repeated eight times**, nothing
    /// erroring, nothing looking wrong until someone counted.
    ///
    /// Every structural assertion — the right count, the right size, real
    /// `UIImage`s — passes on a strip of eight identical pictures. Only reading
    /// the pixels can tell a filmstrip from a wallpaper.
    @Test func theFramesAreDifferentPicturesAndNotOneRepeated() async throws {
        let frames = await VideoFilmstrip().frames(of: try await clip(), count: 6, height: 40)
        #expect(frames.count == 6, "guard: the strip was built")

        let rows = frames.compactMap { Self.row($0) }
        #expect(rows.count == frames.count, "guard: every frame could be read")

        let distinct = Set(rows.map { $0.map(String.init).joined(separator: ",") })
        #expect(distinct.count >= 4,
                "only \(distinct.count) distinct pictures across \(frames.count) frames")
    }

    /// Ordered by time, not by whatever order the generator finished in. A
    /// shuffled filmstrip is a lie about the clip, and the generator makes no
    /// promise about delivery order.
    ///
    /// The band sweeps left to right, so the picture's brightest column marches
    /// across the strip; a shuffle would break the march.
    @Test func theFramesComeBackInClipOrder() async throws {
        let frames = await VideoFilmstrip().frames(of: try await clip(), count: 5, height: 40)
        let brightest = frames.compactMap { Self.brightestColumn(of: $0) }
        #expect(brightest.count == frames.count, "guard: every frame was read")
        #expect(brightest == brightest.sorted(),
                "the bright band does not march in order: \(brightest)")
    }

    /// Which of the eight samples is the lightest — the sweeping band's place.
    ///
    /// ⚠️ SPELLED OUT RATHER THAN CHAINED. This was one `compactMap` holding a
    /// `stride().map` and a `firstIndex(of:)`, and the compiler gave up type
    /// checking it — the error names a time limit, not a mistake, and the fix is
    /// always to give the pieces names. `DebugMediaLibrary`'s init carries the
    /// same note for the same reason.
    private static func brightestColumn(of image: UIImage) -> Int? {
        guard let row = Self.row(image) else { return nil }
        var sums: [Int] = []
        for sample in stride(from: 0, to: row.count, by: 4) {
            let red = Int(row[sample])
            let green = Int(row[sample + 1])
            let blue = Int(row[sample + 2])
            sums.append(red + green + blue)
        }
        guard let peak = sums.max() else { return nil }
        return sums.firstIndex(of: peak)
    }

    @Test func askingForNothingReturnsNothing() async throws {
        #expect(await VideoFilmstrip().frames(of: try await clip(), count: 0, height: 40).isEmpty)
    }

    /// A file with no clip behind it answers empty rather than throwing at a
    /// strip that is only decoration.
    @Test func anUnreadableFileAnswersEmpty() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-clip-\(UUID().uuidString).mp4")
        #expect(await VideoFilmstrip().frames(of: missing, count: 4, height: 40).isEmpty)
    }
}
