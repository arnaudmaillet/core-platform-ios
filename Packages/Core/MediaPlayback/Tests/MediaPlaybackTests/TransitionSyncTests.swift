import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **BOTH PICTURES OF A TRANSITION ARE AT THE SAME MOMENT OF THE FILE AS THEIR
/// OWN SOUND — ON THE EDITOR'S CANVAS AND IN THE FILE THAT IS PUBLISHED.**
///
/// A transition overlaps its two pieces (`VideoExporter.insertPieces`): each
/// plays on its own lane, picture and sound together, the outgoing one's last
/// `d` seconds under the incoming one's first. An earlier version eased moving
/// film across the window on the video lanes only, and put the pictures up to
/// 250ms off their words; a lane whose sound is laid a head or a tail away from
/// its picture would do the same. So each lane's picture is held to that
/// lane's own sound, at every frame of the window.
///
/// ⚠️ **BOTH SIDES READ OFF WHAT WAS MADE, NOT OFF THE BUILDER.** The clip
/// (`TimecodeClipWriter`) lights one cell per frame of the file and plays a
/// sine whose pitch is its clock. The PICTURES are read from the frames the
/// preview composes (the controller's own composition, read as
/// `ComposedFrameReader` reads it), the export's composition composes, or the
/// written file holds: each lit cell is a frame of the file, as bright as its
/// share of the blend. The SOUND is read, as its pitch, from the same asset:
/// each lane's audio track on its own where the two can be told apart — the
/// canvas's item and the export's composition — and the file's one mixed
/// track, where only the louder sound can be heard, as it is.
///
/// ⚠️ **A SPLIT OF ONE SHOT**, [0.5, 5) then [5, 9.5), overlapping by `d`: the
/// window is [4.5 − d, 4.5), the outgoing piece plays the file's second
/// `t + 0.5` at every moment `t` and the incoming one `t + 0.5 + d` — which the
/// test checks of the sound too, before it trusts it. Once more with the
/// incoming piece at 2x, where the two sounds do not cross but are cut at the
/// middle of the overlap (`export-volume-ramp-hang`), through the file, whose
/// time-pitch pass is the one a rate goes through on its way out.
///
/// ⚠️ **NOT ON THE MAIN ACTOR** — `TransitionVisibilityTests`' reason; only
/// `canvas` hops there, for the controller.
/// ⚠️ **THE DEFAULT LANE ONLY.** The pictures read here are the COMPOSITION's
/// and the export's, and neither depends on which layer draws the canvas — so
/// the legacy lane would read the very same frames a second time. It was
/// already the slowest lane (203s on develop's CI), and these suites running
/// beside its real-time ones pushed `RehearsalLoopTests` past its range.
/// `CompositorFinishTests` is gated the same way.
@Suite(.serialized, .enabled(if: VideoRenderFlags.usesSampleBufferLayer), .exclusiveMediaWork)
struct TransitionSyncTests {
    struct Cell: Sendable {
        let frame: Int
        let level: Int
    }

    /// One composed frame: when, and its two brightest cells, brightest first.
    struct Picture: Sendable {
        let time: Double
        let cells: [Cell]
    }

    private static let frame = 1.0 / 30

    /// One reading: from where, how long a transition was asked, and the rate
    /// the incoming piece plays at.
    struct Case: Sendable, CustomTestStringConvertible {
        let source: Source
        let seconds: Double
        var rate: Double = 1

        var testDescription: String { "\(source) \(seconds)s into \(rate)x" }

        var segments: [VideoExportSegment] {
            [
                VideoExportSegment(start: 0.5, end: 5, transitionOut: .dissolve, transitionSeconds: seconds),
                VideoExportSegment(start: 5, end: 9.5, speed: rate)
            ]
        }

        /// How long the two pieces overlap: what was asked, within half of
        /// each (`VideoExporter.transitionOverlap`).
        var overlap: Double { min(seconds, 4.5 / 2, 4.5 / rate / 2) }
    }

    /// Where the pictures and the sound are read from.
    enum Source: String, Sendable {
        /// The item the canvas plays and the composition drawn over it.
        case preview
        /// The composition and mix `VideoExporter.export` hands its session.
        case export
        /// The file the export writes — the encode included.
        case file
    }

