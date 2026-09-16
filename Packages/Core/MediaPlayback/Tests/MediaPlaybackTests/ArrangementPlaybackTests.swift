import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **PLAYING AN ARRANGEMENT OF A FILE AS ONE ITEM.**
///
/// The editor's preview used to play the file and SEEK it at every piece's end;
/// after a re-order each of those seeks was a jump across the file, decoded
/// forward from a keyframe, and the author saw it as a pause between pieces.
/// `load(_:in:at:)` plays the pieces the way the export lays them out — one
/// composition — so a boundary is an edit inside the item.
///
/// ⚠️ **A REAL PLAYER OVER A REAL FILE, LIKE `PlaybackRateTests`.** Everything
/// asserted here — how long an item lasts, whether its clock jumps, what rate a
/// player runs at — is AVFoundation's answer, and a stub would answer whatever
/// it was written to.
@MainActor
@Suite(.serialized)
struct ArrangementPlaybackTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func clip(seconds: Double = 3) async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: seconds)
            .playableURL(for: URL(string: "mock://video/arrangement?w=240&h=240")!)
    }

    private func surface() -> VideoRenderView {
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        return view
    }

    private func controller() -> VideoPlaybackController {
        VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
    }

    /// Waits for the item to say how long it is, which is when every other
    /// question about it has an answer.
    private func landed(
        _ controller: VideoPlaybackController, _ surface: VideoRenderView
    ) async throws -> (fraction: Double, seconds: Double) {
        for _ in 0..<400 {
            if let head = controller.playhead(in: surface) { return head }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(controller.playhead(in: surface), "the item never reported a length")
    }

    /// Two pieces out of order, one of them at twice the speed.
    private let reordered = [
        VideoExportSegment(start: 1, end: 2, speed: 2),     // half a second
        VideoExportSegment(start: 0, end: 1)                // one second
    ]

    // MARK: - What the item is

    /// ⚠️ **THE ITEM LASTS WHAT THE ARRANGEMENT PLAYS FOR — ITS SECONDS ARE THE
    /// TRACK'S SECONDS.** That is the whole of the new clock: the needle's
    /// position IS the item's time.
    @Test func anArrangementPlaysAsOneItemAsLongAsItsPlayedLength() async throws {
        let controller = controller()
        let view = surface()

        await controller.load(
            VideoExportPlan(sourceURL: try await clip(), segments: reordered), in: view
        ) { 0 }

        let head = try await landed(controller, view)
        #expect(abs(head.seconds - 1.5) < 0.02, "the item lasts \(head.seconds)s, not 1.5")
    }

    /// And an empty plan is the file as shot, whose seconds are the file's.
    @Test func anEmptyPlanPlaysTheFileAsShot() async throws {
        let controller = controller()
        let view = surface()

        await controller.load(VideoExportPlan(sourceURL: try await clip()), in: view) { 0 }

        let head = try await landed(controller, view)
        #expect(abs(head.seconds - 3) < 0.05, "the file lasts \(head.seconds)s here")
    }

    /// ⚠️ **THE RATE IS IN THE ITEM, SO THE PLAYER RUNS AT ONE.** A player
    /// reused from a clip that was told to run at 2x would otherwise play every
    /// sped-up piece at 4x.
    @Test func anArrangementRunsAtRateOneOnAPlayerThatWasSpedUp() async throws {
        let controller = controller()
        let view = surface()
        let file = try await clip()
        await controller.play(file, in: view)
        _ = try await landed(controller, view)
        controller.setRate(2, in: view)
        #expect(controller.debugRates(in: view)?.rate == 2, "guard: the player was sped up")

        await controller.load(VideoExportPlan(sourceURL: file, segments: reordered), in: view) { 0 }

        let rates = try #require(controller.debugRates(in: view))
        #expect(rates.rate == 1 && rates.next == 1, "the arrangement runs at \(rates)")
    }

    // MARK: - Swapping in place

    /// ⚠️ **A CLIP THE AUTHOR PAUSED STAYS PAUSED ACROSS AN EDIT.** The editor
    /// swaps the item on every edit; going through stop-and-play would restart
    /// a clip somebody had stopped, and bring the poster back while it did.
    @Test func aSwapKeepsAPausedClipPaused() async throws {
        let controller = controller()
        let view = surface()
        let file = try await clip()
        await controller.load(VideoExportPlan(sourceURL: file), in: view) { 0 }
        _ = try await landed(controller, view)
        controller.setPaused(true, in: view)
        let creations = controller.itemCreations

        await controller.load(VideoExportPlan(sourceURL: file, segments: reordered), in: view) { 0.5 }

        #expect(controller.itemCreations == creations + 1, "guard: the item was not replaced")
        #expect(controller.isPaused(in: view) == true, "the swap restarted a paused clip")
        #expect(controller.hasPlayer(in: view), "the swap let the surface go")
    }

    /// And the witness: a running clip keeps running.
    @Test func aSwapKeepsARunningClipRunning() async throws {
        let controller = controller()
        let view = surface()
        let file = try await clip()
        await controller.load(VideoExportPlan(sourceURL: file), in: view) { 0 }
        _ = try await landed(controller, view)
        controller.setPaused(false, in: view)

        await controller.load(VideoExportPlan(sourceURL: file, segments: reordered), in: view) { 0 }

        #expect(controller.isPaused(in: view) == false, "the swap stopped a running clip")
    }

    /// The new item begins where the caller said — the needle's place in the
    /// new arrangement.
    @Test func aSwapLandsWhereItWasAsked() async throws {
        let controller = controller()
        let view = surface()
        let file = try await clip()
        await controller.load(VideoExportPlan(sourceURL: file), in: view) { 0 }
        _ = try await landed(controller, view)
        controller.setPaused(true, in: view)

        await controller.load(VideoExportPlan(sourceURL: file, segments: reordered), in: view) { 1.2 }

        var at: Double = -1
        for _ in 0..<200 {
            if let head = controller.playhead(in: view), abs(head.seconds - 1.5) < 0.05 {
                at = head.fraction * head.seconds
                if abs(at - 1.2) < 0.05 { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(at - 1.2) < 0.05, "the new item began at \(at)s, not 1.2")
    }

    // MARK: - Abandoning

    /// ⚠️ **THE CALLER HAS THE LAST WORD, AFTER EVERYTHING ASYNCHRONOUS.** A
    /// build takes a moment, and in it the author may have swiped to another
    /// clip; nil from `start` drops the load before anything is bound.
    @Test func aLoadItsCallerAbandonsBindsNothing() async throws {
        let controller = controller()
        let view = surface()

        await controller.load(
            VideoExportPlan(sourceURL: try await clip(), segments: reordered), in: view
        ) { nil }

        #expect(controller.hasPlayer(in: view) == false, "an abandoned load bound a player")
    }

    /// A source that takes its time, so a test can act while a load is waiting.
    private struct Slow: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            try await Task.sleep(for: .milliseconds(200))
            return url
        }
    }

    /// And a stop that arrives while the load is still on its way wins.
    ///
    /// ⚠️ **THE STOP HAS TO LAND WHILE THE LOAD IS SUSPENDED.** Called right
    /// after `Task {}`, it ran before the task had started at all — so it
    /// cleared nothing and the load bound as if no stop had been asked for. The
    /// slow source is what holds the load open long enough to be overtaken.
    @Test func aStopDuringTheLoadBindsNothing() async throws {
        let controller = VideoPlaybackController(source: Slow(), poolSize: 1, capacity: 1)
        let view = surface()
        let file = try await clip()

        let loading = Task { @MainActor in
            await controller.load(VideoExportPlan(sourceURL: file, segments: reordered), in: view) { 0 }
        }
        try await Task.sleep(for: .milliseconds(50))
        controller.stop(view)
        await loading.value

        #expect(controller.hasPlayer(in: view) == false, "a load outlived the stop that superseded it")
    }

    // MARK: - The loop

    /// A clip with a keyframe only every two seconds — the shape a phone
    /// records, and the one a tolerant seek lands on the wrong frame of.
    private func sparselyKeyedClip(seconds: Int = 4) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparse-keys-\(seconds)s.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let shade = UInt8(frame % 255)
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(shade), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// ⚠️ **EVERY PASS STARTS AT THE START OF THE ARRANGEMENT.** The loop used a
    /// tolerant seek, and on a composition whose first piece begins between two
    /// keyframes it landed on the keyframe INSIDE that piece — measured at 0.6s
    /// in for a piece cut from 1.4s of a clip keyed every two seconds. Every pass
    /// after the first then silently skipped the opening the author had kept.
    @Test func theLoopComesBackToTheVeryStartOfTheArrangement() async throws {
        let controller = controller()
        let view = surface()
        let file = try await sparselyKeyedClip()
        await controller.load(
            VideoExportPlan(sourceURL: file, segments: [VideoExportSegment(start: 1.4, end: 2.9)]),
            in: view
        ) { 1.2 }
        _ = try await landed(controller, view)

        var last = controller.playheadSeconds(in: view) ?? 0
        var afterTheLoop: Double?
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(10))
            guard let now = controller.playheadSeconds(in: view) else { continue }
            if now + 0.5 < last {
                afterTheLoop = now
                break
            }
            last = now
        }

        let landing = try #require(afterTheLoop, "guard: playback never looped")
        #expect(landing < 0.3, "the loop came back \(landing)s into the arrangement")
    }

    // MARK: - Showing the file while a handle is held

    /// ⚠️ **SHOWING THE FILE IS IMMEDIATE.** An asynchronous swap could land
    /// after the release that replaces it, and leave raw film on the canvas for
    /// good. The item is the file's the moment the call returns.
    @Test func showingTheFileAsShotSwapsAtOnce() async throws {
        let controller = controller()
        let view = surface()
        let file = try await clip()
        await controller.load(VideoExportPlan(sourceURL: file, segments: reordered), in: view) { 0 }
        _ = try await landed(controller, view)
        let arrangement = controller.debugItem(in: view)

        #expect(controller.showAsShot(file, in: view, at: 2))

        let now = try #require(controller.debugItem(in: view))
        #expect(now !== arrangement, "the arrangement is still in the player")
        #expect((now.asset as? AVURLAsset)?.url == file, "the player is not running the file")
    }

    /// And a seek asked for straight after — before the item has said how long
    /// it is — is still honoured, because it is asked in seconds.
    @Test func aSeekStraightAfterShowingTheFileIsNotDropped() async throws {
        let controller = controller()
        let view = surface()
        let file = try await clip()
        await controller.load(VideoExportPlan(sourceURL: file, segments: reordered), in: view) { 0 }
        _ = try await landed(controller, view)
        controller.setPaused(true, in: view)

        controller.showAsShot(file, in: view, at: 0.5)
        controller.seek(toSeconds: 2.25, in: view, toleranceSeconds: 0)

        var at: Double = -1
        for _ in 0..<200 {
            at = controller.playheadSeconds(in: view) ?? -1
            if abs(at - 2.25) < 0.05 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(at - 2.25) < 0.05, "the seek was dropped: the file is at \(at)s")
    }

    // MARK: - The boundary

    /// Counts the item's time jumps from now on.
    @MainActor
    private final class Jumps {
        var count = 0
        var observer: NSObjectProtocol?
        func watch(_ item: AVPlayerItem) {
            observer = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.count += 1 }
            }
        }
        func stop() { observer.map(NotificationCenter.default.removeObserver) }
    }

    private func play(
        _ controller: VideoPlaybackController, _ view: VideoRenderView, until seconds: Double
    ) async throws {
        for _ in 0..<600 {
            if let head = controller.playhead(in: view), head.fraction * head.seconds >= seconds {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// ⚠️ **A PIECE BOUNDARY INSIDE AN ARRANGEMENT IS NOT A JUMP OF THE CLOCK.**
    /// The pause the author saw was a seek at every boundary; a seek is exactly
    /// what posts `timeJumpedNotification`. Played through three pieces out of
    /// order, the arrangement posts none.
    @Test func aPieceBoundaryInsideAnArrangementIsNotATimeJump() async throws {
        let controller = controller()
        let view = surface()
        let pieces = [
            VideoExportSegment(start: 2, end: 3),
            VideoExportSegment(start: 0, end: 1),
            VideoExportSegment(start: 1, end: 2)
        ]
        await controller.load(
            VideoExportPlan(sourceURL: try await clip(), segments: pieces), in: view
        ) { 0 }
        _ = try await landed(controller, view)
        try await play(controller, view, until: 0.3)
        let item = try #require(controller.debugItem(in: view))
        let jumps = Jumps()
        jumps.watch(item)

        // Across both boundaries, and short of the end, where the loop seeks.
        try await play(controller, view, until: 2.6)
        jumps.stop()

        #expect(controller.playhead(in: view).map { $0.fraction * $0.seconds } ?? 0 >= 2.5,
                "guard: playback never crossed the boundaries")
        #expect(jumps.count == 0, "the clock jumped \(jumps.count) times inside one item")
    }

    /// ⚠️ **AND THE WITNESS: THE OLD WAY DOES JUMP.** The file played with a seek
    /// at each boundary — what the editor used to do — is counted by the same
    /// instrument, so a counter that never fires cannot pass the test above.
    @Test func seekingTheFileAtEachBoundaryIsATimeJumpEachTime() async throws {
        let controller = controller()
        let view = surface()
        await controller.load(VideoExportPlan(sourceURL: try await clip()), in: view) { 2 }
        _ = try await landed(controller, view)
        try await play(controller, view, until: 2.3)
        let item = try #require(controller.debugItem(in: view))
        let jumps = Jumps()
        jumps.watch(item)

        // Piece [2..3] ends at 3; its next piece is [0..1], and the one after
        // that is [1..2] — two boundaries, two seeks, as the old follower did.
        try await play(controller, view, until: 2.9)
        controller.seek(toFraction: 0, in: view, toleranceSeconds: 0.02)
        try await Task.sleep(for: .milliseconds(300))
        controller.seek(toFraction: 1.0 / 3, in: view, toleranceSeconds: 0.02)
        try await Task.sleep(for: .milliseconds(300))
        jumps.stop()

        #expect(jumps.count >= 2, "the instrument missed the seeks: \(jumps.count)")
    }
}
