import AVFoundation
import Foundation
import ImageIO
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// The simulated camera writes REAL files, and the stitcher joins them into one.
///
/// ⚠️ **PIXELS AND DURATIONS, NOT "A FILE EXISTS".** `PlaceholderVideoFetcher`
/// wrote black clips for its whole life because no test ever read a pixel out
/// of one; these read the colour of a photograph and the length of a clip.
@MainActor
struct CaptureSourceTests {
    /// Runs the simulated camera until it has produced a frame.
    private func running() async throws -> (SimulatedCaptureSource, CaptureFolder) {
        let source = SimulatedCaptureSource(frameSize: CGSize(width: 180, height: 320))
        source.start()
        for _ in 0..<200 where source.feed.latestFrame == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(source.feed.latestFrame != nil, "the simulated camera produced no frame")
        return (source, CaptureFolder())
    }

    /// A photograph is a JPEG of the scene, upright, and not black.
    @Test func aPhotographIsARealPictureOfTheScene() async throws {
        let (source, folder) = try await running()
        defer { source.stop() }
        let photo = try await source.capturePhoto(flash: .off, into: folder)

        #expect(photo.uprightSize == SimulatedCaptureEngine.photoSize)
        #expect(CapturedMediaLibrary.uprightImageSize(at: photo.url) == SimulatedCaptureEngine.photoSize)
        let image = try #require(CapturedMediaLibrary.decodedThumbnail(at: photo.url, longestSide: 64, scale: 1))
        let top = try #require(Self.colour(of: image, atY: 0.02))
        // The sky at the top is blue — a black frame would read 0, 0, 0.
        #expect(top.blue > 0.3, "sky blue at the top: \(top)")
        #expect(top.blue > top.red)
    }

    /// A flash photograph is brighter than one without — the flash visibly
    /// does something on the simulator.
    @Test func aFlashPhotographIsBrighter() async throws {
        let (source, folder) = try await running()
        defer { source.stop() }
        let plain = try await source.capturePhoto(flash: .off, into: folder)
        let lit = try await source.capturePhoto(flash: .on, into: folder)
        let dark = try #require(CapturedMediaLibrary.decodedThumbnail(at: plain.url, longestSide: 64, scale: 1))
        let bright = try #require(CapturedMediaLibrary.decodedThumbnail(at: lit.url, longestSide: 64, scale: 1))
        let before = try #require(Self.colour(of: dark, atY: 0.02))
        let after = try #require(Self.colour(of: bright, atY: 0.02))
        #expect(after.red + after.green + after.blue > before.red + before.green + before.blue + 0.2)
    }

    /// A clip runs as long as it was recorded, and stops by itself at its limit.
    @Test func aClipLastsAsLongAsTheRecordingAndStopsAtItsLimit() async throws {
        let (source, folder) = try await running()
        defer { source.stop() }

        let url = folder.newFile("clip", pathExtension: "mov")
        // ⚠️ THE WALL CLOCK BETWEEN START AND STOP, NOT THE SLEEP ASKED FOR.
        // Suites run in parallel on one main actor, and a 0.8s sleep came back
        // after 1.9s (measured); the clip was honest about that, the test was not.
        let startedAt = CACurrentMediaTime()
        let promise = source.startRecording(to: url, torch: false, limit: 60)
        try await Task.sleep(for: .milliseconds(800))
        source.stopRecording()
        let held = CACurrentMediaTime() - startedAt
        let clip = try await promise.value
        #expect(held >= 0.8)
        #expect(abs(clip.duration - held) < 0.25, "held \(held)s, recorded \(clip.duration)s")
        let measured = await CapturedMediaLibrary.duration(of: clip.url)
        #expect(abs(measured - clip.duration) < 0.1, "the file agrees: \(measured)")

        let capped = source.startRecording(to: folder.newFile("clip", pathExtension: "mov"), torch: false, limit: 0.5)
        let short = try await capped.value
        #expect(short.duration <= 0.55, "stopped by its own limit: \(short.duration)")
        #expect(short.duration >= 0.4)
    }

