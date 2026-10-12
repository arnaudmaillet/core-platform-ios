import AVFoundation
import CacheKit
import Testing
import UIKit
@testable import MediaPlayback

/// The return ledger on the device cache (#895, the #923 follow-ups): a
/// parked return player pins its clip's ranges around the parked playhead,
/// and the frame it was parked on is kept past the player, for a close whose
/// player went.
///
/// ⚠️ NO MEMORY WARNING IS POSTED HERE: it reaches every live pool, and a
/// suite parking in parallel would lose its players under it. The ledger's
/// own door (`releaseAllReturnPlaybacks`, what the warning calls) is used.
@MainActor
struct ReturnPlaybackCacheTests {
    private struct IdentitySource: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private struct ClipSource: VideoSource {
        let file: URL
        func playableURL(for url: URL) async throws -> URL { file }
    }

    private func clip(_ index: Int) -> URL { URL(string: "mock://video/return-cache-\(index)")! }

    // MARK: - The pin

    private let folder = VideoCacheFolder()
    private let remote = URL(string: "https://media.example.test/v/parked.mp4")!

    /// A pool on a cache holding ten 1000-byte chunks of `remote`.
    private func cachedPool() throws -> VideoPlaybackController {
        let cache = VideoByteCache(coordinator: nil, root: folder.url, fetcher: FakeRangeFetcher(holds: true), chunkSize: 1000)
        let store = cache.publicStore
        let mediaKey = CacheKey.media(remote)
        let info = try JSONEncoder().encode(VideoContentInfo(length: 10_000, contentType: "public.mpeg-4"))
        try store.write(info, for: VideoCacheKeys.info(mediaKey), tier: .retained)
        let bytes = videoBytes(10_000)
        for index in 0..<10 {
            let chunk = bytes.subdata(in: index * 1000 ..< (index + 1) * 1000)
            try store.write(chunk, for: VideoCacheKeys.chunk(mediaKey, index), tier: index == 0 ? .retained : .recent)
        }
        return VideoPlaybackController(source: IdentitySource(), byteCache: cache)
    }

    /// ⚠️ PINNED WHILE PARKED. Parked at 5 s of 10, the player's pin holds the
    /// head, the tail, the content information and the chunks around the
    /// middle of the file (4–8): eight entries, whatever the player itself has
    /// read. Released, the pin lets them go.
    @Test func aParkedReturnPlayerPinsTheRangesAroundItsPlayhead() async throws {
        let controller = try cachedPool()
        #expect(await controller.parkReturnPlayback(of: remote, scope: "post-0", at: 5, duration: 10))
        let pin = try #require(controller.debugReturnPin(of: remote, scope: "post-0"))
        #expect(await eventually { pin.leaseCount == 8 })

        controller.releaseReturnPlayback(of: remote, scope: "post-0")
        #expect(pin.isReleased)
    }

    /// Every other way out lets the pin go too: an eviction by a deeper
    /// stack, a landing claiming the player, memory pressure.
    @Test func everyWayOutOfTheLedgerReleasesThePin() async throws {
        let controller = try cachedPool()
        await controller.parkReturnPlayback(of: remote, scope: "post-0", at: 5, duration: 10)
        let evicted = try #require(controller.debugReturnPin(of: remote, scope: "post-0"))
        await controller.parkReturnPlayback(of: remote, scope: "post-1", at: 5, duration: 10)
        await controller.parkReturnPlayback(of: remote, scope: "post-2", at: 5, duration: 10)
        #expect(!controller.hasReturnPlayback(of: remote, scope: "post-0"))
        #expect(evicted.isReleased, "an evicted return player kept its ranges pinned")

        let claimed = try #require(controller.debugReturnPin(of: remote, scope: "post-2"))
        let flying = VideoRenderView()
        #expect(controller.attachReturnSurface(flying, of: remote, scope: "post-2"))
        #expect(controller.transferOwnership(of: remote, drawnBy: flying, to: VideoRenderView()))
        #expect(claimed.isReleased, "a claimed return player kept its ranges pinned")

        let released = try #require(controller.debugReturnPin(of: remote, scope: "post-1"))
        controller.releaseAllReturnPlaybacks()
        #expect(released.isReleased)
    }

