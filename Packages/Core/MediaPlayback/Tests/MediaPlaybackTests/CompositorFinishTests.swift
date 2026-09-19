import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import MediaPlayback

/// **EACH PIECE WEARS ITS OWN LOOK, AND THE FINISH IS DRAWN OVER THE FILM.**
///
/// Per frame the compositor draws: each lane upright and in its piece's look →
/// the transition → the crop → the whole look → the overlays. Every assertion
/// reads PIXELS that AVFoundation produced — through an image generator (which
/// honours the custom compositor on the iOS 27 simulator), an export, or the
/// canvas's own renderer — never the instructions the builder wrote.
///
/// The clip (`ColourClipWriter`) is red, green, blue, white for a second each,
/// 160x120, with a cyan square over its middle half and a yellow band 16px deep
/// along its top.
///
/// ⚠️ **THE PRESETS ARE CHOSEN BY MEASUREMENT.** Mono drains a colour to a grey;
/// Process tints a grey teal. Measured on red: mono then process is
/// (36,141,145), process then mono is (136,136,136) — so the order of the two
/// stages shows as "tinted or not", far outside what encoding moves.
@Suite(.serialized, .exclusiveMediaWork)
struct CompositorFinishTests {
    typealias RGB = ColourClipWriter.RGB

    private func arranged(
        _ segments: [VideoExportSegment], finish: FrameFinish = .none, rotated: Bool = false,
        longestSide: CGFloat? = nil
    ) async throws -> VideoExporter.Arrangement {
        let file = try await ColourClipWriter.clip(rotated: rotated)
        return try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: segments, orientation: .whenComposited,
            longestSide: longestSide, finish: finish
        )
    }

    private func pixel(
        _ arrangement: VideoExporter.Arrangement, at seconds: Double, x: Double = 0.1, y: Double = 0.5
    ) async throws -> (colour: RGB, actual: Double, size: CGSize) {
        try await ColourClipWriter.pixel(
            of: arrangement.asset, composition: arrangement.videoComposition, at: seconds, x: x, y: y
        )
    }

    private func exported(_ plan: VideoExportPlan) async throws -> ExportedVideo {
        try await VideoExporter().export(plan)
    }

    private func pixel(
        of exported: ExportedVideo, at seconds: Double, x: Double = 0.1, y: Double = 0.5
    ) async throws -> RGB {
        try await ColourClipWriter.pixel(
            of: AVURLAsset(url: exported.fileURL), composition: nil, at: seconds, x: x, y: y
        ).colour
    }

    /// How far a colour is from a grey: its largest channel minus its smallest.
    private func tint(_ colour: RGB) -> Int {
        max(colour.r, colour.g, colour.b) - min(colour.r, colour.g, colour.b)
    }

    private let mono = FrameLook(preset: .mono)

    // MARK: - Per-piece looks

    /// ⚠️ **A PIECE'S LOOK STAYS ON ITS PIECE.** The red piece is drained to
    /// grey — its square too — and the blue piece after it is still blue.
    @Test func aSegmentLookDressesOnlyItsPiece() async throws {
        let dressed = try await arranged([
            VideoExportSegment(start: 0, end: 1, look: .mono),
            VideoExportSegment(start: 2, end: 3)
        ])

        let red = try await pixel(dressed, at: 0.5).colour
        #expect(tint(red) <= 12 && red.r < 200, "the dressed piece is not grey: \(red)")
        let square = try await pixel(dressed, at: 0.5, x: 0.5).colour
        #expect(tint(square) <= 12, "the dressed piece's square is not grey: \(square)")
        let blue = try await pixel(dressed, at: 1.5).colour
        #expect(blue.near(.blue), "the look ran on into the next piece: \(blue)")
    }

    /// ⚠️ **ASKED OF THE PIXELS EITHER SIDE OF EACH BOUNDARY, NOT OF THE
    /// INSTRUCTION LIST.** A stretch that ran across two pieces would dress the
    /// second in the first's look — here the middle piece's grey would begin
    /// late or never. The last frame before each boundary and the first after
    /// it must each wear their own piece's look.
    @Test func instructionsSplitAtEveryPieceBoundary() async throws {
        let dressed = try await arranged([
            VideoExportSegment(start: 0, end: 1),
            VideoExportSegment(start: 1, end: 2, look: .mono),
            VideoExportSegment(start: 2, end: 3)
        ])
        let frame = 1.0 / 30

        let lastRed = try await pixel(dressed, at: 1 - frame).colour
        #expect(lastRed.near(.red), "the grey began before its piece: \(lastRed)")
        let firstGrey = try await pixel(dressed, at: 1).colour
        #expect(tint(firstGrey) <= 12, "the middle piece does not start grey: \(firstGrey)")
        let lastGrey = try await pixel(dressed, at: 2 - frame).colour
        #expect(tint(lastGrey) <= 12, "the middle piece does not end grey: \(lastGrey)")
        let firstBlue = try await pixel(dressed, at: 2).colour
        #expect(firstBlue.near(.blue), "the grey ran on past its piece: \(firstBlue)")
    }

    /// ⚠️ **A DISSOLVE BLENDS TWO PIECES THAT ALREADY WEAR THEIR LOOKS.** The red
    /// piece is grey; the blue one is not dressed.
    ///
    /// The two overlap over [0.5, 1.0): lane A is the grey piece's last half
    /// second, wearing ITS look, and lane B the blue piece's first — so across
    /// the window the blend is a grey (red equal to green) under some blue. Had
    /// the outgoing lane worn nothing, its red would lead green by ~200; had
    /// the look been laid over the blend instead, the blue would be grey too.
    @Test func aDissolveBlendsTwoDressedPieces() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve, look: .mono),
            VideoExportSegment(start: 2, end: 3)
        ])

        for time in [0.65, 0.85] {
            let got = try await pixel(dissolve, at: time).colour
            #expect(abs(got.r - got.g) <= 20, "the outgoing piece is not grey in the blend at \(time)s: \(got)")
            #expect(got.b > got.g + 30, "the incoming piece is not blue in the blend at \(time)s: \(got)")
        }
    }

    /// ⚠️ **THE WHOLE LOOK GRADES THE FINISHED FILM — AFTER THE PIECE'S LOOK.**
    /// Mono then Process is a teal grey; the other way round it is a plain grey.
    @Test func theWholeLookFollowsTheSegmentLook() async throws {
        let process = FrameFinish(look: FrameLook(preset: .process))

        let graded = try await pixel(
            try await arranged([VideoExportSegment(start: 0, end: 1, look: .mono)], finish: process), at: 0.5
        ).colour
        #expect(tint(graded) > 60 && graded.r < 100, "the whole look did not grade the grey piece: \(graded)")

        // The witness: the same two stages in the other order are a plain grey,
        // so the reading above can only come from this order.
        let reversed = try await pixel(
            try await arranged(
                [VideoExportSegment(start: 0, end: 1, look: .process)], finish: FrameFinish(look: mono)
            ),
            at: 0.5
        ).colour
        #expect(tint(reversed) <= 12, "guard: the reversed order is not grey: \(reversed)")
    }

    // MARK: - The crop

    /// ⚠️ **THE FILE IS AS BIG AS WHAT WAS KEPT, AND SAYS SO.** The right half of
    /// a 160x120 clip is 80x120 — in the written track, in the reported
    /// dimensions the upload declares, and in the pixels: the square's right
    /// half on the left, red on the right.
    @Test func aCropChangesTheRenderSizeAndTheReportedDimensions() async throws {
        let right = FrameFinish(crop: FrameCrop(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        let arrangement = try await arranged([], finish: right)
        #expect(arrangement.videoComposition?.renderSize == CGSize(width: 80, height: 120),
                "got \(String(describing: arrangement.videoComposition?.renderSize))")

        let file = try await ColourClipWriter.clip()
        let export = try await exported(VideoExportPlan(sourceURL: file, finish: right))
        defer { try? FileManager.default.removeItem(at: export.fileURL) }

        let track = try #require(try await AVURLAsset(url: export.fileURL).loadTracks(withMediaType: .video).first)
        let written = try await track.load(.naturalSize)
        #expect(written == CGSize(width: 80, height: 120), "the file is \(written)")
        #expect(export.pixelWidth == 80 && export.pixelHeight == 120,
                "the upload would declare \(export.pixelWidth)x\(export.pixelHeight)")
        let left = try await pixel(of: export, at: 0.5, x: 0.05)
        #expect(left.near(.cyan, by: 90), "the kept half does not start in the square: \(left)")
        let edge = try await pixel(of: export, at: 0.5, x: 0.9)
        #expect(edge.near(.red), "the kept half does not end in the red: \(edge)")
    }

    /// ⚠️ **THE TOP IS THE TOP.** A crop is stored top-left and Core Image counts
    /// from the bottom; kept the wrong way up, the top half is the bottom half
    /// and the band is gone.
    @Test func aTopCropKeepsTheYellowBand() async throws {
        let top = FrameFinish(crop: FrameCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        let arrangement = try await arranged([], finish: top)

        let band = try await pixel(arrangement, at: 0.5, x: 0.5, y: 0.05)
        #expect(band.size == CGSize(width: 160, height: 60), "the top half is \(band.size)")
        #expect(band.colour.near(.yellow), "the band is not along the top: \(band.colour)")
        let square = try await pixel(arrangement, at: 0.5, x: 0.5, y: 0.9)
        #expect(square.colour.near(.cyan, by: 90), "the square's top half is not at the bottom: \(square.colour)")
        let side = try await pixel(arrangement, at: 0.5, x: 0.1, y: 0.9)
        #expect(side.colour.near(.red), "the side is not red: \(side.colour)")
    }

    /// ⚠️ **A TURNED SOURCE IS CROPPED IN ITS UPRIGHT PICTURE.** A phone clip is
    /// stored on its side; the author crops what they see. The top quarter of
    /// the upright 120x160 picture is 120x40 and carries the band.
    @Test func aRotatedSourceIsCroppedUpright() async throws {
        let quarter = FrameFinish(crop: FrameCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.25)))
        let arrangement = try await arranged([], finish: quarter, rotated: true)

        #expect(arrangement.videoComposition?.renderSize == CGSize(width: 120, height: 40),
                "got \(String(describing: arrangement.videoComposition?.renderSize))")
        let band = try await pixel(arrangement, at: 0.5, x: 0.5, y: 0.1)
        #expect(band.colour.near(.yellow), "the band is not along the top: \(band.colour)")
        let below = try await pixel(arrangement, at: 0.5, x: 0.5, y: 0.9)
        #expect(below.colour.near(.red), "below the band is not the red: \(below.colour)")
    }

    /// ⚠️ **THE PREVIEW'S CAP IS ON WHAT IS KEPT.** The right half of the clip is
    /// 80x120; capped at 60 it composes at 40x60 — not at 60's share of the
    /// whole frame's 160 — and it is still the right half.
    @Test func aCroppedPreviewIsCappedOnWhatItKeeps() async throws {
        let right = FrameFinish(crop: FrameCrop(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        let capped = try await arranged([], finish: right, longestSide: 60)

        let left = try await pixel(capped, at: 0.5, x: 0.05)
        #expect(left.size == CGSize(width: 40, height: 60), "the capped crop is \(left.size)")
        #expect(left.colour.near(.cyan, by: 90), "the kept half does not start in the square: \(left.colour)")
        let edge = try await pixel(capped, at: 0.5, x: 0.9)
        #expect(edge.colour.near(.red), "the kept half does not end in the red: \(edge.colour)")
    }

    // MARK: - The export route

    /// ⚠️ **A LOOK ON A CLIP NOBODY CUT STILL REACHES THE FILE.** An uncut clip
    /// used to leave by the plain route, which draws nothing: a filtered video
    /// would publish as shot.
    @Test func aFinishOnAnUncutClipIsComposed() async throws {
        let file = try await ColourClipWriter.clip()
        let export = try await exported(VideoExportPlan(sourceURL: file, finish: FrameFinish(look: mono)))
        defer { try? FileManager.default.removeItem(at: export.fileURL) }

        #expect(abs(export.durationSeconds - 4) < 0.05, "the clip is \(export.durationSeconds)s")
        #expect(export.transitionWindows.isEmpty)
        // Mono turns the red a mid grey and the green a light one (measured
        // 122 and 235); undressed, either is a full colour.
        let red = try await pixel(of: export, at: 0.5)
        #expect(tint(red) <= 16 && red.r < 200, "the red second is not grey: \(red)")
        let green = try await pixel(of: export, at: 1.5)
        #expect(tint(green) <= 16, "the green second is not grey: \(green)")
    }

    /// ⚠️ **A SONG UNDER AN UNCUT CLIP NEEDS A COMPOSITION TO GO INTO** — so the
    /// clip is built as one piece covering its whole picture.
    @Test func aSongUnderAnUncutClipIsBuiltAsOnePiece() async throws {
        let file = try await ColourClipWriter.clip()
        let song = VideoSoundtrack(fileURL: file, title: "Tone")

        let arrangement = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: [], orientation: .whenComposited, soundtrack: song
        )

        let composition = try #require(arrangement.asset as? AVComposition, "the clip is still the file")
        let track = try #require(
            try await composition.loadTracks(withMediaType: .video).first as? AVCompositionTrack
        )
        let targets = track.segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        #expect(targets.count == 1, "got \(targets)")
        #expect(targets.first.map { abs($0.start.seconds) < 0.001 && abs($0.end.seconds - 4) < 0.01 } == true,
                "the piece is \(targets)")
        #expect(arrangement.videoComposition == nil, "a song alone drew something over an upright clip")
    }

    /// ⚠️ **PASSTHROUGH WOULD PUBLISH THE CLIP AS SHOT, AND SAY NOTHING.** A plan
    /// that asks for it and carries a finish gets the exporter's own preset.
    @Test func aFinishOverridesPassthrough() async throws {
        let file = try await ColourClipWriter.clip()
        let export = try await exported(VideoExportPlan(
            sourceURL: file, preset: AVAssetExportPresetPassthrough, finish: FrameFinish(look: mono)
        ))
        defer { try? FileManager.default.removeItem(at: export.fileURL) }

        let colour = try await pixel(of: export, at: 0.5)
        #expect(tint(colour) <= 16 && colour.r < 200, "passthrough dropped the look: \(colour)")
    }

    /// ⚠️ **AN UNTOUCHED PLAN LEAVES BY THE PLAIN ROUTE.** Asked of the decision
    /// for every field, and of the file for the one case where the route shows:
    /// an untouched phone clip keeps its metadata turn, while a composed one has
    /// it baked into its pixels.
    @Test func anUntouchedPlanNeedsNoComposition() async throws {
        let url = URL(filePath: "/clip.mov")
        #expect(!VideoExporter.needsComposition(for: VideoExportPlan(sourceURL: url)), "an untouched clip")
        #expect(!VideoExporter.needsComposition(for: VideoExportPlan(sourceURL: url, timeRange: 0.5...1.5)),
                "a plain trim")
        #expect(!VideoExporter.needsComposition(for: VideoExportPlan(
            sourceURL: url, segments: [VideoExportSegment(start: 0, end: 1, look: .original)]
        )), "an original look is no look")
        let touched: [(String, VideoExportPlan)] = [
            ("a piece's look", VideoExportPlan(
                sourceURL: url, segments: [VideoExportSegment(start: 0, end: 1, look: .mono)]
            )),
            ("a crop", VideoExportPlan(
                sourceURL: url, finish: FrameFinish(crop: FrameCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
            )),
            ("a whole look", VideoExportPlan(sourceURL: url, finish: FrameFinish(look: mono))),
            ("an overlay", VideoExportPlan(
                sourceURL: url, finish: FrameFinish(overlays: [FrameOverlay(content: .emoji("🙂"))])
            )),
            ("a song", VideoExportPlan(sourceURL: url, soundtrack: VideoSoundtrack(fileURL: url, title: "Song")))
        ]
        for (name, plan) in touched {
            #expect(VideoExporter.needsComposition(for: plan), "\(name) leaves by the plain route")
        }

        let turned = try await ColourClipWriter.clip(rotated: true)
        let export = try await exported(VideoExportPlan(sourceURL: turned))
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        let track = try #require(try await AVURLAsset(url: export.fileURL).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        #expect(size == CGSize(width: 160, height: 120) && !transform.isIdentity,
                "the untouched clip was composed: \(size) \(transform)")
        #expect(export.pixelWidth == 120 && export.pixelHeight == 160,
                "the upright size is reported as \(export.pixelWidth)x\(export.pixelHeight)")
    }
}

