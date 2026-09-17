import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **A TRANSITION IS DRAWN, EXPORTED AND PREVIEWED BY ONE BUILDER.**
///
/// Every assertion reads PIXELS or SAMPLES that AVFoundation produced from the
/// arrangement — through an image generator, an export or an audio reader —
/// never the instructions the builder wrote: a set of instructions can look
/// right and render black, or render and fail to export.
///
/// The clip (`ColourClipWriter`) is red, green, blue, white for a second each,
/// with a cyan square over its middle half and a yellow band along its top.
@Suite(.serialized)
struct TransitionCompositionTests {
    typealias RGB = ColourClipWriter.RGB
    // ⚠️ Scaled H.264 bleeds the red around the square into the cyan: measured
    // (74,253,253) where the square fills the frame, hence the wider slack.

    /// Red for a second, then blue for a second: the cut is at 1.0s, and a
    /// standard transition reaches a quarter second either side of it.
    private func cut(_ kind: VideoTransitionKind?) -> [VideoExportSegment] {
        [
            VideoExportSegment(start: 0, end: 1, transitionOut: kind),
            VideoExportSegment(start: 2, end: 3)
        ]
    }

    private func arranged(
        _ segments: [VideoExportSegment], rotated: Bool = false, shifted: Bool = true,
        sound: Bool = true, orientation: VideoExporter.OrientationRule = .whenComposited
    ) async throws -> VideoExporter.Arrangement {
        let file = try await ColourClipWriter.clip(rotated: rotated, shifted: shifted, sound: sound)
        return try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: segments, orientation: orientation
        )
    }

    private func pixel(
        _ arrangement: VideoExporter.Arrangement, at seconds: Double, x: Double = 0.1, y: Double = 0.5
    ) async throws -> (colour: RGB, actual: Double, size: CGSize) {
        try await ColourClipWriter.pixel(
            of: arrangement.asset, composition: arrangement.videoComposition, at: seconds, x: x, y: y
        )
    }

    // MARK: - The picture

    @Test func aFadeToBlackIsBlackAtTheCut() async throws {
        let dip = try await arranged(cut(.dipToBlack))

        let atTheCut = try await pixel(dip, at: 1.0).colour
        #expect(atTheCut.r <= 8 && atTheCut.g <= 8 && atTheCut.b <= 8, "the cut is \(atTheCut)")

        // Half way down: as bright as the ramp says at the frame actually drawn.
        let halfway = try await pixel(dip, at: 0.875)
        let opacity = max(0, min(1, (1.0 - halfway.actual) / 0.25))
        #expect(abs(Double(halfway.colour.r) - 255 * opacity) <= 25,
                "at \(halfway.actual)s the red is \(halfway.colour.r), the ramp says \(Int(255 * opacity))")

        #expect(try await pixel(dip, at: 0.5).colour.near(.red), "the fade reached back before its window")
        #expect(try await pixel(dip, at: 1.5).colour.near(.blue), "the fade ran on after its window")
    }

    @Test func aFadeToWhiteIsWhiteAtTheCut() async throws {
        let dip = try await arranged(cut(.dipToWhite))

        let atTheCut = try await pixel(dip, at: 1.0).colour
        #expect(atTheCut.r >= 247 && atTheCut.g >= 247 && atTheCut.b >= 247, "the cut is \(atTheCut)")
        #expect(try await pixel(dip, at: 0.5).colour.near(.red))
    }

    /// ⚠️ **THE ZOOM GOES THROUGH THE MIDDLE OF THE PICTURE.** At the cut the
    /// cyan square, which covers the middle half, fills the frame; before the
    /// window the edge is still the clip's own colour.
    @Test func aZoomFillsTheFrameAtTheCut() async throws {
        let zoom = try await arranged(cut(.zoom))

        let lastBefore = try await pixel(zoom, at: 1.0 - 1.0 / 30)
        #expect(lastBefore.colour.near(.cyan, by: 90), "a frame before the cut is not zoomed in: \(lastBefore)")
        let beforeTheWindow = try await pixel(zoom, at: 0.75 - 1.0 / 30)
        #expect(beforeTheWindow.colour.near(.red), "the zoom began before its window: \(beforeTheWindow)")
        let atTheCut = try await pixel(zoom, at: 1.0)
        #expect(atTheCut.colour.near(.cyan, by: 90), "the incoming piece is not zoomed out of: \(atTheCut)")
        let after = try await pixel(zoom, at: 1.5)
        #expect(after.colour.near(.blue), "the zoom ran on after its window: \(after)")
    }

    /// ⚠️ **TURNED FIRST, THEN ZOOMED** — about the middle of the UPRIGHT picture.
    @Test func aRotatedZoomStaysUpright() async throws {
        let zoom = try await arranged(cut(.zoom), rotated: true)

        let plain = try await pixel(zoom, at: 0.5, x: 0.5, y: 0.05)
        #expect(plain.size == CGSize(width: 120, height: 160), "the picture is not upright: \(plain.size)")
        #expect(plain.colour.near(.yellow), "the band is not along the top: \(plain.colour)")
        let atTheCut = try await pixel(zoom, at: 1.0, x: 0.5, y: 0.05)
        #expect(atTheCut.colour.near(.cyan, by: 90), "the zoom is not about the upright picture's middle: \(atTheCut)")
    }

    @Test func everyKindDrawsSomething() async throws {
        let plain = try await pixel(arranged(cut(nil)), at: 0.875, x: 0.2)
        #expect(plain.colour.near(.red), "guard: the plain cut is red there: \(plain.colour)")
        for kind in VideoTransitionKind.allCases {
            let drawn = try await pixel(arranged(cut(kind)), at: 0.875, x: 0.2).colour
            let moved = max(abs(drawn.r - plain.colour.r), abs(drawn.g - plain.colour.g), abs(drawn.b - plain.colour.b))
            #expect(moved > 40, "\(kind) draws the plain cut: \(drawn)")
        }
    }

    // MARK: - The structure

    /// ⚠️ **NOTHING DRAWN, NO COMPOSITOR** — the seams charter T12 measured stay
    /// exactly what they were.
    @Test func noTransitionAttachesNoVideoComposition() async throws {
        let plain = try await arranged(cut(nil), orientation: .always)

        #expect(plain.videoComposition == nil)
        #expect(plain.audioMix == nil)
        #expect(plain.windows.isEmpty)
        let track = try #require(try await plain.asset.loadTracks(withMediaType: .video).first as? AVCompositionTrack)
        let targets = track.segments.map { $0.timeMapping.target }
        #expect(targets.map(\.start.seconds) == [0, 1] && targets.map(\.end.seconds) == [1, 2], "got \(targets)")
    }

    @Test func theFadeTilesTheWholeCompositionAndExports() async throws {
        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter(preset: AVAssetExportPresetHighestQuality).export(
            VideoExportPlan(sourceURL: file, segments: cut(.dipToBlack))
        )
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }

        #expect(abs(exported.durationSeconds - 2) < 0.05, "the fade changed the length: \(exported.durationSeconds)")
        #expect(exported.transitionWindows == [0.75...1.25], "got \(exported.transitionWindows)")
        let atTheCut = try await ColourClipWriter.pixel(
            of: AVURLAsset(url: exported.fileURL), composition: nil, at: 1.0, x: 0.1
        ).colour
        #expect(atTheCut.r <= 16 && atTheCut.g <= 16 && atTheCut.b <= 16, "the export is not black at the cut: \(atTheCut)")
    }

    /// ⚠️ **THE CUT IS WHERE THE PIECES MEET IN PLAYED TIME** — two seconds of
    /// film at 2x end at one second, not two.
    @Test func aFadeOnARatedPieceSitsWhereTheTrackDrawsIt() async throws {
        let dip = try await arranged([
            VideoExportSegment(start: 0, end: 2, speed: 2, transitionOut: .dipToBlack),
            VideoExportSegment(start: 2, end: 3)
        ])

        #expect(dip.windows == [0.75...1.25], "got \(dip.windows)")
        let atTheCut = try await pixel(dip, at: 1.0).colour
        #expect(atTheCut.r <= 8 && atTheCut.g <= 8 && atTheCut.b <= 8, "the cut is \(atTheCut)")
    }

    /// ⚠️ **TWO WINDOWS AROUND A SHORT PIECE TOUCH AND NEVER CROSS** — crossing
    /// instructions fail the export.
    @Test func theWindowsTouchButNeverCross() async throws {
        let segments = [
            VideoExportSegment(start: 0, end: 2, transitionOut: .dipToBlack),
            VideoExportSegment(start: 2, end: 3.1, speed: 3, transitionOut: .dipToWhite),
            VideoExportSegment(start: 3.1, end: 4)
        ]
        let arrangement = try await arranged(segments)
        try #require(arrangement.windows.count == 2, "got \(arrangement.windows)")
        #expect(arrangement.windows[0].upperBound <= arrangement.windows[1].lowerBound + 0.000_001,
                "the windows cross: \(arrangement.windows)")

        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter(preset: AVAssetExportPresetHighestQuality).export(
            VideoExportPlan(sourceURL: file, segments: segments)
        )
        try? FileManager.default.removeItem(at: exported.fileURL)
    }

    @Test func aPassthroughPlanStillFades() async throws {
        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter().export(
            VideoExportPlan(sourceURL: file, segments: cut(.dipToBlack), preset: AVAssetExportPresetPassthrough)
        )
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }

        let asset = AVURLAsset(url: exported.fileURL)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let atTheCut = try await ColourClipWriter.pixel(of: asset, composition: nil, at: 1.0, x: 0.1).colour
        #expect(atTheCut.r <= 16 && atTheCut.g <= 16 && atTheCut.b <= 16,
                "passthrough dropped the fade: \(atTheCut)")
    }

    // MARK: - The sound

    private func loudness(_ arrangement: VideoExporter.Arrangement) async throws -> (Double) -> Double {
        let reader = try AVAssetReader(asset: arrangement.asset)
        let tracks = try await arrangement.asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.audioMix = arrangement.audioMix
        reader.add(output)
        reader.startReading()
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { values in
                samples.append(contentsOf: UnsafeBufferPointer(start: values, count: length / 2))
            }
        }
        return { centre in
            let from = max(Int((centre - 0.025) * 44_100), 0)
            let to = min(Int((centre + 0.025) * 44_100), samples.count)
            guard to > from else { return 0 }
            let energy = samples[from..<to].reduce(0.0) { $0 + Double($1) * Double($1) }
            return (energy / Double(to - from)).squareRoot()
        }
    }

    @Test func theSoundDipsWithThePicture() async throws {
        let dip = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dipToBlack),
            VideoExportSegment(start: 1, end: 1.9)
        ])
        let rms = try await loudness(dip)

        let full = rms(0.4)
        #expect(full > 5_000, "guard: the tone is not there: \(full)")
        #expect(rms(1.0) < full * 0.1, "the sound does not dip at the cut: \(rms(1.0)) of \(full)")
        #expect(rms(0.85) < full * 0.8, "the sound does not fall towards the cut: \(rms(0.85))")
        #expect(rms(1.5) > full * 0.8, "the sound does not come back: \(rms(1.5))")
    }

    /// ⚠️ **A RATED NEIGHBOUR DIPS THE PICTURE AND NOT THE SOUND** — a volume
    /// ramp over a rate change froze the export once in twelve.
    @Test func aRatedNeighbourDipsThePictureButNotTheSound() async throws {
        let dip = try await arranged([
            VideoExportSegment(start: 0, end: 2, transitionOut: .dipToBlack),
            VideoExportSegment(start: 2, end: 3.5, speed: 3)
        ])

        #expect(dip.audioMix == nil, "a ramp was laid over a rate change")
        let atTheCut = try await pixel(dip, at: 2.0).colour
        #expect(atTheCut.r <= 8 && atTheCut.g <= 8 && atTheCut.b <= 8, "the picture did not dip: \(atTheCut)")
    }

    @Test func aZoomLeavesTheSoundAlone() async throws {
        let zoom = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .zoom),
            VideoExportSegment(start: 1, end: 1.9)
        ])

        #expect(zoom.audioMix == nil)
    }

    // MARK: - Orientation

    @Test func aRotatedSourceIsComposedUpright() async throws {
        let file = try await ColourClipWriter.clip(rotated: true)
        let exported = try await VideoExporter(preset: AVAssetExportPresetHighestQuality).export(
            VideoExportPlan(sourceURL: file, segments: cut(.dipToBlack))
        )
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }

        let track = try #require(try await AVURLAsset(url: exported.fileURL).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        #expect(size == CGSize(width: 120, height: 160) && transform.isIdentity,
                "the export is not upright in its pixels: \(size) \(transform)")
        let top = try await ColourClipWriter.pixel(
            of: AVURLAsset(url: exported.fileURL), composition: nil, at: 0.5, x: 0.5, y: 0.05
        ).colour
        #expect(top.near(.yellow, by: 40), "the band is not along the top: \(top)")
    }

    /// ⚠️ **A TURN THAT CARRIES NO SHIFT OF ITS OWN.** A phone writes the
    /// translation that brings a turned picture back to the origin; not every
    /// file does, and a composition that trusted it would draw the picture off
    /// its own canvas — a black frame the size of the clip.
    @Test func aTurnWithoutItsOwnShiftIsStillOnTheCanvas() async throws {
        let upright = try await arranged([], rotated: true, shifted: false, orientation: .always)
        let composition = try #require(upright.videoComposition, "guard: a turned file was not composed")

        let top = try await ColourClipWriter.pixel(
            of: upright.asset, composition: composition, at: 0.5, x: 0.5, y: 0.05
        )
        let side = try await ColourClipWriter.pixel(
            of: upright.asset, composition: composition, at: 0.5, x: 0.1, y: 0.6
        )
        #expect(top.size == CGSize(width: 120, height: 160), "got \(top.size)")
        #expect(top.colour.near(.yellow, by: 40), "the band is not along the top: \(top.colour)")
        #expect(side.colour.near(.red), "the picture is off the canvas: \(side.colour)")
    }

    @MainActor
    @Test func aConfigurationBuiltCompositionCanBeAssignedToAPlayerItem() async throws {
        let dip = try await arranged(cut(.dipToBlack))
        let item = AVPlayerItem(asset: dip.asset)

        item.videoComposition = dip.videoComposition
        item.audioMix = dip.audioMix

        #expect(item.videoComposition != nil && item.audioMix != nil)
    }

    // MARK: - The poster

    @Test func posterSecondsAvoidTheWindows() {
        #expect(VideoExporter.posterSeconds(duration: 20, avoiding: []) == 1)
        #expect(VideoExporter.posterSeconds(duration: 4, avoiding: []) == 0.4)
        #expect(VideoExporter.posterSeconds(duration: 20, avoiding: [0.75...1.25]) == 1.25)
        #expect(VideoExporter.posterSeconds(duration: 20, avoiding: [1.5...2, 0.75...1.25]) == 1.25)
        // Where one window ends and the next begins, the picture is whole.
        #expect(VideoExporter.posterSeconds(duration: 20, avoiding: [0.75...1.25, 1.25...1.75]) == 1.25)
        #expect(VideoExporter.posterSeconds(duration: 20, avoiding: [0.75...1.25, 1.2...1.75]) == 1.75)
        #expect(VideoExporter.posterSeconds(duration: 1.2, avoiding: [0.05...1.2]) == 0)
        #expect(VideoExporter.posterSeconds(duration: 20, avoiding: [1...1.5]) == 1, "the window's own edge is clean")
    }

    /// ⚠️ **A DIP AT THE POSTER'S MOMENT DOES NOT PUBLISH A DARK THUMBNAIL.** Cut
    /// at half a second, the fade covers the moment a 3.5s clip's poster is
    /// taken from (a tenth of the way in).
    @Test func aPosterIsNeverTakenInsideATransition() async throws {
        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter(preset: AVAssetExportPresetHighestQuality).export(
            VideoExportPlan(sourceURL: file, segments: [
                VideoExportSegment(start: 0, end: 0.5, transitionOut: .dipToBlack),
                VideoExportSegment(start: 1, end: 4)
            ])
        )
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        try #require(exported.transitionWindows == [0.25...0.75], "got \(exported.transitionWindows)")

        let careless = try await ColourClipWriter.pixel(
            of: AVURLAsset(url: exported.fileURL), composition: nil, at: 0.35, x: 0.1
        ).colour
        #expect(max(careless.r, careless.g, careless.b) < 200,
                "guard: the default moment is not inside the fade: \(careless)")

        let poster = try #require(await VideoExporter().posterImage(for: exported)?.cgImage)
        var buffer = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(poster, in: CGRect(
            x: -CGFloat(poster.width) / 10, y: -CGFloat(poster.height) / 2,
            width: CGFloat(poster.width), height: CGFloat(poster.height)
        ))
        let colour = RGB(r: Int(buffer[0]), g: Int(buffer[1]), b: Int(buffer[2]))
        #expect(max(colour.r, colour.g, colour.b) >= 220, "the poster was taken inside the fade: \(colour)")
    }
}

