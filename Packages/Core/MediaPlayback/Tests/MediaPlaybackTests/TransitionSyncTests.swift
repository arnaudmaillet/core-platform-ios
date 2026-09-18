import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **THE PICTURE THAT DOMINATES A TRANSITION IS AT THE SAME MOMENT OF THE FILE
/// AS ITS SOUND — ON THE EDITOR'S CANVAS AND IN THE FILE THAT IS PUBLISHED.**
///
/// A version of the two-picture transitions eased MOVING film from both pieces
/// across the window, on the video lanes only: the sound still played the
/// outgoing piece up to the cut and the incoming one from it, so the outgoing
/// picture fell `L·u²` behind its words and the incoming one ran `L(1−u)²`
/// ahead of them — a quarter of the window's half at the cut, 62ms at the
/// standard half second and 250ms at two seconds, where people notice from
/// about 45. Found by review, and measured here before the fix at exactly that.
///
/// ⚠️ **BOTH SIDES READ OFF WHAT WAS MADE, NOT OFF THE BUILDER.** The clip
/// (`TimecodeClipWriter`) lights one cell per frame of the file and plays a
/// sine whose pitch is its clock. The PICTURE is read from the frames the
/// preview composes (the controller's own composition, read as
/// `ComposedFrameReader` reads it), the export's composition composes, or the
/// written file holds: the brighter of the two lit cells is the picture that
/// dominates. The SOUND is read from the same asset's audio — the item the
/// canvas plays, the export's mix, or the file — as its pitch.
///
/// ⚠️ **A SPLIT, SO THE SOUND NEVER JUMPS.** [1, 3) then [3, 5): the cut is at
/// 2s on the result's clock, and the sound is at second `t + 1` of the file at
/// every moment `t` — which the test checks too, before it trusts it.
///
/// ⚠️ **NOT ON THE MAIN ACTOR** — `TransitionVisibilityTests`' reason; only
/// `canvas` hops there, for the controller.
@Suite(.serialized)
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

    private static func split(seconds: Double) -> [VideoExportSegment] {
        [
            VideoExportSegment(start: 1, end: 3, transitionOut: .dissolve, transitionSeconds: seconds),
            VideoExportSegment(start: 3, end: 5)
        ]
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

    /// The pictures in `[from, to)` and the whole sound, from `source`.
    private static func measure(
        _ segments: [VideoExportSegment], file: URL, source: Source, from: Double, to: Double
    ) async throws -> (pictures: [Picture], sound: SoundProbe) {
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
            return (pictures, try await SoundProbe.listen(to: arranged.asset, mix: arranged.audioMix))
        case .file:
            let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }
            let asset = AVURLAsset(url: exported.fileURL)
            let pictures = try await TransitionVisibilityTests.read(
                asset, composition: nil, from: from, to: to, sample: read
            )
            return (pictures, try await SoundProbe.listen(to: asset, mix: nil))
        }
    }

    /// The canvas's pictures and sound — the controller is the main actor's;
    /// the reading is not.
    @MainActor
    private static func canvas(
        _ segments: [VideoExportSegment], file: URL, from: Double, to: Double,
        read: @escaping @Sendable (CVPixelBuffer, Double) -> Picture
    ) async throws -> (pictures: [Picture], sound: SoundProbe) {
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
        return (pictures, try await SoundProbe.listen(to: item.asset, mix: item.audioMix))
    }

    /// ⚠️ **WITHIN ONE FRAME, AT EVERY FRAME OF THE WINDOW.** Away from the cut
    /// the brighter cell must be the sound's moment; within a tenth of the
    /// window of the cut, where the two sides are nearly as bright, one of the
    /// two must be. The standard half second and the longest length, two
    /// seconds — where the eased sides were 62ms and 250ms off at the cut — from
    /// the export's composition; the two seconds from the canvas's too, and once
    /// more from the written file, the encoder's own delays included.
    @Test(arguments: zip([Source.export, .export, .preview, .file], [0.5, 2.0, 2.0, 2.0]))
    func theDominantPictureIsWhereTheSoundIs(source: Source, seconds: Double) async throws {
        let file = try await TimecodeClipWriter.clip()
        let half = seconds / 2
        let (opens, closes) = (2 - half, 2 + half)
        let measured = try await Self.measure(
            Self.split(seconds: seconds), file: file, source: source, from: opens, to: closes
        )
        try #require(measured.pictures.count >= Int(seconds * 30) - 1,
                     "guard: \(measured.pictures.count) frames in a \(seconds)s window")
        var checked = 0
        var worst = (off: 0.0, at: "")
        for picture in measured.pictures {
            let heard = try #require(
                TimecodeClipWriter.soundSeconds(in: measured.sound.samples, at: picture.time),
                "guard: no pitch at \(picture.time)s"
            )
            // The ruler the picture is held to: the sound plays the arrangement.
            #expect(abs(heard - (picture.time + 1)) <= Self.frame,
                    "guard: at \(picture.time)s the sound is at \(heard)s of the file, not \(picture.time + 1)")
            let cells = picture.cells
            try #require(cells.count == 2 && cells[0].level > 100, "guard: nothing lit at \(picture.time)s: \(cells)")
            let progress = (picture.time - opens) / (closes - opens)
            let candidates = abs(progress - 0.5) < 0.1 ? cells : [cells[0]]
            let off = candidates.map { abs(Double($0.frame) * Self.frame - heard) }.min() ?? .infinity
            if off > worst.off {
                worst = (off, String(format: "%.3fs: pictures %@, sound %.3f", picture.time,
                                     cells.map { "\($0.frame)@\($0.level)" }.joined(separator: " "), heard))
            }
            checked += 1
        }
        #expect(worst.off <= Self.frame + 0.005,
                "\(source) \(seconds)s: the picture that dominates is \(Int((worst.off * 1000).rounded()))ms off its sound at \(worst.at)")
        #expect(checked >= Int(seconds * 30) - 1)
    }
}