/// **A LOOK CHANGED LIVE REACHES THE CANVAS WITHOUT A NEW ITEM.**
///
/// A real player over the colour clip, and the frames its renderer hands the
/// surface — the very buffer the canvas shows.
///
/// ⚠️ **THE DEFAULT BACKING ONLY, AND THAT IS WHAT "THE CANVAS SHOWS" MEANS
/// HERE.** Every assertion below reads the pixel buffer the renderer handed
/// the surface, and under `-avplayer-render` there is no renderer at all —
/// `AVPlayerLayer` draws the item itself and a test cannot read what it drew.
/// Left to run there, the suite failed on its own guard ("the red frame never
/// showed") and said nothing about the legacy path. What that path can still
/// be asked is asked by `LiveLookOnEitherBackingTests` below, which runs in
/// both lanes.
@MainActor
@Suite(.serialized, .enabled(if: VideoRenderFlags.usesSampleBufferLayer), .exclusiveMediaWork)
struct LiveLookTests {
    typealias RGB = ColourClipWriter.RGB

    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private struct Slow: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            try await Task.sleep(for: .milliseconds(300))
            return url
        }
    }

    private func surface() -> VideoRenderView {
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        return view
    }

    private func tint(_ colour: RGB) -> Int {
        max(colour.r, colour.g, colour.b) - min(colour.r, colour.g, colour.b)
    }

    /// One pixel of the frame the surface was last handed, at fractions of its
    /// size (0,0 top left) — nil before the first frame.
    private func shown(
        _ controller: VideoPlaybackController, _ view: VideoRenderView, x: Double = 0.1, y: Double = 0.5
    ) -> RGB? {
        guard let buffer = controller.debugRenderer(in: view)?.currentFrameBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let at = Int(Double(CVPixelBufferGetHeight(buffer)) * y) * CVPixelBufferGetBytesPerRow(buffer)
            + Int(Double(CVPixelBufferGetWidth(buffer)) * x) * 4
        return RGB(r: Int(base[at + 2]), g: Int(base[at + 1]), b: Int(base[at]))
    }

    /// Waits, up to `limit` seconds, for the surface to show a pixel `matching`.
    ///
    /// ⚠️ **GENEROUS: A FRESH READER'S FIRST FRAME WAITS FOR A DECODE**, and
    /// with other suites — and other simulators — decoding at the same time it
    /// has taken fifteen seconds and more.
    private func waitFor(
        _ controller: VideoPlaybackController, _ view: VideoRenderView, within limit: Double = 60,
        _ matching: (RGB) -> Bool
    ) async throws -> RGB? {
        let deadline = CACurrentMediaTime() + limit
        while CACurrentMediaTime() < deadline {
            if let colour = shown(controller, view), matching(colour) { return colour }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// What the surface's pipeline says about itself, for a failure message:
    /// "no frame" has several causes, and only this tells them apart.
    private func diagnosis(_ controller: VideoPlaybackController, _ view: VideoRenderView) -> String {
        let renderer = controller.debugRenderer(in: view)
        let item = controller.debugItem(in: view)
        return "shown=\(String(describing: shown(controller, view))) "
            + "dispatched=\(renderer?.dispatchedFrameCount ?? -1) "
            + "ticking=\(renderer?.debugIsRegisteredWithClock ?? false) "
            + "composed=\(renderer?.composedVideo != nil) "
            + "item=\(item?.status.rawValue ?? -1) \(String(describing: item?.error)) "
            + "paused=\(String(describing: controller.isPaused(in: view))) "
            + "at=\(String(describing: controller.playheadSeconds(in: view)))"
    }

    /// ⚠️ **A PAUSED CANVAS REPAINTS, AND THE ITEM IS THE SAME ITEM.** Nothing is
    /// playing, so no new frame would ever be composed on its own: the reader
    /// is asked for the paused moment again, through the same arrangement.
    ///
    /// ⚠️ **AN UNTOUCHED UPRIGHT CLIP, ON PURPOSE** — the one the canvas would
    /// otherwise have played plain, with no compositor to take a look at all.
    @Test func aLiveLookRepaintsAPausedFrameWithoutANewItem() async throws {
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let view = surface()
        defer { controller.stop(view) }
        await controller.load(VideoExportPlan(sourceURL: try await ColourClipWriter.clip()), in: view) { 0.5 }
        controller.setPaused(true, in: view)
        let red = try await waitFor(controller, view) { $0.near(.red) }
        try #require(red != nil, "guard: the paused red frame never showed: \(diagnosis(controller, view))")
        let item = try #require(controller.debugItem(in: view))
        let creations = controller.itemCreations

        #expect(controller.setLiveLook(FrameLook(preset: .mono), in: view), "no arrangement took the look")

        let grey = try await waitFor(controller, view) { tint($0) <= 16 && $0.r < 200 }
        #expect(grey != nil, "the paused frame did not repaint: \(diagnosis(controller, view))")
        #expect(controller.debugItem(in: view) === item, "the look brought a new item")
        #expect(controller.itemCreations == creations, "the look made an item")
        #expect(controller.isPaused(in: view) == true, "the look started the clip")
    }

    /// ⚠️ **A PLAYING CANVAS WEARS THE LOOK FROM ITS NEXT FRAMES ON.** Once the
    /// few frames read before the change have gone by, every frame shown is
    /// grey — and they are frames of different moments, so the clip is playing
    /// and the look is not one moment drawn again.
    ///
    /// ⚠️ **PACED ON THE FRAMES THAT ARRIVE, NOT THE WALL CLOCK.** On a loaded
    /// machine the composed reader has fallen behind and restarted, and the
    /// canvas drew nothing for seconds of film at a time; what is asserted is
    /// every frame shown once the film has moved half a second past the
    /// change, however long those take to come.
    @Test func aLiveLookReachesThePlayingFrames() async throws {
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let view = surface()
        defer { controller.stop(view) }
        await controller.load(VideoExportPlan(sourceURL: try await ColourClipWriter.clip()), in: view) { 0 }
        let red = try await waitFor(controller, view) { $0.near(.red) }
        try #require(red != nil, "guard: the playing red frame never showed: \(diagnosis(controller, view))")
        let item = try #require(controller.debugItem(in: view))
        let renderer = try #require(controller.debugRenderer(in: view))

        #expect(controller.setLiveLook(FrameLook(preset: .mono), in: view))

        var last = try #require(controller.playheadSeconds(in: view))
        var played = 0.0
        var shownAt = renderer.currentFrameTime
        var seen: [(time: Double, colour: RGB)] = []
        let deadline = CACurrentMediaTime() + 60
        while Set(seen.map(\.time)).count < 4, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            if let head = controller.playheadSeconds(in: view) {
                // The whole four-second item loops: a step back is a wrap.
                played += head >= last ? head - last : head + 4 - last
                last = head
            }
            let now = renderer.currentFrameTime
            guard now != shownAt else { continue }
            shownAt = now
            // The frames read ahead before the change are a fraction of this.
            if played > 0.5, let now, let colour = shown(controller, view) {
                seen.append((now.seconds, colour))
            }
        }
        #expect(Set(seen.map(\.time)).count >= 2,
                "guard: \(seen.count) frames were shown in \(played)s of film: \(seen.map(\.time))")
        let coloured = seen.filter { tint($0.colour) > 16 }
        #expect(coloured.isEmpty,
                "\(coloured.count) of \(seen.count) playing frames kept their colour: \(coloured.prefix(3))")
        #expect(controller.debugItem(in: view) === item, "the look brought a new item")
        #expect(controller.isPaused(in: view) == false, "guard: the clip stopped")
    }

    /// ⚠️ **A LOOK SET WHILE A LOAD IS ON ITS WAY REACHES THE ITEM IT BRINGS.**
    /// The load's plan was made before the look; without this the new item
    /// would put the old look back on the canvas until the next change.
    @Test func aLookSetDuringALoadReachesTheItemItBrings() async throws {
        let controller = VideoPlaybackController(source: Slow(), poolSize: 1, capacity: 1)
        let view = surface()
        defer { controller.stop(view) }
        let file = try await ColourClipWriter.clip()

        let loading = Task { @MainActor in
            await controller.load(VideoExportPlan(sourceURL: file), in: view) { 0.5 }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.setLiveLook(FrameLook(preset: .mono), in: view), "the load on its way did not take the look")
        await loading.value
        controller.setPaused(true, in: view)

        let grey = try await waitFor(controller, view) { tint($0) <= 16 && $0.r < 200 }
        #expect(grey != nil, "the new item is not grey: \(diagnosis(controller, view))")
    }
}

