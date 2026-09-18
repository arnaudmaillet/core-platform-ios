import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import MediaPlayback

/// **EVERY TRANSITION DRAWS WHAT ITS NAME SAYS — ON THE EDITOR'S CANVAS AND IN
/// THE FILE THAT IS PUBLISHED.**
///
/// Reported as *"la plupart des transitions entre segments ne fonctionnent
/// pas"*. Measured before the fix, frame by frame through both routes: on a
/// SPLIT — the only way this editor makes a cut — a dissolve, a swipe, a swirl
/// and a fold drew every frame of their window identical to the plain cut, and
/// bars, the scan, the page and the crumble changed at most a fifth of it: the
/// other side of the cut was read from the film just past the pieces, and on a
/// split that film IS the neighbouring piece (`VideoExporter.borrowedSides`).
/// Between two pieces whose film differs every kind drew — but the fold drew a
/// plain cross-fade (Core Image folds only between pictures of different
/// heights), and every two-picture kind blended in film the author had cut
/// away.
///
/// ⚠️ **EVERY READING IS PIXELS, AND EVERY FRAME OF THE WINDOW IS READ** — never
/// the instructions the builder wrote. The PREVIEW is the composition the
/// playback controller put on the canvas for the plan (`debugComposition` —
/// the frame reader's on the default backing, the item's own on the legacy one),
/// read by an `AVAssetReaderVideoCompositionOutput` exactly as
/// `ComposedFrameReader` reads it; the EXPORT is the file `VideoExporter`
/// wrote, read back as it is.
///
/// ⚠️ **A REFERENCE FROM THE SAME ROUTE.** An export that composes nothing and
/// one drawn by `VideoCompositor` differ by ~30 levels on every pixel of these
/// clips (measured), so the plain cut is always composed too: a dip at a later
/// cut, far from the window being read, keeps a compositor in the way.
@MainActor
@Suite(.serialized)
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

    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    static let columns = 16
    static let rows = 12

    // MARK: - Reading

    private static func sample(_ buffer: CVPixelBuffer, at time: Double) -> Frame {
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
        var frames: [Frame] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard time >= from - 0.0001, time < to - 0.0001 else { continue }
            frames.append(sample(pixels, at: time))
        }
        #expect(reader.status == .completed, "the reader stopped with \(String(describing: reader.error))")
        return frames
    }

    /// Every frame `segments` draws in `[from, to)`, through `route`.
    static func frames(
        _ segments: [VideoExportSegment], file: URL, route: Route, from: Double, to: Double
    ) async throws -> [Frame] {
        switch route {
        case .preview:
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
        case .export:
            let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: segments))
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }
            return try await read(AVURLAsset(url: exported.fileURL), composition: nil, from: from, to: to)
        }
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

    /// Red for three quarters of a second, then blue — a transition at 0.75s
    /// whose window is [0.5, 1.0). A dip far away at 1.5s keeps the plain cut
    /// composed.
    private static func redThenBlue(_ kind: VideoTransitionKind?) -> [VideoExportSegment] {
        [
            VideoExportSegment(start: 0, end: 0.75, transitionOut: kind),
            VideoExportSegment(start: 2.25, end: 3, transitionOut: .dipToBlack),
            VideoExportSegment(start: 3, end: 3.75)
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
    /// at the bottom.
    @Test(arguments: Route.allCases)
    func everyKindDrawsWhatItsNameSays(route: Route) async throws {
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

    // MARK: - Two moments of one shot

    /// A split at 2s of the moving stripes: [1, 2) then [2, 3), so the cut is
    /// at 1s and a half-second window is [0.75, 1.25). A dip far away at 2.5s
    /// keeps the plain film composed.
    private static func split(_ kind: VideoTransitionKind?) -> [VideoExportSegment] {
        [
            VideoExportSegment(start: 1, end: 2, transitionOut: kind),
            VideoExportSegment(start: 2, end: 3, transitionOut: .dipToBlack),
            VideoExportSegment(start: 3, end: 4)
        ]
    }

    /// ⚠️ **ON A SPLIT EVERY TWO-PICTURE KIND DRAWS A PICTURE NO SINGLE MOMENT
    /// OF THE FILM IS.** The plain cut here is no cut at all — the film runs on
    /// — so a transition is only seen if it shows two moments at once (or light
    /// of its own). Each frame of the window is held against EVERY frame of the
    /// film around the cut, and the closest one must still differ: comparing
    /// with the plain frame at the same time alone would pass a side that was
    /// merely slowed or frozen, which shows one moment, late.
    ///
    /// Measured before the fix, identically through both routes, against the
    /// plain frame at the same time: dissolve, swipe, swirl and fold changed
    /// NOTHING (every point within 60 levels in every frame); bars, the scan,
    /// the page and the crumble at most 21%, 13%, 19% and 13% — their own
    /// edges, light and shade over one picture. After, the closest single
    /// moment still misses at least 22% of it — the swirl, the least, whose
    /// bands each match one moment or the other.
    @Test(arguments: Route.allCases)
    func onASplitEveryTwoPictureKindShowsTwoMoments(route: Route) async throws {
        let file = try await StripeClipWriter.clip()
        let film = try await Self.frames(Self.split(nil), file: file, route: route, from: 0.25, to: 1.75)
        try #require(film.count >= 44, "guard: the plain film has \(film.count) frames")
        for kind in VideoTransitionKind.allCases where kind.needsBothPictures {
            let drawn = try await Self.frames(Self.split(kind), file: file, route: route, from: 0.75, to: 1.25)
            try #require(drawn.count >= 14, "\(kind): \(drawn.count) frames")
            let unexplained = drawn.map { frame in film.map { Self.changed(frame, from: $0) }.min() ?? 0 }
            #expect((unexplained.max() ?? 0) >= 0.15,
                    "\(route) \(kind) on a split draws single moments of the film: \(unexplained.map { String(format: "%.2f", $0) })")
        }
    }

    /// ⚠️ **AND IT MEETS THE FILM EITHER SIDE WITHOUT A JUMP.** Each side is
    /// eased: the outgoing one leaves at its own pace, the incoming one arrives
    /// at its own pace, so the window's first frame is the plain film's, and so
    /// is the frame after its last. Read on the moving stripes, where a side
    /// that started a frame early or late would turn a whole stripe edge over.
    @Test func aDissolveOnASplitMeetsTheFilmAtBothEdges() async throws {
        let file = try await StripeClipWriter.clip()
        let plain = try await Self.frames(Self.split(nil), file: file, route: .export, from: 0.7, to: 1.3)
        let drawn = try await Self.frames(Self.split(.dissolve), file: file, route: .export, from: 0.7, to: 1.3)
        try #require(drawn.count == plain.count && drawn.count >= 17, "guard: \(drawn.count) and \(plain.count) frames")
        for (got, reference) in zip(drawn, plain) where got.time < 0.75 + 0.001 || got.time >= 1.25 - 0.001 {
            let off = Self.changed(got, from: reference)
            #expect(off <= 0.02, "at \(got.time)s the dissolve is not the plain film: \(off) of it differs")
        }
        let middle = zip(drawn, plain).filter { abs($0.0.time - 1.0) < 0.02 }.map { Self.changed($0, from: $1) }
        #expect((middle.max() ?? 0) >= 0.25, "guard: the cut itself shows one moment: \(middle)")
    }

    /// ⚠️ **ONLY FILM THE AUTHOR KEPT.** Red [0.5, 1.0) then blue [2.0, 2.5):
    /// the film just past either piece is GREEN — cut away. The handles this
    /// replaced blended that green into every kind; borrowed from the pieces,
    /// no green reaches the window at all. (The flash and the scan are left
    /// out: their own light is green.)
    @Test(arguments: Route.allCases)
    func aTransitionShowsOnlyFilmThePiecesKeep(route: Route) async throws {
        let file = try await ColourClipWriter.clip()
        for kind in VideoTransitionKind.allCases where kind.needsBothPictures && kind != .flash && kind != .copyMachine {
            let drawn = try await Self.frames([
                VideoExportSegment(start: 0.5, end: 1.0, transitionOut: kind),
                VideoExportSegment(start: 2.0, end: 2.5)
            ], file: file, route: route, from: 0.25, to: 0.75)
            try #require(drawn.count >= 14, "guard: \(kind) drew \(drawn.count) frames")
            let greenest = drawn.flatMap { Self.background($0) }
                .max { $0.colour.g - max($0.colour.r, $0.colour.b) < $1.colour.g - max($1.colour.r, $1.colour.b) }
            let colour = try #require(greenest).colour
            #expect(colour.g < max(colour.r, colour.b) + 40,
                    "\(route) \(kind) shows cut-away green film: \(colour)")
        }
    }

    // MARK: - The duration

    /// ⚠️ **A LONGER TRANSITION DRAWS OVER A LONGER WINDOW — IN BOTH ROUTES.**
    /// One second asked between red and blue: the window is [1.0, 2.0) around
    /// the cut at 1.5s, so at 1.2s a fifth of the blue is already in (~46 of
    /// 229), where the standard half second, [1.25, 1.75), has not opened — and
    /// at 0.95s the long one has not either.
    @Test(arguments: Route.allCases)
    func aTransitionRunsForTheSecondsItWasGiven(route: Route) async throws {
        let file = try await ColourClipWriter.clip()
        func pieces(_ seconds: Double) -> [VideoExportSegment] {
            [
                VideoExportSegment(start: 0, end: 1.5, transitionOut: .dissolve, transitionSeconds: seconds),
                VideoExportSegment(start: 2.0, end: 3.5)
            ]
        }
        func blue(_ frames: [Frame], at time: Double) throws -> Double {
            let frame = try #require(frames.min { abs($0.time - time) < abs($1.time - time) })
            let points = Self.background(frame)
            return Double(points.map(\.colour.b).reduce(0, +)) / Double(max(points.count, 1))
        }
        let long = try await Self.frames(pieces(1), file: file, route: route, from: 0.9, to: 1.25)
        let standard = try await Self.frames(pieces(0.5), file: file, route: route, from: 0.9, to: 1.25)
        #expect(try blue(long, at: 0.95) <= 12, "\(route): a one-second window opened before 1.0s")
        #expect(try blue(long, at: 1.2) >= 30, "\(route): a one-second window is not blending at 1.2s")
        #expect(try blue(standard, at: 1.2) <= 12, "guard: \(route) the standard window blends at 1.2s")

        if route == .export {
            let exported = try await VideoExporter().export(VideoExportPlan(sourceURL: file, segments: pieces(1)))
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }
            #expect(exported.transitionWindows == [1.0...2.0], "the file says it drew at \(exported.transitionWindows)")
        }
    }

}

