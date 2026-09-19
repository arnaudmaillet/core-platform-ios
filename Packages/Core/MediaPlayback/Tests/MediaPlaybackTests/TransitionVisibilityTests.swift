import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import MediaPlayback

/// **EVERY TRANSITION DRAWS WHAT ITS NAME SAYS — ON THE EDITOR'S CANVAS AND IN
/// THE FILE THAT IS PUBLISHED.**
///
/// Reported as *"la plupart des transitions entre segments ne fonctionnent
/// pas"*. Measured then, frame by frame through both routes: on a SPLIT — the
/// only way this editor makes a cut — a dissolve, a swipe, a swirl and a fold
/// drew every frame of their window identical to the plain cut, because the
/// other side of the cut was read from the film just past the pieces, and on a
/// split that film IS the neighbouring piece. A held edge frame fixed that
/// weakly (at most half the picture changed, and least at the cut). The author
/// then chose to OVERLAP the two pieces, CapCut's way — *"oui, chevauche les
/// deux segments"* — so a transition of `d` seconds plays the outgoing piece's
/// last `d` over the incoming piece's first `d` (`VideoExporter.insertPieces`):
/// on a split the two pictures are `d` of the shot apart, and a dissolve at
/// its middle is something no moment of the film is.
///
/// ⚠️ **EVERY READING IS PIXELS, AND EVERY FRAME OF THE WINDOW IS READ** — never
/// the instructions the builder wrote. The PREVIEW is the composition the
/// playback controller put on the canvas for the plan (`debugComposition` —
/// the frame reader's on the default backing, the item's own on the legacy one),
/// read by an `AVAssetReaderVideoCompositionOutput` exactly as
/// `ComposedFrameReader` reads it; the EXPORT is the composition
/// `VideoExporter.export` hands its session (`exportArrangement`, the same
/// call), read the same way, over the window alone.
///
/// ⚠️ **EVERY KIND ONCE, AND EACH ROUTE HELD TO IT — AND THAT IS ENOUGH.**
/// Every kind's pixels come out of one builder and one compositor. What the
/// canvas adds is kind-blind (upright always, a 1280px cap, a live look); what
/// an export adds is the session running the composition and an encoder
/// squeezing its frames. So every kind is read once, from the export's
/// composition; one kind of each drawing is read from the canvas's too and held
/// to it (`theCanvasDrawsWhatTheExportDraws`); three are exported for real and
/// held to their own composition (`theExportedFileDrawsWhatItsCompositionSays`);
/// and every kind is exported once for its length
/// (`CrossTransitionTests.everyKindExportsItsPiecesLessTheOverlap`). Every kind
/// exported and played here, twice over, saturated every core for minutes —
/// and the real-time suites Swift Testing runs beside this one missed their
/// deadlines in CI.
///
/// ⚠️ **A REFERENCE FROM THE SAME ROUTE.** An export that composes nothing and
/// one drawn by `VideoCompositor` differ by ~30 levels on every pixel of these
/// clips (measured), so the plain cut is always composed too: a dip at a later
/// cut, far from the window being read, keeps a compositor in the way.
///
/// ⚠️ **NOT ON THE MAIN ACTOR — ONLY THE CANVAS'S CONTROLLER IS.** Measuring a
/// window is arithmetic over thousands of points, and on the main actor it
/// holds the thread `RehearsalLoopTests` wraps its loops on. Measured with the
/// measuring there: two of four full runs had a looped playhead overshoot its
/// range, by 0.04s and 0.27s; moved off it, eight of eight full runs passed —
/// on a calmer machine, so a reason and not a proof. Only `canvasFrames` hops
/// to the main actor, for the controller.
/// ⚠️ **THE DEFAULT LANE ONLY.** The pictures read here are the COMPOSITION's
/// and the export's, and neither depends on which layer draws the canvas — so
/// the legacy lane would read the very same frames a second time. It was
/// already the slowest lane (203s on develop's CI), and these suites running
/// beside its real-time ones pushed `RehearsalLoopTests` past its range.
/// `CompositorFinishTests` is gated the same way.
@Suite(.serialized, .enabled(if: VideoRenderFlags.usesSampleBufferLayer))
struct TransitionVisibilityTests {
    typealias RGB = ColourClipWriter.RGB

    enum Route: String, CaseIterable, Sendable {
        case preview
        case export
    }

    /// One sampled point of a frame: where, as fractions of the upright picture
    /// (0,0 top left), and its colour.
    struct Point {
        let x: Double
        let y: Double
        let colour: RGB
    }