/// **WHAT `setLiveLook` ANSWERS ON EACH BACKING, WHICH IS NOT THE SAME THING.**
///
/// The pixels belong to `LiveLookTests`, which only the sample-buffer backing
/// can be asked about. What both lanes can be asked is the ANSWER, and it
/// differs by design: the default backing takes the look into the board its
/// renderer composes through and keeps the item it has; the legacy backing
/// hands its composition to the item, which the iOS 27 simulator refuses to
/// play the moment anything renders it, so no board is put under it at all and
/// the look reaches the canvas with a new item instead.
///
/// ⚠️ **SO THE ANSWER MUST BE READ.** A caller that ignores a `false` here
/// shows the author an edit that never arrives — which is exactly what the
/// editor's reload is for.
@MainActor
@Suite(.serialized, .exclusiveMediaWork)
struct LiveLookOnEitherBackingTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    @Test func aLookIsTakenByTheBackingThatCanTakeIt() async throws {
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        defer { controller.stop(view) }
        await controller.load(VideoExportPlan(sourceURL: try await ColourClipWriter.clip()), in: view) { 0.5 }
        controller.setPaused(true, in: view)
        let item = try #require(controller.debugItem(in: view), "guard: nothing was loaded")
        let creations = controller.itemCreations

        let taken = controller.setLiveLook(FrameLook(preset: .mono), in: view)