/// **A TRANSITION'S LENGTH AND ITS EASING, AS ARITHMETIC** — the rules
/// `TransitionVisibilityTests` reads off the pixels, asked of the functions
/// that make them.
struct TransitionLengthTests {
    /// ⚠️ **NEVER MORE THAN THE SHORTER NEIGHBOUR CAN GIVE.** Two seconds asked
    /// between a 0.6s piece and a 1.5s one: each lends at most half of itself,
    /// so the window is 0.6s — [0.3, 0.9] — and the result is exactly as long as
    /// its pieces.
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
        #expect(arranged.windows == [0.3...0.9], "drew at \(arranged.windows)")
        let duration = try await arranged.asset.load(.duration).seconds
        #expect(abs(duration - 2.1) < 0.001, "the arrangement lasts \(duration)s")
    }

    // MARK: - The easing, as arithmetic

    /// ⚠️ **THE STEPS TILE THE WINDOW AND COVER THE FILM, EXACTLY** — the
    /// window is taken out of the arrangement's lane and put back as these, so
    /// a tick short or long moves everything after it.
    @Test(arguments: [0.0667, 0.25, 0.5, 1.0, 2.0])
    func theStepsTileTheWindowAndCoverTheFilm(half: Double) {
        let window = CMTimeRange(
            start: CMTime(value: 450, timescale: 600),
            duration: CMTime(value: CMTimeValue((half * 2 * 600).rounded()), timescale: 600)
        )
        let film = CMTimeRange(
            start: CMTime(value: 1200, timescale: 600),
            duration: CMTime(value: CMTimeValue((half * 600).rounded()), timescale: 600)
        )
        for easing in [VideoExporter.Easing.out, .in] {
            let steps = VideoExporter.steps(film: film, over: window, easing: easing)
            #expect(!steps.isEmpty)
            #expect(steps.first?.screen.start == window.start && steps.last?.screen.end == window.end,
                    "\(easing) \(half): the steps do not span the window")
            #expect(steps.first?.film.start == film.start && steps.last?.film.end == film.end,
                    "\(easing) \(half): the steps do not cover the film")
            for (one, next) in zip(steps, steps.dropFirst()) {
                #expect(one.screen.end == next.screen.start && one.film.end == next.film.start,
                        "\(easing) \(half): a gap between steps")
            }
            #expect(steps.allSatisfy { $0.film.duration > .zero && $0.screen.duration > .zero })
        }
    }

    /// ⚠️ **A SLIVER OF FILM LEAVES NO EMPTY STEP.** Three ticks eased in over
    /// half a second: the first steps round to no film at all, and an empty
    /// range cannot be inserted — their screen time goes to the next step, and
    /// the window is still tiled exactly.
    @Test func aSliverOfFilmFoldsItsEmptyStepsIntoTheNext() {
        let window = CMTimeRange(start: CMTime(value: 60, timescale: 600), duration: CMTime(value: 300, timescale: 600))
        let film = CMTimeRange(start: CMTime(value: 900, timescale: 600), duration: CMTime(value: 3, timescale: 600))
        for easing in [VideoExporter.Easing.out, .in] {
            let steps = VideoExporter.steps(film: film, over: window, easing: easing)
            #expect(!steps.isEmpty && steps.count < 7, "\(easing): \(steps.count) steps")
            #expect(steps.allSatisfy { $0.film.duration > .zero }, "\(easing): an empty step: \(steps)")
            #expect(steps.first?.screen.start == window.start && steps.last?.screen.end == window.end,
                    "\(easing): the steps do not span the window")
            #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.screen.end == $1.screen.start },
                    "\(easing): a gap between steps")
        }
    }

    /// ⚠️ **AT THE PIECE'S OWN PACE WHERE IT IS ALL THAT IS SEEN.** The outgoing
    /// side leaves the window's opening close to its rate and ends nearly
    /// still; the incoming side is the mirror. A linear map would play both at
    /// half pace from the first frame — a visible slow-down on a picture the
    /// window has not started to blend.
    @Test func theSidesAreEasedTowardsTheirOwnPace() {
        let window = CMTimeRange(start: .zero, duration: CMTime(value: 300, timescale: 600))
        let film = CMTimeRange(start: CMTime(value: 600, timescale: 600), duration: CMTime(value: 150, timescale: 600))
        func paces(_ easing: VideoExporter.Easing) -> [Double] {
            VideoExporter.steps(film: film, over: window, easing: easing)
                .map { $0.film.duration.seconds / $0.screen.duration.seconds }
        }
        let leaving = paces(.out)
        let arriving = paces(.in)
        #expect(leaving.count >= 6, "a half-second window in \(leaving.count) steps")
        #expect((leaving.first ?? 0) >= 0.8 && (leaving.last ?? 1) <= 0.2, "leaving at \(leaving)")
        #expect((arriving.first ?? 1) <= 0.2 && (arriving.last ?? 0) >= 0.8, "arriving at \(arriving)")
        #expect(zip(leaving, leaving.dropFirst()).allSatisfy { $0 > $1 }, "the outgoing side does not slow: \(leaving)")
        #expect(zip(arriving, arriving.dropFirst()).allSatisfy { $0 < $1 }, "the incoming side does not speed up: \(arriving)")
    }

    /// The reach, as arithmetic: half the seconds asked, never more than half
    /// of either neighbour, on the 1/600 grid, nothing under a frame.
    @Test func theReachIsHalfWhatWasAskedWithinTheNeighbours() {
        #expect(VideoExporter.transitionHalf(.dissolve, outgoingPlayedSeconds: 3, incomingPlayedSeconds: 3) == 0.25)
        #expect(VideoExporter.transitionHalf(.dissolve, seconds: 1.5, outgoingPlayedSeconds: 3, incomingPlayedSeconds: 3) == 0.75)
        #expect(VideoExporter.transitionHalf(.dissolve, seconds: 2, outgoingPlayedSeconds: 3, incomingPlayedSeconds: 1.2) == 0.6)
        #expect(VideoExporter.transitionHalf(.dissolve, seconds: 2, outgoingPlayedSeconds: 0.9, incomingPlayedSeconds: 3) == 0.45)
        #expect(VideoExporter.transitionHalf(.dissolve, seconds: 0.05, outgoingPlayedSeconds: 3, incomingPlayedSeconds: 3) == 0)
        #expect(VideoExporter.transitionHalf(nil, seconds: 1, outgoingPlayedSeconds: 3, incomingPlayedSeconds: 3) == 0)
    }

    /// ⚠️ **A LENGTH ON A PLAIN CUT IS NOT STORED** — the initialiser puts the
    /// standard there, so two plain pieces compare equal whatever was passed.
    @Test func aPlainCutCarriesNoLength() {
        #expect(VideoExportSegment(start: 0, end: 1, transitionSeconds: 2) == VideoExportSegment(start: 0, end: 1))
        #expect(VideoExportSegment(start: 0, end: 1, transitionOut: .dissolve, transitionSeconds: 2).transitionSeconds == 2)
    }
}