    /// The pictures in `[from, to)`, and the sound: one probe per lane, or the
    /// file's one mixed track.
    private static func measure(
        _ segments: [VideoExportSegment], file: URL, source: Source, from: Double, to: Double
    ) async throws -> (pictures: [Picture], sounds: [SoundProbe]) {
        let read: @Sendable (CVPixelBuffer, Double) -> Picture = { buffer, time in
            Picture(time: time, cells: TimecodeClipWriter.litCells(in: buffer).map { Cell(frame: $0.frame, level: $0.level) })
        }
        switch source {
        case .preview:
            return try await canvas(segments, file: file, from: from, to: to, read: read)
        case .export:
            let arranged = try #require(
                try await VideoExporter.exportArrangement(
                    of: AVURLAsset(url: file), for: VideoExportPlan(sourceURL: file, segments: segments)
                ),
                "the export composes nothing"
            )
            let composition = try #require(arranged.videoComposition, "the export draws nothing")
            let pictures = try await TransitionVisibilityTests.read(
                arranged.asset, composition: composition, from: from, to: to, sample: read
            )
            return (pictures, try await lanes(of: arranged.asset))
        case .file:
            let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }
            let asset = AVURLAsset(url: exported.fileURL)
            let pictures = try await TransitionVisibilityTests.read(
                asset, composition: nil, from: from, to: to, sample: read
            )
            return (pictures, [try await SoundProbe.listen(to: asset, mix: nil)])
        }
    }

    /// Each audio track of `asset` on its own, at full level — the sound laid
    /// on each lane, whatever the mix then does with it.
    private static func lanes(of asset: AVAsset) async throws -> [SoundProbe] {
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var probes: [SoundProbe] = []
        for track in tracks {
            probes.append(try await SoundProbe.listen(to: asset, tracks: [track], mix: nil))
        }
        return probes
    }

    /// The canvas's pictures and sound — the controller is the main actor's;
    /// the reading is not.
    @MainActor
    private static func canvas(
        _ segments: [VideoExportSegment], file: URL, from: Double, to: Double,
        read: @escaping @Sendable (CVPixelBuffer, Double) -> Picture
    ) async throws -> (pictures: [Picture], sounds: [SoundProbe]) {
        let controller = VideoPlaybackController(
            source: TransitionVisibilityTests.Passthrough(), poolSize: 1, capacity: 1
        )
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        defer { controller.stop(view) }
        await controller.load(VideoExportPlan(sourceURL: file, segments: segments), in: view) {
            VideoLoadLanding(seconds: 0)
        }
        let item = try #require(controller.debugItem(in: view), "the preview loaded nothing")
        let composition = try #require(controller.debugComposition(in: view), "the preview composes nothing")
        _ = controller.setPaused(true, in: view)
        let pictures = try await TransitionVisibilityTests.read(
            item.asset, composition: composition, from: from, to: to, sample: read
        )
        return (pictures, try await lanes(of: item.asset))
    }

    /// ⚠️ **EACH LANE'S PICTURE WITHIN ONE FRAME OF ITS OWN SOUND, AT EVERY FRAME
    /// OF THE WINDOW.** Where the two lanes are heard apart, every picture that
    /// makes up at least a quarter of the blend must be lit at its own lane's
    /// moment; in the file, where only the mix is left, the picture that
    /// dominates must be at the moment of the sound that does — away from the
    /// middle, where neither does. The standard half second and the longest
    /// length, two seconds, from the export's composition; the two seconds
    /// from the canvas's too, and once more from the written file, the
    /// encoder's own delays included; and a second into a piece at 2x, from
    /// the file.
    @Test(arguments: [
        Case(source: .export, seconds: 0.5), Case(source: .export, seconds: 2),
        Case(source: .preview, seconds: 2), Case(source: .file, seconds: 2),
        Case(source: .file, seconds: 1, rate: 2)
    ])
    func eachPictureIsWhereItsOwnSoundIs(_ reading: Case) async throws {
        let file = try await TimecodeClipWriter.clip()
        let source = reading.source
        let overlap = reading.overlap
        let (opens, closes) = (4.5 - overlap, 4.5)
        let measured = try await Self.measure(
            reading.segments, file: file, source: source, from: opens, to: closes
        )
        try #require(measured.pictures.count >= Int(overlap * 30) - 1,
                     "guard: \(measured.pictures.count) frames in a \(overlap)s window")
        let lanesApart = source != .file
        try #require(measured.sounds.count == (lanesApart ? 2 : 1),
                     "guard: \(measured.sounds.count) sounds, one per lane expected: \(lanesApart)")
        var checked = 0
        var worst = (off: 0.0, at: "")
        for picture in measured.pictures {
            let progress = (picture.time - opens) / (closes - opens)
            // Where each piece is in the file at this moment, as planned.
            let outgoing = picture.time + 0.5
            let incoming = 5 + (picture.time - opens) * reading.rate
            let heard = measured.sounds.compactMap {
                TimecodeClipWriter.soundSeconds(in: $0.samples, at: picture.time)
            }
            let cells = picture.cells
            try #require(cells.count == 2 && cells[0].level > 100, "guard: nothing lit at \(picture.time)s: \(cells)")
            // Each held picture: the moment its sound says, and how much of the
            // blend it makes up.
            var held: [(sound: Double, share: Double)] = []
            if lanesApart {
                // The ruler the pictures are held to: each lane plays its piece.
                let sorted = heard.sorted()
                try #require(sorted.count == 2, "guard: \(sorted.count) lanes heard at \(picture.time)s")
                #expect(abs(sorted[0] - outgoing) <= Self.frame && abs(sorted[1] - incoming) <= Self.frame,
                        "guard: at \(picture.time)s the lanes are at \(sorted) of the file, not \(outgoing) and \(incoming)")
                held = [(sorted[0], 1 - progress), (sorted[1], progress)]
            } else {
                guard abs(progress - 0.5) >= 0.2 else { continue }
                let louder = try #require(heard.first, "guard: no pitch at \(picture.time)s")
                let expected = progress < 0.5 ? outgoing : incoming
                #expect(abs(louder - expected) <= Self.frame,
                        "guard: at \(picture.time)s the louder sound is at \(louder), not \(expected)")
                held = [(louder, max(progress, 1 - progress))]
            }
            for side in held where side.share >= 0.25 {
                // The louder sound's picture is the brighter cell; a lane's is
                // whichever lit cell it is.
                let candidates = lanesApart ? cells.filter { $0.level >= 40 } : [cells[0]]
                let off = candidates.map { abs(Double($0.frame) * Self.frame - side.sound) }.min() ?? .infinity
                if off > worst.off {
                    worst = (off, String(format: "%.3fs: pictures %@, sound %.3f", picture.time,
                                         cells.map { "\($0.frame)@\($0.level)" }.joined(separator: " "), side.sound))
                }
            }
            checked += 1
        }
        #expect(worst.off <= Self.frame + 0.005,
                "\(reading.testDescription): a picture is \(Int((worst.off * 1000).rounded()))ms off its own sound at \(worst.at)")
        #expect(checked >= Int(overlap * 30 * (lanesApart ? 1 : 0.6)) - 1, "guard: only \(checked) frames checked")
    }
}