/// **THE EDITOR'S PREVIEW IS HANDED WHAT THE EXPORT DRAWS.**
@MainActor
@Suite(.serialized)
struct TransitionPreviewTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func surface() -> VideoRenderView {
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        return view
    }

    private func controller() -> VideoPlaybackController {
        VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
    }

    private func item(
        loading segments: [VideoExportSegment], rotated: Bool = false
    ) async throws -> (AVPlayerItem, VideoPlaybackController, VideoRenderView, URL) {
        let controller = controller()
        let view = surface()
        let file = try await ColourClipWriter.clip(rotated: rotated)
        await controller.load(VideoExportPlan(sourceURL: file, segments: segments), in: view) { 0 }
        let item = try #require(controller.debugItem(in: view), "nothing was loaded")
        return (item, controller, view, file)
    }

    @Test func thePreviewDrawsTheTransitionTheExportDraws() async throws {
        let (item, controller, view, _) = try await item(loading: [
            VideoExportSegment(start: 0, end: 1, transitionOut: .dipToBlack),
            VideoExportSegment(start: 2, end: 3)
        ])
        defer { controller.stop(view) }

        let composition = try #require(item.videoComposition, "the preview item draws nothing")
        let atTheCut = try await ColourClipWriter.pixel(
            of: item.asset, composition: composition, at: 1.0, x: 0.1
        ).colour
        #expect(atTheCut.r <= 8 && atTheCut.g <= 8 && atTheCut.b <= 8, "the preview is not black at the cut")
        let mix = try #require(item.audioMix, "the preview item does not dip its sound")
        let owned = Set(try await item.asset.loadTracks(withMediaType: .audio).map(\.trackID))
        #expect(mix.inputParameters.allSatisfy { owned.contains($0.trackID) },
                "the mix names a track the item does not have")
    }

    /// ⚠️ **A COMPOSED ITEM HANDS THE RENDERER IOSURFACE FRAMES.** Without
    /// asking, the compositor's buffers came back with no IOSurface, and the
    /// sample-buffer layer froze on them while the renderer dispatched thirty a
    /// second — measured in the editor as a canvas that only moved at the dips.
    @Test func aComposedItemHandsTheRendererIOSurfaceFrames() async throws {
        for composed in [true, false] {
            let file = try await ColourClipWriter.clip()
            let arranged = try await VideoExporter.arrangement(
                of: AVURLAsset(url: file),
                cut: [
                    VideoExportSegment(start: 0, end: 1, transitionOut: composed ? .dipToBlack : nil),
                    VideoExportSegment(start: 2, end: 3)
                ],
                orientation: .always
            )
            #expect((arranged.videoComposition != nil) == composed, "guard: the arrangement is not what the case says")
            let item = AVPlayerItem(asset: arranged.asset)
            item.videoComposition = arranged.videoComposition
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            let source = VideoFrameSource(player: player)
            source.setItem(item)
            player.play()
            var frames = 0
            var backed = 0
            for _ in 0..<150 where frames < 10 {
                try await Task.sleep(for: .milliseconds(10))
                guard let frame = source.copyFrame(atHostTime: CACurrentMediaTime()) else { continue }
                frames += 1
                if CVPixelBufferGetIOSurface(frame.buffer) != nil { backed += 1 }
            }
            player.pause()
            #expect(frames > 3, "guard: no frames came out (composed: \(composed))")
            #expect(backed == frames, "\(frames - backed) of \(frames) frames had no IOSurface (composed: \(composed))")
        }
    }

    @Test func aRotatedUntouchedFileIsComposedUpright() async throws {
        let (item, controller, view, _) = try await item(loading: [], rotated: true)
        defer { controller.stop(view) }

        let composition = try #require(item.videoComposition, "a turned file plays on its side")
        #expect(composition.renderSize == CGSize(width: 120, height: 160), "got \(composition.renderSize)")
    }

    @Test func anIdentityUntouchedFileHasNoComposition() async throws {
        let (item, controller, view, _) = try await item(loading: [])
        defer { controller.stop(view) }

        #expect(item.videoComposition == nil, "an upright file went through a compositor")
    }

    @Test func aRotatedArrangementWithoutATransitionIsUprightToo() async throws {
        let (item, controller, view, _) = try await item(loading: [
            VideoExportSegment(start: 0, end: 1), VideoExportSegment(start: 2, end: 3)
        ], rotated: true)
        defer { controller.stop(view) }

        #expect(item.videoComposition?.renderSize == CGSize(width: 120, height: 160),
                "a cut turned file plays on its side")
    }

    /// ⚠️ **A HELD HANDLE SHOWS THE FILE UPRIGHT TOO** — or every grab would turn
    /// the canvas on its side.
    @Test func showingARotatedFileAsShotStaysUpright() async throws {
        let (_, controller, view, file) = try await item(loading: [
            VideoExportSegment(start: 0, end: 1), VideoExportSegment(start: 2, end: 3)
        ], rotated: true)
        defer { controller.stop(view) }

        #expect(controller.showAsShot(file, in: view, at: 0.5))
        let shown = try #require(controller.debugItem(in: view))
        #expect(shown.videoComposition?.renderSize == CGSize(width: 120, height: 160),
                "the file as shot is on its side")
    }
}
