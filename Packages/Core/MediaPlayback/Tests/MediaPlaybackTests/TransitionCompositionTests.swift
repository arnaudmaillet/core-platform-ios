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
///
/// ⚠️ **THE DEFAULT LANE ONLY.** Nothing here goes through the canvas's layer
/// — pictures come from an image generator or an export, sound from a reader —
/// so the legacy lane would do the same work twice beside its real-time
/// suites (memory `parallel-suite-starvation`). `TransitionPreviewTests`,
/// which loads the controller, runs in both.
@Suite(.serialized, .enabled(if: VideoRenderFlags.usesSampleBufferLayer), .exclusiveMediaWork)
struct TransitionCompositionTests {
    typealias RGB = ColourClipWriter.RGB
    // ⚠️ Scaled H.264 bleeds the red around the square into the cyan: measured
    // (74,253,253) where the square fills the frame, hence the wider slack.

    /// Red for a second, then blue for a second, overlapping by the standard
    /// half second: the window is [0.5, 1.0), its middle — where a dip or a
    /// zoom changes piece — is 0.75s, and the result lasts 1.5s.
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

    @Test func aFadeToBlackIsBlackAtTheMiddle() async throws {
        let dip = try await arranged(cut(.dipToBlack))

        let atTheMiddle = try await pixel(dip, at: 0.75).colour
        #expect(atTheMiddle.r <= 8 && atTheMiddle.g <= 8 && atTheMiddle.b <= 8, "the middle is \(atTheMiddle)")

        // Half way down: as bright as the ramp says at the frame actually drawn.
        let halfway = try await pixel(dip, at: 0.625)
        let opacity = max(0, min(1, (0.75 - halfway.actual) / 0.25))
        #expect(abs(Double(halfway.colour.r) - 255 * opacity) <= 25,
                "at \(halfway.actual)s the red is \(halfway.colour.r), the ramp says \(Int(255 * opacity))")
        // ⚠️ AND IT COMES BACK UP ON THE INCOMING PIECE: both play through the
        // whole overlap, so a dip that kept the outgoing one past the middle
        // would fade red back in.
        let rising = try await pixel(dip, at: 0.875).colour
        #expect(rising.b > rising.r + 60, "the fade does not come back up on the incoming piece: \(rising)")

