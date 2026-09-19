import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import MediaPlayback

/// **A TWO-PICTURE TRANSITION OVERLAPS ITS TWO PIECES, AND THE RESULT IS THAT
/// MUCH SHORTER.**
///
/// Chosen by the author — *"oui, chevauche les deux segments"*. A dissolve, a
/// swipe or a page curl of `d` seconds draws the outgoing piece's last `d` on
/// lane A and the incoming piece's first `d` on lane B, both at once, both
/// real film at their own pace (`VideoExporter.insertPieces`). Every assertion
/// reads pixels an image generator or an export produced, never the
/// instructions the builder wrote.
///
/// The clip (`ColourClipWriter`) is red, green, blue, white for a second each,
/// so which second of the file a lane read is visible in its colour. Red [0, 1)
/// then blue [2, 3) overlap by the standard half second: the window is
/// [0.5, 1.0), its middle 0.75s, and the result lasts 1.5s.
///
/// ⚠️ **EXPECTED BLENDS ARE COMPUTED FROM COLOURS THIS COMPOSITOR DREW, AT THE
/// TIME THE GENERATOR ACTUALLY USED.** H.264 moves the pure colours (red comes
/// back near (229,32,0)), and a blend is a blend of what was encoded — so the
/// references are the clip's own colours read through the same compositor
/// where no transition reaches, and the progress is taken from the generator's
/// answer, never from the time asked for.
@Suite(.serialized)
struct CrossTransitionTests {
    typealias RGB = ColourClipWriter.RGB