    struct Frame {
        let time: Double
        let points: [Point]
    }

    struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    nonisolated static let columns = 16
    nonisolated static let rows = 12

    // MARK: - Reading

    private nonisolated static func sample(_ buffer: CVPixelBuffer, at time: Double) -> Frame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return Frame(time: time, points: [])
        }
        var points: [Point] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let x = (Double(c) + 0.5) / Double(columns)
                let y = (Double(r) + 0.5) / Double(rows)
                let at = Int(y * Double(height)) * row + Int(x * Double(width)) * 4
                points.append(Point(x: x, y: y, colour: RGB(r: Int(base[at + 2]), g: Int(base[at + 1]), b: Int(base[at]))))
            }
        }
        return Frame(time: time, points: points)
    }

    /// Every frame `asset` draws through `composition` in `[from, to)`.
    private static func read(
        _ asset: AVAsset, composition: AVVideoComposition?, from: Double, to: Double
    ) async throws -> [Frame] {
        try await read(asset, composition: composition, from: from, to: to) { Self.sample($0, at: $1) }
    }

    /// Every frame `asset` draws through `composition` in `[from, to)`, as
    /// `sample` reads each one.
    static func read<Reading: Sendable>(
        _ asset: AVAsset, composition: AVVideoComposition?, from: Double, to: Double,
        sample: @escaping @Sendable (CVPixelBuffer, Double) -> Reading
    ) async throws -> [Reading] {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
        let output: AVAssetReaderOutput
        if let composition {
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: settings)
            composed.videoComposition = composition
            output = composed
        } else {
            output = AVAssetReaderTrackOutput(track: try #require(tracks.first), outputSettings: settings)
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600)
        )
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        // ⚠️ **OFF THE MAIN ACTOR, BECAUSE EACH COPY RENDERS A FRAME.** Read here,
        // on this suite's own actor, every `copyNextSampleBuffer` blocked the
        // main thread while the composition drew — fourteen kinds, two routes —
        // and the suites that run beside this one starved: `RehearsalLoopTests`
        // loops on a main-queue callback, and its playhead ran a second and a
        // half past its range, in CI and on this machine alike, only while this
        // suite ran next to it.
        // ⚠️ `nonisolated(unsafe)`: the reader and its output were made above,
        // are touched by nothing else while the task runs, and this function
        // waits for it before reading `reader.status`.
        nonisolated(unsafe) let pulled = output
        let frames = await Task.detached { () -> [Reading] in
            var frames: [Reading] = []
            while let buffer = pulled.copyNextSampleBuffer() {
                guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard time >= from - 0.0001, time < to - 0.0001 else { continue }
                frames.append(sample(pixels, time))
            }
            return frames
        }.value
        #expect(reader.status == .completed, "the reader stopped with \(String(describing: reader.error))")
        return frames
    }

    /// Every frame `segments` draws in `[from, to)`, through `route`.
    static func frames(
        _ segments: [VideoExportSegment], file: URL, route: Route, from: Double, to: Double
    ) async throws -> [Frame] {
        switch route {
        case .preview:
            return try await canvasFrames(segments, file: file, from: from, to: to)
        case .export:
            let arranged = try #require(
                try await VideoExporter.exportArrangement(
                    of: AVURLAsset(url: file), for: VideoExportPlan(sourceURL: file, segments: segments)
                ),
                "the export composes nothing"
            )
            let composition = try #require(arranged.videoComposition, "the export draws nothing")
            return try await read(arranged.asset, composition: composition, from: from, to: to)
        }
    }

    /// Every frame the canvas's composition draws — the controller is the main
    /// actor's; the reading is not.
    @MainActor
    private static func canvasFrames(
        _ segments: [VideoExportSegment], file: URL, from: Double, to: Double
    ) async throws -> [Frame] {
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        defer { controller.stop(view) }
        await controller.load(VideoExportPlan(sourceURL: file, segments: segments), in: view) {
            VideoLoadLanding(seconds: 0)
        }
        let item = try #require(controller.debugItem(in: view), "the preview loaded nothing")
        let composition = try #require(controller.debugComposition(in: view), "the preview composes nothing")
        _ = controller.setPaused(true, in: view)
        return try await read(item.asset, composition: composition, from: from, to: to)
    }

    /// Every frame of the FILE `VideoExporter` writes for `segments`, in
    /// `[from, to)` — the encode itself, for the few checks that need one.
    static func exported(
        _ segments: [VideoExportSegment], file: URL, from: Double, to: Double
    ) async throws -> [Frame] {
        let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        return try await read(AVURLAsset(url: exported.fileURL), composition: nil, from: from, to: to)
    }

    // MARK: - Measuring

    static func distance(_ a: RGB, _ b: RGB) -> Int {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    /// The share of points that differ from `reference`'s by more than `by`.
    static func changed(_ frame: Frame, from reference: Frame, by: Int = 60) -> Double {
        let pairs = zip(frame.points, reference.points)
        let count = pairs.filter { distance($0.colour, $1.colour) > by }.count
        return frame.points.isEmpty ? 0 : Double(count) / Double(frame.points.count)
    }

    /// How much greener than its other two channels a colour is.
    static func greenness(_ colour: RGB) -> Int {
        colour.g - max(colour.r, colour.b)
    }

    /// The colour clip's own background — neither its cyan square nor its
    /// yellow band, which every second shares.
    static func background(_ frame: Frame) -> [Point] {
        frame.points.filter { point in
            point.y > 0.16 && !(0.2 < point.x && point.x < 0.8 && 0.2 < point.y && point.y < 0.8)
        }
    }

    /// What one frame of red giving way to blue is made of.
    struct Shares: CustomStringConvertible {
        var red = 0.0, blue = 0.0, mixed = 0.0, dark = 0.0, bright = 0.0, lit = 0.0, cyan = 0.0

        var description: String {
            String(format: "red %.2f blue %.2f mixed %.2f dark %.2f bright %.2f lit %.2f cyan %.2f",
                   red, blue, mixed, dark, bright, lit, cyan)
        }
    }

    static func shares(_ points: [Point]) -> Shares {
        guard !points.isEmpty else { return Shares() }
        func share(_ test: (RGB) -> Bool) -> Double {
            Double(points.filter { test($0.colour) }.count) / Double(points.count)
        }
        return Shares(
            red: share { $0.r > 150 && $0.b < 90 && $0.g < 110 },
            blue: share { $0.b > 150 && $0.r < 90 && $0.g < 110 },
            mixed: share { $0.r > 50 && $0.b > 50 && $0.g < 110 && abs($0.r - $0.b) < 120 },
            dark: share { max($0.r, $0.g, $0.b) < 40 },
            bright: share { min($0.r, $0.g, $0.b) > 170 },
            // Light that neither red nor blue carries: green, from a flash or a
            // scanner's bar.
            lit: share { $0.g > 110 },
            cyan: share { $0.g > 150 && $0.b > 150 && $0.r < 90 }
        )
    }

    // MARK: - Every kind, on two distinct pieces

    /// Red for a second, then blue: the two overlap by the standard half
    /// second, so the window is [0.5, 1.0) — the red piece's last half second
    /// under the blue one's first. A short dip at the far end of the blue piece,
    /// [1.4, 1.5), keeps the plain cut composed.
    private static func redThenBlue(_ kind: VideoTransitionKind?) -> [VideoExportSegment] {
        [
            VideoExportSegment(start: 0, end: 1, transitionOut: kind),
            VideoExportSegment(start: 2, end: 3, transitionOut: .dipToBlack, transitionSeconds: 0.1),
            VideoExportSegment(start: 3, end: 4)
        ]
    }

    /// ⚠️ **DIFFERENT FROM THE PLAIN CUT, AND DIFFERENT IN THE WAY THE NAME
    /// SAYS.** Each kind is read at every frame of its window and held to a
    /// signature: a dip goes (nearly) all black or all white; the zoom blows
    /// the middle square up over the picture; a dissolve is ONE blend
    /// everywhere at once; the kinds that uncover (swipe, bars, swirl, pages,
    /// crumble, scan) show pure red and pure blue side by side, with more blue
    /// as the window goes on; a ripple's ring of light and shade crosses the
    /// picture as it turns; the flash and the scan add light neither picture
    /// has; the fold uncovers blue at the TOP while its pleats still hold red
    /// at the bottom. Read from the export's composition; the canvas's is held
    /// to it by `theCanvasDrawsWhatTheExportDraws`.
    @Test func everyKindDrawsWhatItsNameSays() async throws {
        let route = Route.export
        let file = try await ColourClipWriter.clip()
        let plain = try await Self.frames(Self.redThenBlue(nil), file: file, route: route, from: 0.5, to: 1.0)
        try #require(plain.count >= 14, "guard: the plain window has \(plain.count) frames")
        for kind in VideoTransitionKind.allCases {
            let drawn = try await Self.frames(Self.redThenBlue(kind), file: file, route: route, from: 0.5, to: 1.0)
            try #require(drawn.count == plain.count, "\(kind): \(drawn.count) frames against \(plain.count)")
            let differs = zip(drawn, plain).map { Self.changed($0, from: $1) }.max() ?? 0
            #expect(differs >= 0.2, "\(route) \(kind) looks like the plain cut: at most \(differs) of the picture changed")

            let shares = drawn.map { Self.shares(Self.background($0)) }
            let third = max(shares.count / 3, 1)
            let early = shares.prefix(third).map(\.blue).reduce(0, +) / Double(third)
            let late = shares.suffix(third).map(\.blue).reduce(0, +) / Double(third)
            let sideBySide = shares.map { min($0.red, $0.blue) }.max() ?? 0
            let summary = shares.enumerated().map { "\(String(format: "%.2f", drawn[$0].time)): \($1)" }
                .joined(separator: "\n")
            switch kind {
            case .dipToBlack:
                #expect(shares.map(\.dark).max() ?? 0 >= 0.9, "\(route) \(kind) never goes black:\n\(summary)")
            case .dipToWhite:
                #expect(shares.map(\.bright).max() ?? 0 >= 0.9, "\(route) \(kind) never goes white:\n\(summary)")
            case .zoom:
                #expect(shares.map(\.cyan).max() ?? 0 >= 0.8, "\(route) \(kind) never blows the square up:\n\(summary)")
            case .dissolve:
                #expect(shares.map(\.mixed).max() ?? 0 >= 0.9, "\(route) \(kind) is not one blend:\n\(summary)")
                #expect(sideBySide < 0.1, "\(route) \(kind) shows two regions, not a blend:\n\(summary)")
            case .flash:
                #expect(shares.map(\.lit).max() ?? 0 >= 0.5, "\(route) \(kind) never flashes:\n\(summary)")
            case .copyMachine:
                #expect(shares.map(\.lit).max() ?? 0 >= 0.05, "\(route) \(kind) shows no scanning light:\n\(summary)")
                #expect(sideBySide >= 0.1, "\(route) \(kind) never uncovers:\n\(summary)")
                #expect(late > early + 0.3, "\(route) \(kind) does not advance: \(early) → \(late)\n\(summary)")
            case .accordion:
                let folded = drawn.map { frame -> (top: Double, bottom: Double) in
                    let points = Self.background(frame)
                    return (
                        Self.shares(points.filter { $0.y < 0.45 }).blue,
                        Self.shares(points.filter { $0.y > 0.85 }).blue
                    )
                }
                let pleated = folded.contains { $0.top >= 0.8 && $0.bottom <= 0.2 }
                #expect(pleated, "\(route) \(kind) does not fold: \(folded)\n\(summary)")
            case .ripple:
                // A ring of light and shade crosses the picture as it turns —
                // measured, its crest lights 30% of the points and its trough
                // darkens 44% — rather than two flat regions side by side.
                #expect(shares.map(\.bright).max() ?? 0 >= 0.15, "\(route) \(kind) has no crest:\n\(summary)")
                #expect(shares.map(\.dark).max() ?? 0 >= 0.2, "\(route) \(kind) has no trough:\n\(summary)")
                #expect(late > early + 0.3, "\(route) \(kind) does not advance: \(early) → \(late)\n\(summary)")
            case .swipe, .bars, .mod, .pageCurl, .pageCurlShadow, .disintegrate:
                #expect(sideBySide >= 0.1, "\(route) \(kind) never uncovers:\n\(summary)")
                #expect(late > early + 0.3, "\(route) \(kind) does not advance: \(early) → \(late)\n\(summary)")
            }
        }
    }

    /// ⚠️ **THE FILE IS WHAT ITS COMPOSITION DRAWS.** The one place the export
    /// could part from the composition every other test here reads is the
    /// session: a preset that passes through, a composition not handed over, an
    /// encoder that loses the blend. Three kinds, one of each family — a blend,
    /// a Core Image edge, the fold drawn here — exported for real and held,
    /// frame by frame, to their own composition's frames.
    @Test func theExportedFileDrawsWhatItsCompositionSays() async throws {
        let file = try await ColourClipWriter.clip()
        let plain = try await Self.frames(Self.redThenBlue(nil), file: file, route: .export, from: 0.5, to: 1.0)
        for kind in [VideoTransitionKind.dissolve, .swipe, .accordion] {
            let composed = try await Self.frames(Self.redThenBlue(kind), file: file, route: .export, from: 0.5, to: 1.0)
            let written = try await Self.exported(Self.redThenBlue(kind), file: file, from: 0.5, to: 1.0)
            try #require(written.count == composed.count && composed.count >= 14,
                         "\(kind): \(written.count) frames written, \(composed.count) composed")
            let drawn = zip(composed, plain).map { Self.changed($0, from: $1) }.max() ?? 0
            #expect(drawn >= 0.2, "guard: \(kind)'s composition draws nothing: \(drawn)")
            let apart = zip(written, composed).map { Self.changed($0, from: $1) }
            #expect((apart.max() ?? 1) <= 0.05,
                    "\(kind): the file is not its composition: \(apart.map { String(format: "%.2f", $0) })")
        }
    }

    /// ⚠️ **THE CANVAS DRAWS WHAT THE EXPORT DRAWS.** The preview's composition
    /// differs from the export's in three things only — it is always turned
    /// upright, capped at 1280px, and reads its whole look from a live board —
    /// and none of them depends on the kind. So every kind is read from the
    /// export's composition, and one kind of each drawing — a dip on one lane,
    /// a blend, a Core Image edge, the fold drawn here — is read from the
    /// controller's own composition too and held to it, frame by frame. Every
    /// kind through both, twice over, is what made this suite a minute long.
    @Test func theCanvasDrawsWhatTheExportDraws() async throws {
        let file = try await ColourClipWriter.clip()
        for kind in [VideoTransitionKind.dipToBlack, .dissolve, .swipe, .accordion] {
            let exported = try await Self.frames(Self.redThenBlue(kind), file: file, route: .export, from: 0.5, to: 1.0)
            let canvas = try await Self.frames(Self.redThenBlue(kind), file: file, route: .preview, from: 0.5, to: 1.0)
            try #require(canvas.count == exported.count && exported.count >= 14,
                         "\(kind): \(canvas.count) frames on the canvas, \(exported.count) in the export")
            let apart = zip(canvas, exported).map { Self.changed($0, from: $1, by: 24) }
            #expect((apart.max() ?? 1) <= 0.02,
                    "\(kind): the canvas is not the export: \(apart.map { String(format: "%.2f", $0) })")
        }
    }

    // MARK: - One shot, cut in two

    /// The moving stripes split at 2s: [0.5, 2) then [2, 3.5). They overlap by
    /// the standard half second, so the window is [1.0, 1.5): the outgoing
    /// piece plays the shot's [1.5, 2.0) while the incoming one plays its
    /// [2.0, 2.5) — HALF A SECOND APART, which at 32px a second is half a
    /// period: every stripe of one is the opposite colour in the other. A short
    /// dip at the far end, [2.9, 3.0), keeps the plain film composed.
    private static func split(_ kind: VideoTransitionKind?) -> [VideoExportSegment] {
        [
            VideoExportSegment(start: 0.5, end: 2, transitionOut: kind),
            VideoExportSegment(start: 2, end: 3.5, transitionOut: .dipToBlack, transitionSeconds: 0.1),
            VideoExportSegment(start: 3.5, end: 4)
        ]
    }

    /// ⚠️ **A DISSOLVE AT A PLAIN SPLIT CHANGES MOST OF THE PICTURE.** Asked for
    /// in those words once the author chose the overlap. Half way through the
    /// window the dissolve is half each of two stripe patterns that disagree
    /// everywhere: an even grey where the film is black and white. Every frame
    /// of the middle third is held against EVERY frame of the film around the
    /// split, and the closest single moment must still miss most of it —
    /// comparing with the plain frame at the same time alone would pass a
    /// picture that was only late.
    ///
    /// Measured: every point of every frame of the middle third (100%). With
    /// the held edge frame this replaced, 3% at the cut.
    @Test func aDissolveAtASplitChangesMostOfThePicture() async throws {
        let file = try await StripeClipWriter.clip()
        let film = try await Self.frames(Self.split(nil), file: file, route: .export, from: 0.5, to: 2.0)
        try #require(film.count >= 44, "guard: the plain film has \(film.count) frames")
        let drawn = try await Self.frames(Self.split(.dissolve), file: file, route: .export, from: 1.0, to: 1.5)
        try #require(drawn.count >= 14, "guard: the dissolve drew \(drawn.count) frames")
        let middle = drawn.filter { $0.time >= 1.0 + 0.5 / 3 - 0.001 && $0.time <= 1.0 + 1.0 / 3 + 0.001 }
        try #require(middle.count >= 4, "guard: \(middle.count) frames in the middle third")
        let unexplained = middle.map { frame in film.map { Self.changed(frame, from: $0) }.min() ?? 0 }
        #expect((unexplained.min() ?? 0) >= 0.6,
                "the dissolve at a split leaves the film showing: \(unexplained.map { String(format: "%.2f", $0) })")
    }

    /// ⚠️ **ON A SPLIT EVERY KIND DRAWS A PICTURE NO SINGLE MOMENT OF THE FILM
    /// IS** — the dips and the zoom as well as the kinds that show both pieces,
    /// the fold included. The plain cut is no cut at all here — the film runs
    /// on — so a transition is only seen if it lays something over it. Each
    /// frame of the window is held against every frame of the film around the
    /// split, as above.
    ///
    /// Before any fix a dissolve, a swipe, a swirl and a fold changed NOTHING
    /// on a split. Measured with the overlap, at its best frame: the dissolve
    /// 100%, the fold 75%, a ripple 52%, the dips, the zoom, a swipe, the scan
    /// and the flash 50% — a frame of two halves matches the film in one of
    /// them — and bars, the swirl, the pages and the crumble 42–47%.
    @Test func onASplitEveryKindDrawsMoreThanTheFilm() async throws {
        let route = Route.export
        let file = try await StripeClipWriter.clip()
        let film = try await Self.frames(Self.split(nil), file: file, route: route, from: 0.5, to: 2.0)
        try #require(film.count >= 44, "guard: the plain film has \(film.count) frames")
        for kind in VideoTransitionKind.allCases {
            let drawn = try await Self.frames(Self.split(kind), file: file, route: route, from: 1.0, to: 1.5)
            try #require(drawn.count >= 14, "\(kind): \(drawn.count) frames")
            let unexplained = drawn.map { frame in film.map { Self.changed(frame, from: $0) }.min() ?? 0 }
            #expect((unexplained.max() ?? 0) >= 0.3,
                    "\(route) \(kind) on a split draws single moments of the film: \(unexplained.map { String(format: "%.2f", $0) })")
        }
    }

    /// ⚠️ **AND IT MEETS EACH PIECE'S OWN FILM AT ITS EDGES, WITHOUT A JUMP.**
    /// Where the window opens the picture is the outgoing piece alone — the
    /// plain film at that moment; where it closes it is the incoming piece
    /// alone, which the plain split, not overlapping, shows HALF A SECOND
    /// LATER. Read on the moving stripes, where a side a frame early or late
    /// would turn a whole stripe edge over.
    @Test func aDissolveOnASplitMeetsEachPieceAtItsEdges() async throws {
        let file = try await StripeClipWriter.clip()
        let plain = try await Self.frames(Self.split(nil), file: file, route: .export, from: 0.9, to: 2.1)
        let drawn = try await Self.frames(Self.split(.dissolve), file: file, route: .export, from: 0.9, to: 1.6)
        func film(at time: Double) throws -> Frame {
            try #require(plain.first { abs($0.time - time) < 0.25 / 30 }, "guard: no plain frame at \(time)s")
        }
        // ⚠️ THE FRAMES EITHER SIDE OF EACH EDGE: the window's first frame is
        // at 1.0s and its last at 1.467s; the frame after it is 1.5s.
        // ⚠️ AND AT 24 LEVELS, NOT 60: both are this route's own composed
        // frames, and a frame already a tenth blended moves a stripe by 25.
        let edges: [(time: Double, filmAt: Double)] = [
            (1.0 - 1.0 / 30, 1.0 - 1.0 / 30), (1.0, 1.0),
            (1.5 - 1.0 / 30, 2.0 - 1.0 / 30), (1.5, 2.0)
        ]
        for edge in edges {
            let got = try #require(drawn.first { abs($0.time - edge.time) < 0.25 / 30 }, "guard: no frame at \(edge.time)s")
            let off = Self.changed(got, from: try film(at: edge.filmAt), by: 24)
            #expect(off <= 0.02, "at \(got.time)s the dissolve is not the film at \(edge.filmAt)s: \(off) of it differs")
        }
        let inside = drawn.filter { $0.time > 1.01 && $0.time < 1.46 }
        let changed = try inside.map { Self.changed($0, from: try film(at: $0.time)) }
        #expect((changed.max() ?? 0) >= 0.5, "guard: nothing is laid over the film: \(changed)")
    }

    /// ⚠️ **ONLY FILM THE AUTHOR KEPT.** Red [0, 1) then blue [2, 3): the film
    /// just past either piece is GREEN — cut away. An overlap taken from the
    /// pieces' handles would keep the length and blend that green in; taken
    /// from the pieces themselves, no green reaches the window at all. (The
    /// flash and the scan are left out: their own light is green.)
    @Test func aTransitionShowsOnlyFilmThePiecesKeep() async throws {
        let route = Route.export
        let file = try await ColourClipWriter.clip()
        for kind in VideoTransitionKind.allCases where kind.needsBothPictures && kind != .flash && kind != .copyMachine {
            let drawn = try await Self.frames(Self.redThenBlue(kind), file: file, route: route, from: 0.5, to: 1.0)
            try #require(drawn.count >= 14, "guard: \(kind) drew \(drawn.count) frames")
            // ⚠️ ONE STEP AT A TIME: written as one comparator, Xcode 26's type
            // checker gives up on this line ("unable to type-check this
            // expression in reasonable time") where Xcode 27's does not.
            let points: [Point] = drawn.flatMap { Self.background($0) }
            let greenest = points.max { Self.greenness($0.colour) < Self.greenness($1.colour) }
            let colour = try #require(greenest).colour
            #expect(colour.g < max(colour.r, colour.b) + 40,
                    "\(route) \(kind) shows cut-away green film: \(colour)")
        }
    }

    // MARK: - The duration

    /// ⚠️ **A LONGER TRANSITION OVERLAPS MORE — IN BOTH ROUTES.** One second
    /// asked between two pieces of two seconds — red then green, blue then
    /// white — each able to give half of itself: the window is [1.0, 2.0), the
    /// green second under the blue one, so at 1.25s a quarter of the blue is
    /// already in (~57 of 229), where the standard half second, [1.5, 2.0),
    /// has not opened — and at 0.95s the long one has not either.
    @Test(arguments: Route.allCases)
    func aTransitionRunsForTheSecondsItWasGiven(route: Route) async throws {
        let file = try await ColourClipWriter.clip()
        func pieces(_ seconds: Double) -> [VideoExportSegment] {
            [
                VideoExportSegment(start: 0, end: 2, transitionOut: .dissolve, transitionSeconds: seconds),
                VideoExportSegment(start: 2, end: 4)
            ]
        }
        func blue(_ frames: [Frame], at time: Double) throws -> Double {
            let frame = try #require(frames.min { abs($0.time - time) < abs($1.time - time) })
            let points = Self.background(frame)
            return Double(points.map(\.colour.b).reduce(0, +)) / Double(max(points.count, 1))
        }
        let long = try await Self.frames(pieces(1), file: file, route: route, from: 0.9, to: 1.3)
        let standard = try await Self.frames(pieces(0.5), file: file, route: route, from: 0.9, to: 1.3)
        #expect(try blue(long, at: 0.95) <= 12, "\(route): a one-second window opened before 1.0s")
        #expect(try blue(long, at: 1.25) >= 30, "\(route): a one-second window is not blending at 1.25s")
        #expect(try blue(standard, at: 1.25) <= 12, "guard: \(route) the standard window blends at 1.25s")

        if route == .export {
            let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: pieces(1)))
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }
            #expect(exported.transitionWindows == [1.0...2.0], "the file says it drew at \(exported.transitionWindows)")
        }
    }
}