    /// Without a duration passed, the pool reads it from a player of its own
    /// already playing the clip for that post (the tile's, at the tap); with
    /// none, the pin still holds the ends.
    @Test func withoutADurationThePinHoldsTheEnds() async throws {
        let controller = try cachedPool()
        await controller.parkReturnPlayback(of: remote, scope: "post-0", at: 5)
        let pin = try #require(controller.debugReturnPin(of: remote, scope: "post-0"))
        #expect(await eventually { pin.leaseCount == 3 })
    }

    // MARK: - The parked frame

    /// One pixel of `image`, at fractions of its size (0,0 top left).
    private func colour(of image: UIImage, x: Double, y: Double) throws -> ColourClipWriter.RGB {
        let cgImage = try #require(image.cgImage)
        var buffer = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let column = CGFloat(Int(Double(cgImage.width) * x))
        let row = CGFloat(Int(Double(cgImage.height) * (1 - y)))
        context.draw(cgImage, in: CGRect(x: -column, y: -row, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return ColourClipWriter.RGB(r: Int(buffer[0]), g: Int(buffer[1]), b: Int(buffer[2]))
    }

    /// ⚠️ THE FRAME OF THE PARK, NOT THE CLIP'S FIRST. Parked at 2.5 s of the
    /// colour clip (blue from 2 s to 3 s), the kept frame is blue, and where
    /// it was taken is said.
    @Test func theFrameAReturnPlayerWasParkedOnIsKept() async throws {
        let controller = VideoPlaybackController(source: ClipSource(file: try await ColourClipWriter.clip()))
        #expect(await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 2.5))
        #expect(await eventually { controller.returnStill(of: clip(0), scope: "post-0") != nil })
        let still = try #require(controller.returnStill(of: clip(0), scope: "post-0"))
        #expect(abs(still.seconds - 2.5) < 0.5)
        // Beside the cyan square, under the yellow band: the second's colour.
        let seen = try colour(of: still.image, x: 0.1, y: 0.5)
        #expect(seen.near(.blue), "the kept frame is \(seen), not the parked second's blue")
    }

    /// ⚠️ KEPT PAST ITS PLAYER: the cases it exists for. An eviction by a
    /// deeper stack and memory pressure take the players and leave their
    /// frames; the owner's release and a landing that claimed the clip
    /// drop them.
    @Test func theParkedFrameOutlivesItsPlayerUntilItsOwnerLetsGo() async throws {
        let controller = VideoPlaybackController(source: ClipSource(file: try await ColourClipWriter.clip()))
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 1.5)
        #expect(await eventually { controller.returnStill(of: clip(0), scope: "post-0") != nil })
        await controller.parkReturnPlayback(of: clip(1), scope: "post-1", at: 1.5)
        await controller.parkReturnPlayback(of: clip(2), scope: "post-2", at: 1.5)
        #expect(!controller.hasReturnPlayback(of: clip(0), scope: "post-0"))
        #expect(controller.returnStill(of: clip(0), scope: "post-0") != nil, "an eviction took the parked frame")

        #expect(await eventually { controller.returnStill(of: clip(1), scope: "post-1") != nil })
        controller.releaseAllReturnPlaybacks()
        #expect(controller.returnPlaybackCount == 0)
        #expect(controller.returnStill(of: clip(1), scope: "post-1") != nil, "memory pressure took the parked frame")

        controller.releaseReturnPlayback(of: clip(1), scope: "post-1")
        #expect(controller.returnStill(of: clip(1), scope: "post-1") == nil)

        await controller.parkReturnPlayback(of: clip(3), scope: "post-3", at: 1.5)
        #expect(await eventually { controller.returnStill(of: clip(3), scope: "post-3") != nil })
        let flying = VideoRenderView()
        #expect(controller.attachReturnSurface(flying, of: clip(3), scope: "post-3"))
        #expect(controller.transferOwnership(of: clip(3), drawnBy: flying, to: VideoRenderView()))
        #expect(controller.returnStill(of: clip(3), scope: "post-3") == nil, "a landed clip kept its parked frame")
    }
}