    private func arranged(
        _ segments: [VideoExportSegment], rotated: Bool = false
    ) async throws -> VideoExporter.Arrangement {
        let file = try await ColourClipWriter.clip(rotated: rotated)
        return try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: segments, orientation: .whenComposited
        )
    }

    private func pixel(
        _ arrangement: VideoExporter.Arrangement, at seconds: Double, x: Double = 0.1, y: Double = 0.5
    ) async throws -> (colour: RGB, actual: Double, size: CGSize) {
        try await ColourClipWriter.pixel(
            of: arrangement.asset, composition: arrangement.videoComposition, at: seconds, x: x, y: y
        )
    }

    /// The colour of the clip's `second`th second, as the compositor draws it
    /// where no transition reaches: a piece inside that second, dipped at its
    /// far end so a compositor is in the way, read before the dip opens.
    private func drawn(second: Int) async throws -> RGB {
        let start = Double(second) + 0.1
        let reference = try await arranged([
            VideoExportSegment(start: start, end: start + 0.4, transitionOut: .dipToBlack),
            VideoExportSegment(start: start + 0.4, end: start + 0.8)
        ])
        try #require(reference.videoComposition != nil, "guard: the reference is not composed")
        return try await pixel(reference, at: 0.05).colour
    }

    /// `from` dissolved `progress` of the way into `to`.
    private func mix(_ from: RGB, _ to: RGB, _ progress: Double) -> RGB {
        func channel(_ a: Int, _ b: Int) -> Int { Int((Double(a) * (1 - progress) + Double(b) * progress).rounded()) }
        return RGB(r: channel(from.r, to.r), g: channel(from.g, to.g), b: channel(from.b, to.b))
    }

    /// The largest difference between two colours on any channel.
    private func distance(_ a: RGB, _ b: RGB) -> Int {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    /// How far through the window `[opens, opens + length]` the generator's
    /// frame is.
    private func progress(_ actual: Double, opens: Double = 0.5, length: Double = 0.5) -> Double {
        min(max((actual - opens) / length, 0), 1)
    }

    // MARK: - The blend

    /// Red for a second, then blue: across the window the picture is red
    /// giving way to blue, `progress` of the way through it.
    ///
    /// ⚠️ **BOTH SIDES ARE THE PIECES' OWN, NOT THE FILM AROUND THEM.** The film
    /// just past either piece is the GREEN second, cut away. An overlap drawn
    /// from the pieces' handles — keeping the length — would blend it in.
    @Test func aDissolveBlendsBothPictures() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 3)
        ])
        let red = try await drawn(second: 0)
        let green = try await drawn(second: 1)
        let blue = try await drawn(second: 2)

        for time in [0.625, 0.875] {
            let got = try await pixel(dissolve, at: time)
            let expected = mix(red, blue, progress(got.actual))
            #expect(distance(got.colour, expected) <= 20,
                    "at \(got.actual)s the picture is \(got.colour), red into blue says \(expected)")
            #expect(got.colour.g <= max(red.g, blue.g) + 12,
                    "cut-away green at \(got.actual)s: \(got.colour) (green is \(green))")
        }
        let early = try await pixel(dissolve, at: 0.625).colour
        #expect(early.r > early.b, "the outgoing red does not lead early in the window: \(early)")
        let late = try await pixel(dissolve, at: 0.875).colour
        #expect(late.b > late.r, "the incoming blue does not lead late in the window: \(late)")
    }

    /// ⚠️ **NO JUMP AT THE MIDDLE OF THE OVERLAP.** The instructions are split
    /// there — it is where a dip or a zoom changes piece — and a blend that
    /// read its lanes or its progress differently on either side would jump.
    /// The picture must not change there by more than one frame's worth of
    /// fade.
    ///
    /// ⚠️ **A WINDOW WHOSE MIDDLE IS A FRAME.** 0.4s asked between red [0, 1)
    /// and blue [2, 3): the window is [0.6, 1.0) and its middle 0.8s is frame
    /// 24 — so the frames either side of it are the ones read. Both pieces lie
    /// inside one colour, so no change of colour in the clip itself can pass
    /// for a jump.
    @Test func thereIsNoJumpAtTheMiddle() async throws {
        func pieces(_ kind: VideoTransitionKind?) -> [VideoExportSegment] {
            [
                VideoExportSegment(start: 0, end: 1, transitionOut: kind, transitionSeconds: 0.4),
                VideoExportSegment(start: 2, end: 3)
            ]
        }
        let frame = 1.0 / 30
        let plain = try await arranged(pieces(nil))
        let plainJump = distance(
            try await pixel(plain, at: 1.0 - frame).colour, try await pixel(plain, at: 1.0).colour
        )
        #expect(plainJump > 150, "guard: the plain cut does not jump (\(plainJump))")

        let dissolve = try await arranged(pieces(.dissolve))
        try #require(dissolve.windows == [0.6...1.0], "guard: the window is \(dissolve.windows)")
        let lastBefore = try await pixel(dissolve, at: 0.8 - frame)
        let atTheMiddle = try await pixel(dissolve, at: 0.8)
        #expect(distance(lastBefore.colour, atTheMiddle.colour) <= 40,
                "the dissolve jumps at its middle: \(lastBefore.colour) at \(lastBefore.actual)s, \(atTheMiddle.colour) at \(atTheMiddle.actual)s")
        for side in [lastBefore, atTheMiddle] {
            #expect(side.colour.r >= 80 && side.colour.b >= 80, "not a mix of red and blue at \(side.actual)s: \(side.colour)")
        }
    }

    /// ⚠️ **OUTSIDE ITS WINDOW A TRANSITION DRAWS NOTHING**, whichever kind it
    /// is: before the window the picture is the outgoing piece as a plain cut
    /// shows it, and after it the incoming piece — which the plain cut, not
    /// overlapping, shows HALF A SECOND LATER, so it is read there.
    ///
    /// The reference is drawn by the same compositor — a short dip at a cut far
    /// from the sampled moments — so any difference at all is the
    /// transition's. Sampled a tenth of a second outside the window too, where
    /// a window grown by a fifth would already be a tenth of the way in.
    @Test func beforeAndAfterTheWindowThePictureIsPlain() async throws {
        let reference = try await arranged([
            VideoExportSegment(start: 0, end: 1),
            VideoExportSegment(start: 2, end: 3.5, transitionOut: .dipToBlack),
            VideoExportSegment(start: 3.5, end: 4)
        ])
        // The drawn moment, and where the reference shows the same film.
        let times: [(drawn: Double, plain: Double)] = [(0.3, 0.3), (0.4, 0.4), (1.1, 1.6), (1.2, 1.7)]
        let points: [(x: Double, y: Double)] = [(0.1, 0.5), (0.5, 0.5), (0.9, 0.9), (0.5, 0.05)]
        var plain: [RGB] = []
        for time in times {
            for point in points {
                plain.append(try await pixel(reference, at: time.plain, x: point.x, y: point.y).colour)
            }
        }
        for kind in VideoTransitionKind.allCases where kind.needsBothPictures {
            let drawn = try await arranged([
                VideoExportSegment(start: 0, end: 1, transitionOut: kind),
                VideoExportSegment(start: 2, end: 3)
            ])
            var index = 0
            var worst = 0
            var worstAt = ""
            for time in times {
                for point in points {
                    let got = try await pixel(drawn, at: time.drawn, x: point.x, y: point.y).colour
                    let off = distance(got, plain[index])
                    if off > worst { worst = off; worstAt = "\(time.drawn)s (\(point.x),\(point.y)): \(got) vs \(plain[index])" }
                    index += 1
                }
            }
            #expect(worst <= 6, "\(kind) draws outside its window, at \(worstAt)")
        }
    }

    /// ⚠️ **EVERY KIND STARTS ON THE OUTGOING PICTURE AND ENDS ON THE INCOMING
    /// ONE, UNTOUCHED** — or the window opens and closes with a jump.
    ///
    /// Two readings: `VideoCompositor.cross` itself at progress 0 and 1, over
    /// flat red and flat blue, rendered by the compositor's own context; and
    /// the arrangement's first frame inside the window (0.5s, progress 0)
    /// against the same compositor's plain picture. (The last frame inside
    /// the window is at progress 0.93, which some kinds legitimately still
    /// draw over, so the close is read from `cross` alone.)
    ///
    /// ⚠️ **FOUND THE RIPPLE WASHED WHITE FROM END TO END.** A ripple ADDS its
    /// shading image, read where the picture's slope points — at the shading's
    /// centre wherever the picture is flat. Handed the page curl's shading,
    /// bright in the middle, it drew red as (255,228,228) and blue as
    /// (228,228,255) for the whole window, and jumped by 231 where the window
    /// opened. Every other kind measured exactly 0 at both ends, but for the
    /// shadowed page curl, which leaves its shadow 9 levels deep in one corner
    /// at progress 1 — hence the slack on `cross`.
    @Test func everyKindStartsAndEndsOnItsOwnPictures() async throws {
        let canvas = CGRect(x: 0, y: 0, width: 160, height: 120)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: canvas)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: canvas)
        func worst(_ image: CIImage, against expected: RGB) -> (off: Int, at: String) {
            var found = (off: 0, at: "")
            for x in stride(from: 8.0, to: 160, by: 24) {
                for y in stride(from: 6.0, to: 120, by: 18) {
                    var bytes = [UInt8](repeating: 0, count: 4)
                    VideoCompositor.context.render(
                        image, toBitmap: &bytes, rowBytes: 4,
                        bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil
                    )
                    let got = RGB(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
                    let off = distance(got, expected)
                    if off > found.off { found = (off, "(\(Int(x)),\(Int(y))): \(got)") }
                }
            }
            return found
        }

        let reference = try await arranged([
            VideoExportSegment(start: 0, end: 1),
            VideoExportSegment(start: 2, end: 3.5, transitionOut: .dipToBlack),
            VideoExportSegment(start: 3.5, end: 4)
        ])
        let points: [(x: Double, y: Double)] = [(0.1, 0.5), (0.5, 0.5), (0.9, 0.9), (0.5, 0.05), (0.3, 0.3)]
        var plain: [RGB] = []
        for point in points {
            plain.append(try await pixel(reference, at: 0.5, x: point.x, y: point.y).colour)
        }

        for kind in VideoTransitionKind.allCases where kind.needsBothPictures {
            let start = worst(VideoCompositor.cross(kind, from: red, to: blue, progress: 0, canvas: canvas), against: .red)
            #expect(start.off <= 12, "\(kind) at progress 0 is not the outgoing picture, at \(start.at)")
            let end = worst(VideoCompositor.cross(kind, from: red, to: blue, progress: 1, canvas: canvas), against: .blue)
            #expect(end.off <= 12, "\(kind) at progress 1 is not the incoming picture, at \(end.at)")

            let drawn = try await arranged([
                VideoExportSegment(start: 0, end: 1, transitionOut: kind),
                VideoExportSegment(start: 2, end: 3)
            ])
            for (index, point) in points.enumerated() {
                let opening = try await pixel(drawn, at: 0.5, x: point.x, y: point.y)
                #expect(distance(opening.colour, plain[index]) <= 6,
                        "\(kind) opens its window with a jump at \(opening.actual)s (\(point.x),\(point.y)): \(opening.colour), plainly \(plain[index])")
            }
        }
    }

    // MARK: - The file's edges

    /// ⚠️ **A PIECE THAT OPENS THE FILE GIVES ITS OWN OPENING.** Blue then red:
    /// the red piece starts at 0s, where the file has no film before it — and
    /// needs none, since the overlap plays its own first half second.
    @Test func aPieceOpeningTheFileBlendsItsOwnOpening() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 2, end: 3, transitionOut: .dissolve),
            VideoExportSegment(start: 0, end: 1)
        ])
        let red = try await drawn(second: 0)
        let blue = try await drawn(second: 2)

        for time in [0.625, 1.0 - 1.0 / 30] {
            let got = try await pixel(dissolve, at: time)
            let expected = mix(blue, red, progress(got.actual))
            #expect(distance(got.colour, expected) <= 20,
                    "at \(got.actual)s the picture is \(got.colour), blue into red says \(expected)")
            #expect(got.colour.g <= max(red.g, blue.g) + 12, "green leaked into the blend at \(got.actual)s: \(got.colour)")
            #expect(got.colour.r - blue.r >= 30, "no red from the incoming piece at \(got.actual)s: \(got.colour)")
        }
    }

    /// ⚠️ **A PIECE THAT CLOSES THE FILE GIVES ITS OWN CLOSE.** White (the
    /// file's last second) then red: the outgoing side is the white piece's
    /// last half second, up to the file's very last frame.
    @Test func aPieceClosingTheFileBlendsItsOwnClose() async throws {
        let file = try await ColourClipWriter.clip()
        let track = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
        let range = try await track.load(.timeRange)
        try #require(abs(range.end.seconds - 4) < 0.001, "guard: the file does not end at 4s: \(range.end.seconds)")

        let dissolve = try await arranged([
            VideoExportSegment(start: 3, end: 4, transitionOut: .dissolve),
            VideoExportSegment(start: 0, end: 1)
        ])
        let white = try await drawn(second: 3)
        let red = try await drawn(second: 0)

        for time in [0.625, 0.875, 1.0 - 1.0 / 30] {
            let got = try await pixel(dissolve, at: time)
            let expected = mix(white, red, progress(got.actual))
            #expect(distance(got.colour, expected) <= 20,
                    "at \(got.actual)s the picture is \(got.colour), white into red says \(expected)")
            #expect(got.colour.b >= 8, "no white from the outgoing piece at \(got.actual)s: \(got.colour)")
        }
    }

    // MARK: - Time

    /// ⚠️ **EACH PIECE ON ITS OWN LANE, AT ITS OWN RATE, AND THE RESULT ITS
    /// PIECES LESS THE OVERLAP.** Two seconds at 2x, then half a second at
    /// 0.5x: a second each, overlapping by half a second — lane A holds the
    /// first piece over [0, 1) and lane B the second over [0.5, 1.5), each
    /// scaled on its own track. A composition-level scale would stretch the
    /// other lane where the two overlap, and its sound with it.
    ///
    /// ⚠️ **THE EXPORT'S LENGTH IS READ FROM ITS VIDEO TRACK.** The sound of a
    /// rated export runs on past the pictures — the time-pitch pass's tail and
    /// AAC's packets: 35–55ms when these two pieces shared one track, 160–165ms
    /// now that the one at 0.5x starts its own lane after the overlap. Measured
    /// silent, and the sound under the pictures stays within 20ms of them
    /// (`TransitionSyncTests`, at 2x). The file's own duration is the longer of
    /// the two, so it is held only to that overhang. The pictures themselves
    /// measured a frame short, as a composed dip over the same pieces is —
    /// hence a frame of slack, plus a millisecond for the floating point.
    @Test func aDissolveBetweenRatedPiecesKeepsTheirTiming() async throws {
        let segments = [
            VideoExportSegment(start: 0, end: 2, speed: 2, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 2.5, speed: 0.5)
        ]
        let played = 1.5
        let arrangement = try await arranged(segments)

        let tracks = try await arrangement.asset.loadTracks(withMediaType: .video)
            .compactMap { $0 as? AVCompositionTrack }.sorted { $0.trackID < $1.trackID }
        try #require(tracks.count == 2, "guard: no second lane was laid: \(tracks.count) tracks")
        func laid(_ track: AVCompositionTrack) -> [ClosedRange<Double>] {
            track.segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
                .map { $0.start.seconds...$0.end.seconds }
        }
        #expect(laid(tracks[0]) == [0...1], "lane A is not the first piece: \(laid(tracks[0]))")
        #expect(laid(tracks[1]) == [0.5...1.5], "lane B is not the second piece: \(laid(tracks[1]))")
        let duration = try await arrangement.asset.load(.duration)
        #expect(abs(duration.seconds - played) < 0.001, "the arrangement lasts \(duration.seconds)s, not \(played)s")

        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        let asset = AVURLAsset(url: exported.fileURL)
        let pictures = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let drawn = try await pictures.load(.timeRange).duration.seconds
        #expect(abs(drawn - played) <= 1.0 / 30 + 0.001, "the exported pictures last \(drawn)s, the pieces \(played)s")
        #expect(exported.durationSeconds >= drawn && exported.durationSeconds - played <= 0.2,
                "the export lasts \(exported.durationSeconds)s, the pieces \(played)s")
        #expect(exported.transitionWindows == [0.5...1.0], "got \(exported.transitionWindows)")
        // 0.3s of the export is 0.6s of the file at 2x; 1.4s is 0.9s into the
        // second piece, 2.45s of the file at 0.5x.
        let early = try await ColourClipWriter.pixel(of: asset, composition: nil, at: 0.3, x: 0.1).colour
        let late = try await ColourClipWriter.pixel(of: asset, composition: nil, at: 1.4, x: 0.1).colour
        #expect(early.near(.red), "0.3s of the export is not the file's 0.6s: \(early)")
        #expect(late.near(.blue), "1.4s of the export is not the file's 2.45s: \(late)")
    }

    /// ⚠️ **EVERY KIND PUBLISHES, HALF A SECOND SHORTER THAN ITS PIECES.** A
    /// compositor that fails one request fails the whole export, and a lane
    /// that reaches past the overlap lengthens the file.
    @Test func everyKindExportsItsPiecesLessTheOverlap() async throws {
        let file = try await ColourClipWriter.clip()
        for kind in VideoTransitionKind.allCases {
            let segments = [
                VideoExportSegment(start: 0, end: 1, transitionOut: kind),
                VideoExportSegment(start: 2, end: 3)
            ]
            let played = 2.0 - VideoTransitionKind.standardSeconds
            let exported: ExportedVideo
            do {
                exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
            } catch {
                Issue.record("\(kind) did not export: \(error)")
                continue
            }
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }
            #expect(abs(exported.durationSeconds - played) <= 1.0 / 30 + 0.001,
                    "\(kind) exported \(exported.durationSeconds)s of \(played)s")
            let pictures = try await AVURLAsset(url: exported.fileURL).loadTracks(withMediaType: .video)
            let drawn = try await pictures.first?.load(.timeRange).duration.seconds ?? 0
            #expect(pictures.count == 1 && abs(drawn - played) <= 1.0 / 30 + 0.001,
                    "\(kind) exported \(pictures.count) video tracks, \(drawn)s of pictures for \(played)s")
            #expect(exported.transitionWindows == [0.5...1.0], "\(kind) drew at \(exported.transitionWindows)")
        }
    }

    // MARK: - Orientation

    /// ⚠️ **BOTH LANES ARE TURNED.** A clip recorded upright is stored on its
    /// side; lane B's frames need the same turn as lane A's, or inside the
    /// window the incoming side is drawn sideways across the picture.
    @Test func aRotatedDissolveStaysUpright() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 3)
        ], rotated: true)
        let red = try await drawn(second: 0)
        let blue = try await drawn(second: 2)

        for time in [0.625, 0.875] {
            let top = try await pixel(dissolve, at: time, x: 0.5, y: 0.05)
            #expect(top.size == CGSize(width: 120, height: 160), "the picture is not upright at \(time)s: \(top.size)")
            #expect(top.colour.near(.yellow, by: 40), "the band is not along the top at \(top.actual)s: \(top.colour)")
            let side = try await pixel(dissolve, at: time, x: 0.1, y: 0.6)
            let expected = mix(red, blue, progress(side.actual))
            #expect(distance(side.colour, expected) <= 25,
                    "at \(side.actual)s the side is \(side.colour), the upright blend says \(expected)")
        }
    }
}