/// **A TRANSITION'S LENGTH, AS ARITHMETIC — AND WHAT IT TAKES OFF THE FILM.**
/// The rules `TransitionVisibilityTests` reads off the pixels, asked of the
/// functions that make them — the default lane only, as it is: an export
/// does not depend on the canvas's layer.
@Suite(.enabled(if: VideoRenderFlags.usesSampleBufferLayer))
struct TransitionLengthTests {
    /// ⚠️ **NEVER MORE THAN THE SHORTER NEIGHBOUR CAN GIVE.** Two seconds asked
    /// between a 0.6s piece and a 1.5s one: each gives at most half of itself,
    /// so they overlap by 0.3s — [0.3, 0.6] — and the result is 0.6 + 1.5 − 0.3.
    @Test func aTransitionIsClampedToWhatItsPiecesCanGive() async throws {
        let file = try await ColourClipWriter.clip()
        let arranged = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file),
            cut: [
                VideoExportSegment(start: 0, end: 0.6, transitionOut: .dissolve, transitionSeconds: 2),
                VideoExportSegment(start: 2, end: 3.5)
            ],
            orientation: .whenComposited
        )
        #expect(arranged.windows == [0.3...0.6], "drew at \(arranged.windows)")
        let duration = try await arranged.asset.load(.duration)
        #expect(duration == CMTime(value: 1080, timescale: 600), "the arrangement lasts \(duration.seconds)s, not 1.8s")
    }

    /// The overlap, as arithmetic: what was asked, never more than half of
    /// either neighbour, floored to the 1/600 grid, nothing under two frames.
    @Test func theOverlapIsWhatWasAskedWithinTheNeighbours() {
        func overlap(_ kind: VideoTransitionKind?, _ seconds: Double, _ outgoing: Double, _ incoming: Double) -> Double {
            VideoExporter.transitionOverlap(
                kind, seconds: seconds, outgoingPlayedSeconds: outgoing, incomingPlayedSeconds: incoming
            )
        }
        #expect(VideoExporter.transitionOverlap(.dissolve, outgoingPlayedSeconds: 3, incomingPlayedSeconds: 3) == 0.5)
        #expect(overlap(.dissolve, 1.5, 3, 3) == 1.5)
        #expect(overlap(.dissolve, 2, 3, 1.2) == 0.6)
        #expect(overlap(.dissolve, 2, 0.9, 3) == 0.45)
        #expect(overlap(.dissolve, 2, 1.0025, 3) == 0.5, "not floored to the grid: 300.75 ticks")
        #expect(overlap(.dissolve, 40.0 / 600, 3, 3) == 40.0 / 600, "two frames is drawn")
        #expect(overlap(.dissolve, 39.0 / 600, 3, 3) == 0, "under two frames is a flicker")
        #expect(overlap(.dissolve, 2, 3, 78.0 / 600) == 0, "half of a short neighbour is under two frames")
        #expect(overlap(nil, 1, 3, 3) == 0)
        #expect(overlap(.dissolve, .nan, 3, 3) == 0)
    }

    /// ⚠️ **THE FILE LASTS ITS PIECES LESS THEIR OVERLAPS.** Asked for in those
    /// words with the overlap: the composition is `d` shorter per transition.
    /// Four pieces — a second at 1x, two seconds at 2x, 0.6s and 0.6s, played
    /// 3.2s in all — joined by a dissolve (0.5s), a dip asked at 0.4s and
    /// clamped to 0.3s by the 0.6s piece after it, and a plain cut, which
    /// overlaps nothing: 3.2 − 0.5 − 0.3 = 2.4s, on the composition's clock to
    /// the tick and in the written file to a frame.
    @Test func anExportLastsItsPiecesLessTheirOverlaps() async throws {
        let file = try await ColourClipWriter.clip()
        let segments = [
            VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve),
            VideoExportSegment(start: 1, end: 3, speed: 2, transitionOut: .dipToBlack, transitionSeconds: 0.4),
            VideoExportSegment(start: 3, end: 3.6),
            VideoExportSegment(start: 0.2, end: 0.8)
        ]
        let arranged = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: segments, orientation: .whenComposited
        )
        let duration = try await arranged.asset.load(.duration)
        #expect(duration == CMTime(value: 1440, timescale: 600), "the arrangement lasts \(duration.seconds)s, not 2.4s")
        #expect(arranged.windows == [0.5...1.0, 1.2...1.5], "drew at \(arranged.windows)")

        let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        let pictures = try #require(try await AVURLAsset(url: exported.fileURL).loadTracks(withMediaType: .video).first)
        let drawn = try await pictures.load(.timeRange).duration.seconds
        #expect(abs(drawn - 2.4) <= 1.0 / 30 + 0.001, "the exported pictures last \(drawn)s, not 2.4s")
        #expect(exported.transitionWindows == [0.5...1.0, 1.2...1.5], "the file says \(exported.transitionWindows)")
    }

    /// ⚠️ **A LENGTH ON A PLAIN CUT IS NOT STORED** — the initialiser puts the
    /// standard there, so two plain pieces compare equal whatever was passed.
    @Test func aPlainCutCarriesNoLength() {
        #expect(VideoExportSegment(start: 0, end: 1, transitionSeconds: 2) == VideoExportSegment(start: 0, end: 1))
        #expect(VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve, transitionSeconds: 2).transitionSeconds == 2)
    }
}
