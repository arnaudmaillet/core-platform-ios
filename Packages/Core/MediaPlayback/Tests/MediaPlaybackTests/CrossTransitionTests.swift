import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import MediaPlayback

/// **A TWO-PICTURE TRANSITION SHOWS BOTH SIDES OF ITS CUT, AND COSTS NO TIME.**
///
/// A dissolve, a swipe or a page curl draws the outgoing piece and the incoming
/// one at once, across the whole window. Both come from the two pieces
/// themselves (`VideoExporter.borrowedSides`): the outgoing piece's last half
/// window on lane B, eased out, and the incoming piece's first half window in
/// place of the window on the arrangement's own lane, eased in. Every
/// assertion reads pixels an image generator or an export produced, never the
/// instructions the builder wrote.
///
/// The clip (`ColourClipWriter`) is red, green, blue, white for a second each,
/// so which second of the file a lane read is visible in its colour.
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

    /// How far through the window `[opens, opens + 0.5]` the generator's
    /// frame is.
    private func progress(_ actual: Double, opens: Double = 0.75) -> Double {
        min(max((actual - opens) / 0.5, 0), 1)
    }

    // MARK: - The blend

    /// Red for a second, then blue: on both sides of the cut the picture is red
    /// giving way to blue, `progress` of the way through the window.
    ///
    /// ⚠️ **BOTH SIDES ARE THE PIECES' OWN, NOT THE FILM AROUND THEM.** The film
    /// just past either piece is the GREEN second, cut away; the handles this
    /// used to read blended it in on both sides of the cut — (red → green) and
    /// then (green → blue).
    @Test func aDissolveBlendsBothPictures() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 3)
        ])
        let red = try await drawn(second: 0)
        let green = try await drawn(second: 1)
        let blue = try await drawn(second: 2)

        for time in [0.875, 1.125] {
            let got = try await pixel(dissolve, at: time)
            let expected = mix(red, blue, progress(got.actual))
            #expect(distance(got.colour, expected) <= 20,
                    "at \(got.actual)s the picture is \(got.colour), red into blue says \(expected)")
            #expect(got.colour.g <= max(red.g, blue.g) + 12,
                    "cut-away green at \(got.actual)s: \(got.colour) (green is \(green))")
        }
        let early = try await pixel(dissolve, at: 0.875).colour
        #expect(early.r > early.b, "the outgoing red does not lead before the cut: \(early)")
        let late = try await pixel(dissolve, at: 1.125).colour
        #expect(late.b > late.r, "the incoming blue does not lead after the cut: \(late)")
    }

    /// ⚠️ **NO JUMP AT THE CUT.** Both sides run across the whole window, so the
    /// picture does not change there by more than one frame's worth of fade.
    ///
    /// ⚠️ **PIECES CUT INSIDE A COLOUR, ON PURPOSE.** Each side eases through the
    /// film at the end of its own piece; half a second of red and half a second
    /// of blue, taken from the middle of their seconds, stay one colour however
    /// far a side has got.
    @Test func thereIsNoJumpAtTheCut() async throws {
        func pieces(_ kind: VideoTransitionKind?) -> [VideoExportSegment] {
            [
                VideoExportSegment(start: 0, end: 0.5, transitionOut: kind),
                VideoExportSegment(start: 2.5, end: 3)
            ]
        }
        let frame = 1.0 / 30
        let plain = try await arranged(pieces(nil))
        let plainJump = distance(
            try await pixel(plain, at: 0.5 - frame).colour, try await pixel(plain, at: 0.5).colour
        )
        #expect(plainJump > 150, "guard: the plain cut does not jump (\(plainJump))")

        let dissolve = try await arranged(pieces(.dissolve))
        let lastBefore = try await pixel(dissolve, at: 0.5 - frame)
        let atTheCut = try await pixel(dissolve, at: 0.5)
        #expect(distance(lastBefore.colour, atTheCut.colour) <= 40,
                "the dissolve jumps at the cut: \(lastBefore.colour) at \(lastBefore.actual)s, \(atTheCut.colour) at \(atTheCut.actual)s")
        for side in [lastBefore, atTheCut] {
            #expect(side.colour.r >= 80 && side.colour.b >= 80, "not a mix of red and blue at \(side.actual)s: \(side.colour)")
        }
    }

    /// ⚠️ **OUTSIDE ITS WINDOW A TRANSITION DRAWS NOTHING**, whichever kind it
    /// is: the picture a quarter second and more from the cut is the plain one.
    ///
    /// The reference is drawn by the same compositor — a dip at a cut far from
    /// the sampled moments — so any difference at all is the transition's.
    /// Measured: every kind matched it exactly (0 on every channel). Sampled a
    /// tenth of a second outside the window too, where a window grown to a
    /// whole second either side would already be a tenth of the way in.
    @Test func beforeAndAfterTheWindowThePictureIsPlain() async throws {
        let reference = try await arranged([
            VideoExportSegment(start: 0, end: 1),
            VideoExportSegment(start: 2, end: 3, transitionOut: .dipToBlack),
            VideoExportSegment(start: 3, end: 4)
        ])
        let times = [0.5, 0.6, 1.4, 1.5]
        let points: [(x: Double, y: Double)] = [(0.1, 0.5), (0.5, 0.5), (0.9, 0.9), (0.5, 0.05)]
        var plain: [RGB] = []
        for time in times {
            for point in points {
                plain.append(try await pixel(reference, at: time, x: point.x, y: point.y).colour)
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
                    let got = try await pixel(drawn, at: time, x: point.x, y: point.y).colour
                    let off = distance(got, plain[index])
                    if off > worst { worst = off; worstAt = "\(time)s (\(point.x),\(point.y)): \(got) vs \(plain[index])" }
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
    /// the arrangement's first frame inside the window (0.75s, progress 0)
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
            VideoExportSegment(start: 2, end: 3, transitionOut: .dipToBlack),
            VideoExportSegment(start: 3, end: 4)
        ])
        let points: [(x: Double, y: Double)] = [(0.1, 0.5), (0.5, 0.5), (0.9, 0.9), (0.5, 0.05), (0.3, 0.3)]
        var plain: [RGB] = []
        for point in points {
            plain.append(try await pixel(reference, at: 0.75, x: point.x, y: point.y).colour)
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
                let opening = try await pixel(drawn, at: 0.75, x: point.x, y: point.y)
                #expect(distance(opening.colour, plain[index]) <= 6,
                        "\(kind) opens its window with a jump at \(opening.actual)s (\(point.x),\(point.y)): \(opening.colour), plainly \(plain[index])")
            }
        }
    }

    // MARK: - The file's edges

    /// ⚠️ **A PIECE THAT OPENS THE FILE NEEDS NOTHING BEFORE IT.** Blue then
    /// red: the red piece starts at 0s, where the file has no film before it.
    /// The handles this replaced held the first frame there; borrowed from the
    /// piece, the incoming side is simply the red piece's own opening, and the
    /// blend is blue and red with no green in it.
    @Test func aPieceOpeningTheFileBlendsItsOwnOpening() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 2, end: 3, transitionOut: .dissolve),
            VideoExportSegment(start: 0, end: 1)
        ])
        let red = try await drawn(second: 0)
        let blue = try await drawn(second: 2)

        for time in [0.875, 1.0 - 1.0 / 30] {
            let got = try await pixel(dissolve, at: time)
            let expected = mix(blue, red, progress(got.actual))
            #expect(distance(got.colour, expected) <= 20,
                    "at \(got.actual)s the picture is \(got.colour), blue into red says \(expected)")
            #expect(got.colour.g <= max(red.g, blue.g) + 12, "green leaked into the blend at \(got.actual)s: \(got.colour)")
            #expect(got.colour.r - blue.r >= 30, "no red from the incoming piece at \(got.actual)s: \(got.colour)")
        }
    }

    /// ⚠️ **A PIECE THAT CLOSES THE FILE NEEDS NOTHING AFTER IT.** White (the
    /// file's last second) then red: after the cut the outgoing side is still
    /// the white piece's own closing film — the only place blue can come from,
    /// since red has none.
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

        for time in [1.0, 1.0 + 1.0 / 30, 1.125] {
            let got = try await pixel(dissolve, at: time)
            let expected = mix(white, red, progress(got.actual))
            #expect(distance(got.colour, expected) <= 20,
                    "at \(got.actual)s the picture is \(got.colour), white into red says \(expected)")
            #expect(got.colour.b >= 40, "no white from the outgoing piece at \(got.actual)s: \(got.colour)")
        }
    }

    // MARK: - Time

    /// ⚠️ **THE WINDOW NEVER MOVES THE PIECES.** The incoming side is put in
    /// place of the window on lane A, exactly as long, and the outgoing side on
    /// lane B; both are scaled on their own tracks, after the pieces' rates are
    /// set — a composition-level scale issued there would stretch the
    /// arrangement under it and the sound with it.
    ///
    /// Two seconds at 2x, then half a second at 0.5x: one second each, so each
    /// side lends a quarter of a second played — half a second of film from the
    /// fast piece, an eighth from the slow one — eased across the half-second
    /// window.
    ///
    /// ⚠️ **THE EXPORT'S LENGTH IS READ FROM ITS VIDEO TRACK.** The sound of a
    /// rated export runs 35–55ms past the pictures — measured 2.035, 2.043 and
    /// 2.055s for these two seconds, and the same with no transition at all
    /// (the time-pitch pass and AAC's packets, not lane B). The file's own
    /// duration is the longer of the two, so it is held only to that overhang.
    /// The pictures themselves measured 1.967s — exactly a frame short, as a
    /// composed dip over the same pieces is — hence a frame of slack, plus a
    /// millisecond for the floating point.
    @Test func aDissolveBetweenRatedPiecesKeepsTheirTiming() async throws {
        let segments = [
            VideoExportSegment(start: 0, end: 2, speed: 2, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 2.5, speed: 0.5)
        ]
        let played = segments.reduce(0) { $0 + ($1.end - $1.start) / $1.speed }
        let arrangement = try await arranged(segments)

        let tracks = try await arrangement.asset.loadTracks(withMediaType: .video)
        try #require(tracks.count == 2, "guard: no second lane was laid: \(tracks.count) tracks")
        let laneA = try #require(tracks.min(by: { $0.trackID < $1.trackID }) as? AVCompositionTrack)
        let targets = laneA.segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        let spans = targets.map { ($0.start.seconds, $0.end.seconds) }
        #expect(targets.first?.start == .zero && targets.last?.end.seconds == 2,
                "the window moved the pieces: \(spans)")
        #expect(zip(targets, targets.dropFirst()).allSatisfy { $0.end == $1.start }, "a gap in lane A: \(spans)")
        #expect(targets.contains { $0.start.seconds == 0 && $0.end.seconds == 0.75 }
                && targets.contains { $0.start.seconds == 1.25 && $0.end.seconds == 2 },
                "the pieces outside the window were touched: \(spans)")
        let duration = try await arrangement.asset.load(.duration)
        #expect(abs(duration.seconds - played) < 0.001, "the arrangement lasts \(duration.seconds)s, not \(played)s")

        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        let asset = AVURLAsset(url: exported.fileURL)
        let pictures = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let drawn = try await pictures.load(.timeRange).duration.seconds
        #expect(abs(drawn - played) <= 1.0 / 30 + 0.001, "the exported pictures last \(drawn)s, the pieces \(played)s")
        #expect(abs(exported.durationSeconds - played) <= 0.075,
                "the export lasts \(exported.durationSeconds)s, the pieces \(played)s")
        #expect(exported.transitionWindows == [0.75...1.25], "got \(exported.transitionWindows)")
        // 0.4s of the export is 0.8s of the file at 2x; 1.6s is 2.3s at 0.5x.
        let early = try await ColourClipWriter.pixel(of: asset, composition: nil, at: 0.4, x: 0.1).colour
        let late = try await ColourClipWriter.pixel(of: asset, composition: nil, at: 1.6, x: 0.1).colour
        #expect(early.near(.red), "0.4s of the export is not the file's 0.8s: \(early)")
        #expect(late.near(.blue), "1.6s of the export is not the file's 2.3s: \(late)")
    }

    /// ⚠️ **EVERY KIND PUBLISHES, AND NONE CHANGES THE LENGTH.** A compositor
    /// that fails one request fails the whole export, and a lane that reaches
    /// past the arrangement lengthens the file.
    @Test func everyKindExportsAtThePlansLength() async throws {
        let file = try await ColourClipWriter.clip()
        for kind in VideoTransitionKind.allCases {
            let segments = [
                VideoExportSegment(start: 0, end: 1, transitionOut: kind),
                VideoExportSegment(start: 2, end: 3)
            ]
            let played = segments.reduce(0) { $0 + ($1.end - $1.start) / $1.speed }
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
            #expect(exported.transitionWindows == [0.75...1.25], "\(kind) drew at \(exported.transitionWindows)")
        }
    }

    // MARK: - Orientation

    /// ⚠️ **BOTH LANES ARE TURNED.** A clip recorded upright is stored on its
    /// side; lane B's frames need the same turn as lane A's, or inside the
    /// window the outgoing side is drawn sideways across the picture.
    @Test func aRotatedDissolveStaysUpright() async throws {
        let dissolve = try await arranged([
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 2, end: 3)
        ], rotated: true)
        let red = try await drawn(second: 0)
        let blue = try await drawn(second: 2)

        for time in [0.875, 1.125] {
            let (from, to) = (red, blue)
            let top = try await pixel(dissolve, at: time, x: 0.5, y: 0.05)
            #expect(top.size == CGSize(width: 120, height: 160), "the picture is not upright at \(time)s: \(top.size)")
            #expect(top.colour.near(.yellow, by: 40), "the band is not along the top at \(top.actual)s: \(top.colour)")
            let side = try await pixel(dissolve, at: time, x: 0.1, y: 0.6)
            let expected = mix(from, to, progress(side.actual))
            #expect(distance(side.colour, expected) <= 25,
                    "at \(side.actual)s the side is \(side.colour), the upright blend says \(expected)")
        }
    }
}