        #expect(taken == VideoRenderFlags.usesSampleBufferLayer,
                "the sample-buffer backing takes a look live and the legacy one does not")
        guard taken else { return }
        #expect(controller.debugItem(in: view) === item, "the look brought a new item")
        #expect(controller.itemCreations == creations, "the look made an item")
        #expect(controller.isPaused(in: view) == true, "the look started the clip")
    }
}

/// **A REFRESHED READER DRAWS THE PAUSED MOMENT AGAIN.**
@Suite(.serialized, .exclusiveMediaWork)
struct ComposedFrameRefreshTests {
    typealias RGB = ColourClipWriter.RGB

    private func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 600).rounded()), timescale: 600)
    }

    private func composed(_ board: VideoLiveLook) async throws -> ComposedVideo {
        let file = try await ColourClipWriter.clip()
        let arrangement = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: [], orientation: .whenComposited, live: board
        )
        return try #require(arrangement.composed, "guard: a board did not compose the clip")
    }

    /// ⚠️ **TWENTY SECONDS, BECAUSE A FRESH READER HAS TAKEN THAT LONG** on a
    /// machine running several simulators; a reader that answers is never
    /// waited on longer than it takes.
    private func poll(
        _ reader: ComposedFrameReader, at seconds: Double, within limit: Double = 20
    ) async throws -> (buffer: CVPixelBuffer, time: CMTime)? {
        let deadline = CACurrentMediaTime() + limit
        while CACurrentMediaTime() < deadline {
            if let frame = reader.frame(at: time(seconds)) { return frame }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func colour(of buffer: CVPixelBuffer) -> RGB {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return RGB(r: -1, g: -1, b: -1)
        }
        let at = (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer)
            + (CVPixelBufferGetWidth(buffer) / 10) * 4
        return RGB(r: Int(base[at + 2]), g: Int(base[at + 1]), b: Int(base[at]))
    }

    /// ⚠️ **THE SAME MOMENT, HANDED AGAIN, FROM A NEW READ.** A frame is handed
    /// once; a refresh is what lets the paused moment be handed a second time —
    /// read after the change, so it wears it.
    @Test func aRefreshedReaderAnswersTheSameTimeAgain() async throws {
        let board = VideoLiveLook(.neutral)
        let reader = ComposedFrameReader(try await composed(board))
        defer { reader.close() }
        let first = try #require(try await poll(reader, at: 0.5), "guard: nothing answered 0.5s: \(reader.debugState)")
        #expect(colour(of: first.buffer).near(.red), "guard: 0.5s is not red: \(colour(of: first.buffer))")
        #expect(try await poll(reader, at: 0.5, within: 0.3) == nil, "guard: the frame was handed out twice")
        let generation = reader.debugState.generation

        board.set(FrameLook(preset: .mono))
        reader.refresh()

        let again = try #require(try await poll(reader, at: 0.5), "the refreshed moment was never handed out: \(reader.debugState)")
        #expect(again.time == first.time, "the refresh answered \(again.time.seconds)s for \(first.time.seconds)s")
        let grey = colour(of: again.buffer)
        #expect(abs(grey.r - grey.g) <= 16 && grey.r < 200, "the redrawn frame does not wear the look: \(grey)")
        #expect(reader.debugState.generation == generation + 1,
                "the refresh restarted the reader \(reader.debugState.generation - generation) times")
    }

    /// ⚠️ **A MOVING CLOCK IS NOT RESTARTED.** Its next frames are composed after
    /// the change anyway, and a restart under a playing clip is a decode from
    /// the keyframe — a stutter for every tick of a slider.
    @Test func aRefreshWhileTheClockMovesKeepsTheReader() async throws {
        let reader = ComposedFrameReader(try await composed(VideoLiveLook(.neutral)))
        defer { reader.close() }
        let first = try #require(try await poll(reader, at: 0.5), "guard: nothing answered 0.5s: \(reader.debugState)")
        let generation = reader.debugState.generation

        reader.refresh()
        var last = first.time
        for step in 1...4 {
            let next = try #require(
                try await poll(reader, at: 0.5 + Double(step) / 30), "the frame \(step) on never came: \(reader.debugState)"
            )
            #expect(next.time > last, "the frame \(step) on is not newer: \(next.time.seconds)s")
            last = next.time
        }

        #expect(reader.debugState.generation == generation,
                "a refresh under a moving clock restarted the reader")
    }
}