        #expect(try await pixel(dip, at: 0.3).colour.near(.red), "the fade reached back before its window")
        #expect(try await pixel(dip, at: 1.2).colour.near(.blue), "the fade ran on after its window")
    }

    @Test func aFadeToWhiteIsWhiteAtTheMiddle() async throws {
        let dip = try await arranged(cut(.dipToWhite))

        let atTheMiddle = try await pixel(dip, at: 0.75).colour
        #expect(atTheMiddle.r >= 247 && atTheMiddle.g >= 247 && atTheMiddle.b >= 247, "the middle is \(atTheMiddle)")
        #expect(try await pixel(dip, at: 0.3).colour.near(.red))
    }

    /// ⚠️ **THE ZOOM GOES THROUGH THE MIDDLE OF THE PICTURE.** At the middle of
    /// the window the cyan square, which covers the middle half, fills the
    /// frame; before the window the edge is still the clip's own colour.
    @Test func aZoomFillsTheFrameAtTheMiddle() async throws {
        let zoom = try await arranged(cut(.zoom))

        let lastBefore = try await pixel(zoom, at: 0.75 - 1.0 / 30)
        #expect(lastBefore.colour.near(.cyan, by: 90), "a frame before the middle is not zoomed in: \(lastBefore)")
        let beforeTheWindow = try await pixel(zoom, at: 0.5 - 1.0 / 30)
        #expect(beforeTheWindow.colour.near(.red), "the zoom began before its window: \(beforeTheWindow)")
        let atTheMiddle = try await pixel(zoom, at: 0.75)
        #expect(atTheMiddle.colour.near(.cyan, by: 90), "the incoming piece is not zoomed out of: \(atTheMiddle)")
        let after = try await pixel(zoom, at: 1.2)
        #expect(after.colour.near(.blue), "the zoom ran on after its window: \(after)")
    }

    /// ⚠️ **TURNED FIRST, THEN ZOOMED** — about the middle of the UPRIGHT picture.
    @Test func aRotatedZoomStaysUpright() async throws {
        let zoom = try await arranged(cut(.zoom), rotated: true)

        let plain = try await pixel(zoom, at: 0.3, x: 0.5, y: 0.05)
        #expect(plain.size == CGSize(width: 120, height: 160), "the picture is not upright: \(plain.size)")
        #expect(plain.colour.near(.yellow), "the band is not along the top: \(plain.colour)")
        let atTheMiddle = try await pixel(zoom, at: 0.75, x: 0.5, y: 0.05)
        #expect(atTheMiddle.colour.near(.cyan, by: 90), "the zoom is not about the upright picture's middle: \(atTheMiddle)")
    }

    /// ⚠️ **SAMPLED ACROSS THE WINDOW AND ACROSS THE FRAME.** A swipe or a
    /// page curl has not reached every point at every moment — one point at one
    /// time says nothing about them. What every kind must do is change the
    /// picture SOMEWHERE inside its window.
    @Test func everyKindDrawsSomething() async throws {
        let times = [0.55, 0.65, 0.75, 0.85, 0.95]
        let points = [0.1, 0.3, 0.5, 0.7, 0.9]
        let plain = try await arranged(cut(nil))
        var reference: [ColourClipWriter.RGB] = []
        for time in times {
            for point in points {
                reference.append(try await pixel(plain, at: time, x: point, y: point).colour)
            }
        }
        for kind in VideoTransitionKind.allCases {
            let drawn = try await arranged(cut(kind))
            var moved = 0
            var index = 0
            for time in times {
                for point in points {
                    let colour = try await pixel(drawn, at: time, x: point, y: point).colour
                    let was = reference[index]
                    index += 1
                    moved = max(moved, abs(colour.r - was.r), abs(colour.g - was.g), abs(colour.b - was.b))
                }
            }
            #expect(moved > 40, "\(kind) draws the plain cut everywhere (moved \(moved))")
        }
    }

    // MARK: - The structure

    /// ⚠️ **NOTHING DRAWN, NO COMPOSITOR — AND NO SECOND LANE.** Plain cuts
    /// overlap nothing, so the pieces follow each other on one track, and the
    /// seams charter T12 measured stay exactly what they were.
    @Test func noTransitionAttachesNoVideoComposition() async throws {
        let plain = try await arranged(cut(nil), orientation: .always)

        #expect(plain.videoComposition == nil)
        #expect(plain.audioMix == nil)
        #expect(plain.windows.isEmpty)
        let tracks = try await plain.asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1, "a plain cut laid \(tracks.count) video lanes")
        let track = try #require(tracks.first as? AVCompositionTrack)
        let targets = track.segments.map { $0.timeMapping.target }
        #expect(targets.map(\.start.seconds) == [0, 1] && targets.map(\.end.seconds) == [1, 2], "got \(targets)")
    }

    @Test func theFadeTilesTheWholeCompositionAndExports() async throws {
        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter(preset: AVAssetExportPresetHighestQuality).export(
            VideoExportPlan(sourceURL: file, segments: cut(.dipToBlack))
        )
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }

        #expect(abs(exported.durationSeconds - 1.5) < 0.05, "the fade is not its pieces less the overlap: \(exported.durationSeconds)")
        #expect(exported.transitionWindows == [0.5...1.0], "got \(exported.transitionWindows)")
        let atTheMiddle = try await ColourClipWriter.pixel(
            of: AVURLAsset(url: exported.fileURL), composition: nil, at: 0.75, x: 0.1
        ).colour
        #expect(atTheMiddle.r <= 16 && atTheMiddle.g <= 16 && atTheMiddle.b <= 16,
                "the export is not black at the middle: \(atTheMiddle)")
    }

    /// ⚠️ **THE WINDOW IS WHERE THE PIECES OVERLAP IN PLAYED TIME** — two
    /// seconds of film at 2x end at one second, not two.
    @Test func aFadeOnARatedPieceSitsWhereTheTrackDrawsIt() async throws {
        let dip = try await arranged([
            VideoExportSegment(start: 0, end: 2, speed: 2, transitionOut: .dipToBlack),
            VideoExportSegment(start: 2, end: 3)
        ])

        #expect(dip.windows == [0.5...1.0], "got \(dip.windows)")
        let atTheMiddle = try await pixel(dip, at: 0.75).colour
        #expect(atTheMiddle.r <= 8 && atTheMiddle.g <= 8 && atTheMiddle.b <= 8, "the middle is \(atTheMiddle)")
    }

    /// ⚠️ **TWO WINDOWS AROUND A SHORT PIECE TOUCH AND NEVER CROSS** — crossing
    /// windows would ask for three pictures on two lanes, and crossing
    /// instructions fail the export. A piece played 0.367s gives each side at
    /// most half of itself: 0.183s either way, so the two windows meet.
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
        let atTheMiddle = try await ColourClipWriter.pixel(of: asset, composition: nil, at: 0.75, x: 0.1).colour
        #expect(atTheMiddle.r <= 16 && atTheMiddle.g <= 16 && atTheMiddle.b <= 16,
                "passthrough dropped the fade: \(atTheMiddle)")
    }

    // MARK: - The sound

    /// Each lane's sound as the mix leaves it, heard on its own: the outgoing
    /// piece's lane and the incoming one's, in track order.
    private func lanes(_ arrangement: VideoExporter.Arrangement) async throws -> [SoundProbe] {
        let tracks = try await arrangement.asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var heard: [SoundProbe] = []
        for track in tracks {
            heard.append(try await SoundProbe.listen(to: arrangement.asset, tracks: [track], mix: arrangement.audioMix))
        }
        return heard
    }

    /// ⚠️ **THE TWO SOUNDS CROSS OVER THE WHOLE OVERLAP**, the outgoing one down
    /// as the incoming one comes up, each at its own place in its own piece.
    /// Heard lane by lane, since the clip's one tone sounds the same from both:
    /// mixed, the two could cancel or add and say nothing about either level.
    @Test func aDissolveCrossesTheTwoSounds() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 1, end: 2)
        ])
        let heard = try await lanes(dissolve)
        try #require(heard.count == 2, "guard: \(heard.count) lanes of sound")
        let (outgoing, incoming) = (heard[0], heard[1])

        let full = outgoing.rms(at: 0.3)
        #expect(full > 5_000, "guard: the tone is not there: \(full)")
        #expect(incoming.rms(at: 0.3) < full * 0.02, "the incoming sound plays before the window: \(incoming.rms(at: 0.3))")
        // ⚠️ AND DOES NOT BURST IN WHERE IT OPENS: a ramp laid on a track's
        // first sample took hold only ~25ms in, measured at full volume until
        // then — so the lane is silenced before the piece arrives.
        #expect(incoming.rms(at: 0.51, width: 0.02) < full * 0.1,
                "the incoming sound bursts in where the window opens: \(incoming.rms(at: 0.51, width: 0.02)) of \(full)")
        for (time, share) in [(0.625, 0.25), (0.75, 0.5), (0.875, 0.75)] {
            #expect(abs(outgoing.rms(at: time) / full - (1 - share)) < 0.1,
                    "at \(time)s the outgoing sound is \(outgoing.rms(at: time) / full) of full, not \(1 - share)")
            #expect(abs(incoming.rms(at: time) / full - share) < 0.1,
                    "at \(time)s the incoming sound is \(incoming.rms(at: time) / full) of full, not \(share)")
        }
        #expect(outgoing.rms(at: 1.2) < full * 0.02, "the outgoing sound plays after the window: \(outgoing.rms(at: 1.2))")
        #expect(incoming.rms(at: 1.2) > full * 0.9, "the incoming sound does not come up: \(incoming.rms(at: 1.2))")
    }

    /// A dip takes the sound through silence with its picture: the outgoing
    /// sound down to nothing by the middle, the incoming one up from it.
    @Test func theSoundDipsWithThePicture() async throws {
        let dip = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dipToBlack),
            VideoExportSegment(start: 1, end: 2)
        ])
        let rms = try await SoundProbe.listen(to: dip.asset, mix: dip.audioMix)

        let full = rms.rms(at: 0.3)
        #expect(full > 5_000, "guard: the tone is not there: \(full)")
        #expect(rms.rms(at: 0.75) < full * 0.1, "the sound does not dip at the middle: \(rms.rms(at: 0.75)) of \(full)")
        #expect(rms.rms(at: 0.6) < full * 0.8, "the sound does not fall towards the middle: \(rms.rms(at: 0.6))")
        #expect(rms.rms(at: 1.2) > full * 0.8, "the sound does not come back: \(rms.rms(at: 1.2))")
    }

    /// ⚠️ **NEXT TO A RATED PIECE THE SOUNDS DO NOT CROSS — THEY ARE CUT AT THE
    /// MIDDLE OF THE OVERLAP.** A volume ramp over a rate change froze the export
    /// once in twelve (memory `export-volume-ramp-hang`), so the outgoing sound
    /// is laid up to the middle and the incoming one from it: an edit, no mix at
    /// all, each sound still under its own picture, the rated one on a track of
    /// its own. Half a second at 1x, then a second and a half at 3x: they overlap
    /// by a quarter second, [0.25, 0.5), and the sound changes piece at 0.375s.
    /// Heard both ways round with the clip's tone on one side only — its first
    /// two seconds sound, the rest is silent — so each side can be told apart.
    @Test func aRatedNeighbourCutsTheTwoSoundsAtTheMiddle() async throws {
        let toneFirst = try await arranged([
            VideoExportSegment(start: 1.5, end: 2, transitionOut: .dipToBlack),
            VideoExportSegment(start: 2, end: 3.5, speed: 3)
        ])
        let toneAfter = try await arranged([
            VideoExportSegment(start: 2.5, end: 3, transitionOut: .dipToBlack),
            VideoExportSegment(start: 0, end: 1.5, speed: 3)
        ])

        for dip in [toneFirst, toneAfter] {
            #expect(dip.audioMix == nil, "a ramp was laid over a rate change")
            try #require(dip.windows == [0.25...0.5], "guard: the window is \(dip.windows)")
            let tracks = try await dip.asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count == 2, "guard: \(tracks.count) tracks of sound")
        }
        let atTheMiddle = try await pixel(toneFirst, at: 0.375).colour
        #expect(atTheMiddle.r <= 8 && atTheMiddle.g <= 8 && atTheMiddle.b <= 8, "the picture did not dip: \(atTheMiddle)")
        let outgoing = try await SoundProbe.listen(to: toneFirst.asset, mix: nil)
        let incoming = try await SoundProbe.listen(to: toneAfter.asset, mix: nil)
        let full = outgoing.rms(at: 0.1)
        #expect(full > 5_000, "guard: the tone is not there: \(full)")
        #expect(outgoing.rms(at: 0.33) > full * 0.9 && incoming.rms(at: 0.33) < full * 0.02,
                "before the middle the outgoing sound alone is heard: \(outgoing.rms(at: 0.33)), \(incoming.rms(at: 0.33))")
        #expect(outgoing.rms(at: 0.42) < full * 0.02 && incoming.rms(at: 0.42) > full * 0.5,
                "after the middle the incoming sound alone is heard: \(outgoing.rms(at: 0.42)), \(incoming.rms(at: 0.42))")
    }

    /// ⚠️ **A RATED PIECE'S SOUND HAS A TRACK OF ITS OWN, EMPTY UP TO IT.** Laid
    /// on its picture's lane, after the first piece's sound and a gap, a 3x
    /// piece's sound played SILENT when this ran beside two other suites: the
    /// log said `AppendRateChange: scheduling rate change at unscaled t=60638,
    /// but we previously did a conversion for t=64512` — 60638 samples is
    /// 1.375s, where the piece's sound begins, and the line the export freeze
    /// of `export-volume-ramp-hang` left. A 3x piece laid end to end after
    /// 0.375s of its neighbour's sound was silent in 4 exports of 12. On a
    /// track where nothing plays before its rate is set, in none of 12, in
    /// every shape measured (`VideoExporter.insertPieces`). A
    /// second, a second, and a second and a half of tone at 3x: they overlap by
    /// half a second, then a quarter; the dip into the 3x piece does not cross,
    /// and its sound runs from the middle of that overlap, 1.375s, to the end,
    /// 1.75s — and is heard.
    @Test func aRatedSoundHasATrackOfItsOwn() async throws {
        let arranged = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 1, end: 2, transitionOut: .dipToBlack),
            VideoExportSegment(start: 0, end: 1.5, speed: 3)
        ])
        try #require(arranged.windows == [0.5...1.0, 1.25...1.5], "guard: the windows are \(arranged.windows)")
        let tracks = try await arranged.asset.loadTracks(withMediaType: .audio)
            .compactMap { $0 as? AVCompositionTrack }
        let laid = tracks.map { $0.segments.map { ($0.isEmpty, $0.timeMapping.target) } }
        let own = try #require(laid.first { $0.contains { !$0.0 && abs($0.1.start.seconds - 1.375) < 0.001 } },
                               "the rated sound is not laid at 1.375s: \(laid)")
        #expect(own.filter { !$0.0 }.count == 1, "the rated sound shares its track: \(own)")
        let heard = try await SoundProbe.listen(to: arranged.asset, mix: arranged.audioMix)
        let full = heard.rms(at: 0.3)
        #expect(full > 5_000, "guard: the tone is not there: \(full)")
        #expect(heard.rms(at: 1.6) > full * 0.5, "the rated piece is silent: \(heard.rms(at: 1.6)) of \(full)")
    }

    /// ⚠️ **A SOUND CUT NEXT TO A RATED PIECE IS CUT TO THE TICK, AND A PIECE AS
    /// SHOT IS NEVER SCALED.** Found by review: the trims went back through
    /// `CMTime(seconds:preferredTimescale:)`, which truncates — 55/600 of a
    /// second came back as 54/600 — so where an overlap is clamped by a rated
    /// neighbour's half, a piece as shot heard a tick more film than it plays
    /// for, and its sound became a scaled edit on a shared lane, under the ramp
    /// of the crossfade it arrived through.
    ///
    /// The review's plan, on the ten-second clip, in 1/600ths: P0 [0, 2)
    /// dissolves into A [2, 5), which dips into R [5, 6.47) at 4x — 220 ticks
    /// played, so their overlap is half of it floored, 109, and the sound
    /// changes piece at its middle, 2645 — then R into B [6.47, 9), overlapping
    /// by 109 again, the sound changing at 2756. A's sound is the file's
    /// [1200, 2945) over [900, 2645); B's is [3936, 5400) from 2756.
    @Test func aSoundCutNextToARatedPieceIsCutToTheTick() async throws {
        let file = try await TimecodeClipWriter.clip()
        let arranged = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file),
            cut: [
                VideoExportSegment(start: 0, end: 2, transitionOut: .dissolve),
                VideoExportSegment(start: 2, end: 5, transitionOut: .dipToBlack),
                VideoExportSegment(start: 5, end: 6.47, speed: 4, transitionOut: .dissolve),
                VideoExportSegment(start: 6.47, end: 9)
            ],
            orientation: .whenComposited
        )
        func ticks(_ time: CMTime) -> Int64 { CMTimeConvertScale(time, timescale: 600, method: .roundHalfAwayFromZero).value }
        // ⚠️ PLAIN RANGES AND ONE STEP AT A TIME: key paths through tuples in an
        // `#expect` took 170ms to type-check here, over CI's 60.
        struct Edit: CustomStringConvertible {
            let track: CMPersistentTrackID
            let source: ClosedRange<Int64>
            let target: ClosedRange<Int64>
            var scaled: Bool { source.upperBound - source.lowerBound != target.upperBound - target.lowerBound }
            var description: String { "\(track): \(source) -> \(target)" }
        }
        let tracks = try await arranged.asset.loadTracks(withMediaType: .audio).compactMap { $0 as? AVCompositionTrack }
        var edits: [Edit] = []
        for track in tracks {
            for segment in track.segments where !segment.isEmpty {
                let mapping = segment.timeMapping
                edits.append(Edit(
                    track: track.trackID,
                    source: ticks(mapping.source.start)...ticks(mapping.source.end),
                    target: ticks(mapping.target.start)...ticks(mapping.target.end)
                ))
            }
        }
        try #require(edits.count == 4, "guard: \(edits)")
        let scaled: [Edit] = edits.filter { $0.scaled }
        let scaledStarts: [Int64] = scaled.map { $0.target.lowerBound }
        #expect(scaledStarts == [2645], "only the 4x sound is scaled: \(edits)")
        for edit in scaled {
            let sharing: Int = edits.filter { $0.track == edit.track }.count
            #expect(sharing == 1, "a scaled sound shares its track: \(edits)")
        }
        let dissolving: Bool = edits.contains { $0.source == 1200...2945 && $0.target == 900...2645 }
        #expect(dissolving, "the dissolving piece's sound is not cut at the middle of its overlap, to the tick: \(edits)")
        let last: Bool = edits.contains { $0.source == 3936...5400 && $0.target == 2756...4220 }
        #expect(last, "the last piece's sound does not start at the middle of its overlap, to the tick: \(edits)")
    }

    /// Every kind but the dips crosses the two sounds, the zoom included.
    @Test func aZoomCrossesTheSoundToo() async throws {
        let zoom = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .zoom),
            VideoExportSegment(start: 1, end: 1.9)
        ])

        #expect(zoom.audioMix != nil, "the zoom's two sounds do not cross")
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
            of: AVURLAsset(url: exported.fileURL), composition: nil, at: 0.3, x: 0.5, y: 0.05
        ).colour
        #expect(top.near(.yellow, by: 40), "the band is not along the top: \(top)")
    }

    /// ⚠️ **A CAPPED PREVIEW IS SMALLER AND STILL THE SAME PICTURE.** The
    /// canvas composes at most `previewLongestSide`; the turn and the shrink
    /// must compose in the right order, or the picture lands off the canvas.
    @Test func aCappedCanvasIsSmallerAndStillUpright() async throws {
        let file = try await ColourClipWriter.clip(rotated: true)
        let capped = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: cut(.dipToBlack), orientation: .always, longestSide: 80
        )
        let composition = try #require(capped.videoComposition)
        #expect(composition.renderSize == CGSize(width: 60, height: 80), "got \(composition.renderSize)")
        let top = try await ColourClipWriter.pixel(
            of: capped.asset, composition: composition, at: 0.3, x: 0.5, y: 0.05
        )
        #expect(top.size == CGSize(width: 60, height: 80), "guard: read at \(top.size)")
        #expect(top.colour.near(.yellow, by: 60), "the band is not along the top: \(top.colour)")
        let side = try await ColourClipWriter.pixel(
            of: capped.asset, composition: composition, at: 0.3, x: 0.1, y: 0.6
        )
        #expect(side.colour.near(.red), "the picture is off the canvas: \(side.colour)")
        let square = try await ColourClipWriter.pixel(
            of: capped.asset, composition: composition, at: 0.3, x: 0.5, y: 0.5
        )
        #expect(square.colour.near(.cyan, by: 90), "the middle is not the square: \(square.colour)")
        // Never scaled up.
        let small = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: cut(.dipToBlack), orientation: .always, longestSide: 4000
        )
        #expect(small.videoComposition?.renderSize == CGSize(width: 120, height: 160))
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

    /// ⚠️ **A DIP AT THE POSTER'S MOMENT DOES NOT PUBLISH A DARK THUMBNAIL.** Half
    /// a second then three, overlapping by a quarter second: the fade, over
    /// [0.25, 0.5), covers the moment a 3.25s clip's poster is taken from (a
    /// tenth of the way in).
    @Test func aPosterIsNeverTakenInsideATransition() async throws {
        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter(preset: AVAssetExportPresetHighestQuality).export(
            VideoExportPlan(sourceURL: file, segments: [
                VideoExportSegment(start: 0, end: 0.5, transitionOut: .dipToBlack),
                VideoExportSegment(start: 1, end: 4)
            ])
        )
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        try #require(exported.transitionWindows == [0.25...0.5], "got \(exported.transitionWindows)")

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
@Suite(.serialized, .exclusiveMediaWork)
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

        let composition = try #require(controller.debugComposition(in: view), "the preview item draws nothing")
        let atTheMiddle = try await ColourClipWriter.pixel(
            of: item.asset, composition: composition, at: 0.75, x: 0.1
        ).colour
        #expect(atTheMiddle.r <= 8 && atTheMiddle.g <= 8 && atTheMiddle.b <= 8, "the preview is not black at the middle of the overlap")
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
            // ⚠️ THE ITEM STAYS PLAIN AND THE SOURCE COMPOSES, as the controller
            // does it — an item carrying the composition fails outright on the
            // iOS 27 simulator.
            let item = AVPlayerItem(asset: arranged.asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            let source = VideoFrameSource(player: player)
            source.setItem(item, composing: arranged.composed)
            player.play()
            var frames = 0
            var backed = 0
            // ⚠️ SIX SECONDS, NOT ONE AND A HALF: a composed reader's first frame
            // waits for a decode from the keyframe, and with other suites
            // exporting alongside it that took longer than 1.5s.
            for _ in 0..<600 where frames < 10 {
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

        let composition = try #require(controller.debugComposition(in: view), "a turned file plays on its side")
        #expect(composition.renderSize == CGSize(width: 120, height: 160), "got \(composition.renderSize)")
    }

    /// ⚠️ **AN UNTOUCHED UPRIGHT FILE IS COMPOSED TOO, SO A LOOK CAN REACH IT
    /// LIVE.** Played plain, it would have no compositor to hand the author's
    /// first filter to (`LiveLookTests`). The legacy layer path, which would hand
    /// the composition to its item, still plays it plain.
    @Test func anIdentityUntouchedFileIsComposedForItsLiveLook() async throws {
        let (_, controller, view, _) = try await item(loading: [])
        defer { controller.stop(view) }

        let composition = controller.debugComposition(in: view)
        if VideoRenderFlags.usesSampleBufferLayer {
            #expect(composition?.renderSize == CGSize(width: 160, height: 120),
                    "an upright file has no compositor for its look: \(String(describing: composition?.renderSize))")
        } else {
            #expect(composition == nil, "an upright file went through a compositor on the layer path")
        }
    }

    @Test func aRotatedArrangementWithoutATransitionIsUprightToo() async throws {
        let (item, controller, view, _) = try await item(loading: [
            VideoExportSegment(start: 0, end: 1), VideoExportSegment(start: 2, end: 3)
        ], rotated: true)
        defer { controller.stop(view) }

        #expect(controller.debugComposition(in: view)?.renderSize == CGSize(width: 120, height: 160),
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
        #expect(controller.debugComposition(in: view)?.renderSize == CGSize(width: 120, height: 160),
                "the file as shot is on its side")
    }
}