    /// A stop that arrives before the first frame still ends the recording —
    /// the ordering `startRecording` promises. Time-limited: broken, it never
    /// resolves at all.
    @Test(.timeLimit(.minutes(1)))
    func aStopRightAfterTheStartEndsTheRecording() async throws {
        let (source, folder) = try await running()
        defer { source.stop() }
        let promise = source.startRecording(to: folder.newFile("clip", pathExtension: "mov"), torch: false, limit: 60)
        source.stopRecording()
        let clip = try await promise.value
        #expect(clip.duration < CaptureTake.shortest, "a slip, which the take refuses")
    }

    /// Two clips become one video as long as both.
    @Test func twoClipsAreStitchedIntoOneVideo() async throws {
        let (source, folder) = try await running()
        defer { source.stop() }
        var clips: [CaptureClip] = []
        for _ in 0..<2 {
            let promise = source.startRecording(to: folder.newFile("clip", pathExtension: "mov"), torch: false, limit: 0.6)
            clips.append(try await promise.value)
        }
        let output = folder.newFile("take", pathExtension: "mov")
        let stitched = try await CaptureStitcher.stitch(clips.map(\.url), to: output)
        #expect(stitched == output)
        let duration = await CapturedMediaLibrary.duration(of: stitched)
        let expected = clips.reduce(0) { $0 + $1.duration }
        #expect(abs(duration - expected) < 0.1, "\(duration) vs \(expected)")
        let size = await CapturedMediaLibrary.uprightVideoSize(at: stitched)
        #expect(size == CGSize(width: 180, height: 320))
    }

    /// Clips of different sizes — a take that flipped cameras — are fitted into
    /// the first one's frame rather than refused.
    @Test func clipsOfDifferentSizesAreFittedIntoTheFirstsFrame() async throws {
        let tall = SimulatedCaptureSource(frameSize: CGSize(width: 180, height: 320))
        let wide = SimulatedCaptureSource(frameSize: CGSize(width: 320, height: 180))
        tall.start()
        wide.start()
        defer {
            tall.stop()
            wide.stop()
        }
        let folder = CaptureFolder()
        let first = try await tall.startRecording(to: folder.newFile("clip", pathExtension: "mov"), torch: false, limit: 0.5).value
        let second = try await wide.startRecording(to: folder.newFile("clip", pathExtension: "mov"), torch: false, limit: 0.5).value
        let stitched = try await CaptureStitcher.stitch([first.url, second.url], to: folder.newFile("take", pathExtension: "mov"))
        let size = await CapturedMediaLibrary.uprightVideoSize(at: stitched)
        #expect(size == CGSize(width: 180, height: 320), "the first clip's frame")
        let duration = await CapturedMediaLibrary.duration(of: stitched)
        #expect(abs(duration - (first.duration + second.duration)) < 0.15)
    }

    /// The folder goes with its owner, files and all.
    @Test func theFolderIsRemovedWithItsOwner() throws {
        var folder: CaptureFolder? = CaptureFolder()
        let file = try #require(folder?.newFile("capture", pathExtension: "jpg"))
        try Data([1, 2, 3]).write(to: file)
        let directory = try #require(folder?.url)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        folder = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// The draft owns the folder, so the sheet's end is the files' end.
    @Test func theDraftOwnsTheCaptureFolder() throws {
        var draft: PostDraft? = PostDraft()
        let file = try #require(draft?.captureFolder.newFile("clip", pathExtension: "mov"))
        try Data([1]).write(to: file)
        draft = nil
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Reading pixels

    struct RGB: CustomStringConvertible {
        let red: Double
        let green: Double
        let blue: Double
        var description: String { String(format: "(%.2f, %.2f, %.2f)", red, green, blue) }
    }

    /// The colour of the pixel at the middle of the row `y` (0 top … 1 bottom).
    static func colour(of image: UIImage, atY y: CGFloat) -> RGB? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // Draw so that the wanted pixel lands on the context's only pixel.
        // Core Graphics is y-up: row `y` from the top sits at `height * (1 - y)`.
        context.draw(cgImage, in: CGRect(x: -width / 2, y: -height * (1 - y), width: width, height: height))
        return RGB(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}
