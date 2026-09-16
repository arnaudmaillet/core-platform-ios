import Foundation
import Testing
import UIKit
@testable import Upload

/// Tracks laid out on their own, for the suites that ask what is DRAWN.
@MainActor
enum TrackFixture {
    static let threeCuts = [
        MediaSegment(start: 0, end: 3, speed: 1),
        MediaSegment(start: 3, end: 6, speed: 1),
        MediaSegment(start: 6, end: 9, speed: 1)
    ]

    /// A track cut into `segments` — three three-second pieces by default — laid
    /// out at rest, with `piece` held and `poster` handed over before the first
    /// layout.
    static func cutInThree(
        holding piece: Int?, segments: [MediaSegment] = threeCuts, duration: Double = 12,
        poster: UIImage? = nil, width: CGFloat = 390
    ) -> MediaTimelineTrackView {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: width, height: MediaTimelineTrackView.height)
        track.showPoster(poster)
        track.configure(duration: duration, timeline: MediaTimeline(segments: segments))
        track.setNeedsLayout()
        track.layoutIfNeeded()
        if let piece {
            track.select(piece)
            track.layoutIfNeeded()
        }
        return track
    }

    /// One flat colour, opaque.
    static func swatch(_ colour: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

/// ⚠️ **ASKED FOR IN THE AUTHOR'S WORDS**: *"séparer les segments avec un léger
/// espace et arrondir les bords"*, and *"que le cadre intérieur des pinces de
/// sélection ait aussi des bordures intérieures arrondies, ce qui matcherait avec
/// les coins arrondis des segments"*. Every assertion here reads a view or a
/// layer that is on screen — or its pixels — never the arithmetic that placed it.
@MainActor
struct MediaTimelineTrackDrawingTests {
    private func inside(_ inner: CGRect, _ outer: CGRect) -> Bool {
        inner.minX >= outer.minX - 0.01 && inner.maxX <= outer.maxX + 0.01
    }

    private func windowFrames(_ track: MediaTimelineTrackView) -> [Int: CGRect] {
        Dictionary(uniqueKeysWithValues: track.debugFilmWindows.map { ($0.piece, $0.frame) })
    }

    // MARK: - The pieces

    /// ⚠️ **EVERY PIECE IS ROUNDED AT ITS OWN ENDS — BY ITS WINDOW, NOT BY A
    /// SQUARE.** And only at the ends a window actually shows: at rest the third
    /// piece runs off the band, so its trailing corners are not there to round.
    @Test func everyPieceIsRoundedAtItsOwnEnds() throws {
        let track = TrackFixture.cutInThree(holding: nil)
        let all: CACornerMask = [
            .layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner
        ]
        let leading: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]

        let open = track.debugFilmWindows
        try #require(open.count == 3, "got \(open.map(\.frame))")
        for window in open {
            #expect(window.radius == MediaTimelineTrackView.debugFilmCorner, "got \(window)")
            #expect(window.clips && window.curve == .continuous, "got \(window)")
        }
        #expect(open[0].corners == all && open[1].corners == all,
                "a whole piece is not rounded all round: \(open.map(\.corners))")
        #expect(open[2].corners == leading, "a corner off the band is rounded: \(open[2].corners)")

        track.debugScroll(toContentOffset: 300)
        track.layoutIfNeeded()
        #expect(track.debugFilmWindows.last?.corners == all, "the last piece's end is not rounded")
        #expect(track.debugTiles.allSatisfy { $0.cornerRadius == 0 }, "a square carries a radius")
    }

    /// ⚠️ **A SLIVER AT THE END OF THE FILM STILL ENDS ON A WHOLE CORNER.** Ten
    /// seconds is 600pt and a square is 54, so the last square is six points
    /// wide — rounded on its own it could not carry an eight-point curve.
    @Test func aSliverAtTheEndOfTheFilmStillEndsOnAWholeCorner() throws {
        let track = TrackFixture.cutInThree(holding: nil, segments: [], duration: 10)
        track.debugScroll(toContentOffset: 600 - 195)
        track.layoutIfNeeded()

        let last = try #require(track.debugTiles.last)
        #expect(abs(last.frame.width - 6) < 0.01, "guard: the last square is \(last.frame.width)pt")
        #expect(last.cornerRadius == 0, "the sliver rounds itself")
        let window = try #require(track.debugFilmWindows.last)
        #expect(abs(window.frame.maxX - 600) < 0.01, "the window ends at \(window.frame.maxX)")
        #expect(window.corners.contains(.layerMaxXMaxYCorner) && window.radius == 8,
                "the end is not one whole corner: \(window)")
    }

    /// ⚠️ **ZOOMED OUT, A SLIVER IS A PILL AND NEVER A SPIKE.** One second at 4×
    /// is three points at 12pt/s; Core Animation does not clamp a radius, so the
    /// track has to.
    @Test func aZoomedOutSliverIsAPillAndNeverASpike() throws {
        let segments = [
            MediaSegment(start: 0, end: 5), MediaSegment(start: 5, end: 6, speed: 4),
            MediaSegment(start: 6, end: 10)
        ]
        let track = TrackFixture.cutInThree(
            holding: nil, segments: segments, duration: 10, poster: TrackFixture.swatch(.blue)
        )
        for _ in 0..<10 { track.debugPinch(by: 0.2) }
        track.layoutIfNeeded()
        try #require(track.debugPointsPerSecond == 12, "guard: \(track.debugPointsPerSecond)pt/s")

        let open = track.debugFilmWindows
        try #require(open.count == 3, "got \(open.map(\.frame))")
        for window in open {
            #expect(window.frame.width > 0, "a piece with an empty window: \(window)")
            #expect(window.radius <= window.frame.width / 2 + 0.001, "a spike: \(window)")
        }
        for (left, right) in zip(open, open.dropFirst()) {
            #expect(left.frame.maxX <= right.frame.minX + 0.001, "windows overlap: \(left) \(right)")
        }
        let frames = windowFrames(track)
        for tile in track.debugTiles {
            #expect(tile.frame.width > 0, "an empty square: \(tile)")
            #expect(frames[tile.place.piece].map { inside(tile.frame, $0) } == true,
                    "a square outside its window: \(tile)")
        }

        track.select(1)
        track.layoutIfNeeded()
        let held = try #require(windowFrames(track)[1])
        #expect(track.debugStartGrip.maxX <= track.debugEndGrip.minX + 0.001, "the caps cross")
        let plates = track.debugFillets.map(\.frame)
        #expect(plates[0].maxX <= held.maxX + 0.001 && plates[1].minX >= held.minX - 0.001,
                "a plate reaches past the sliver: \(plates) around \(held)")
    }

    /// ⚠️ **TAKING A PIECE CHANGES THAT PIECE'S FILM AND NO OTHER.** The held
    /// piece keeps its half-daylights; its neighbours keep theirs.
    @Test func holdingAPieceMovesNoOtherPiecesFilm() throws {
        let track = TrackFixture.cutInThree(holding: nil)
        let free = windowFrames(track)
        track.select(1)
        track.layoutIfNeeded()
        let held = windowFrames(track)
        let half = MediaTimelineTrackView.debugSeamGap / 2

        #expect(held[0] == free[0] && held[2] == free[2], "a neighbour moved: \(free) → \(held)")
        let before = try #require(free[1])
        let after = try #require(held[1])
        #expect(abs(after.minX - (before.minX - half)) < 0.01 && abs(after.maxX - (before.maxX + half)) < 0.01,
                "the held piece did not take back its daylight: \(before) → \(after)")
    }

    /// ⚠️ **THE DAYLIGHT IS NOT A DEAD ZONE.** Which piece a finger is on is asked
    /// of the clock, where the pieces touch.
    @Test func aTapInTheDaylightTakesThePieceOnThatSide() throws {
        let track = TrackFixture.cutInThree(
            holding: nil,
            segments: [MediaSegment(start: 0, end: 5), MediaSegment(start: 5, end: 10)],
            duration: 10
        )
        let seam = try #require(track.debugPieceFrames.first?.upperBound)

        track.debugTap(atContentX: seam + 0.5)
        track.layoutIfNeeded()
        #expect(track.debugSelectedPiece == 1, "the right half of the daylight took nothing")
        #expect(track.debugSelectionIsDrawn)

        track.debugTap(atContentX: 100_000)
        track.debugTap(atContentX: seam - 0.5)
        track.layoutIfNeeded()
        #expect(track.debugSelectedPiece == 0, "the left half of the daylight took nothing")
        #expect(track.debugSelectionIsDrawn)
    }

    /// ⚠️ **A CARRY RENUMBERS THE PIECES, AND EVERY SQUARE STILL STANDS IN ITS OWN
    /// PIECE'S WINDOW.**
    @Test func aCarriedOrderKeepsEveryTileInsideItsOwnPiecesWindow() throws {
        let track = TrackFixture.cutInThree(holding: nil)
        track.debugLift(atContentX: 370)
        try #require(track.debugCarrying == 2, "guard: the last piece was lifted")
        track.layoutIfNeeded()
        track.debugCarry(toTrackX: 20)
        track.debugDrop()
        track.layoutIfNeeded()

        let order = MediaTimelining.resolved(track.debugTimeline, withinSource: 12)
        #expect(order.first?.start == 6, "guard: the order did not change: \(order)")
        let frames = windowFrames(track)
        for tile in track.debugTiles {
            #expect(tile.windowPiece == tile.place.piece, "a square in another piece's window: \(tile)")
            let window = try #require(frames[tile.place.piece])
            #expect(inside(tile.frame, window), "a square outside its window: \(tile) in \(window)")
        }
    }

    /// A rate's stamp stays on its own film, clear of the held piece's cap, and
    /// under the selection's ink.
    @Test func aStampStaysOnItsOwnFilmAndUnderTheFrame() throws {
        let segments = [
            MediaSegment(start: 0, end: 3), MediaSegment(start: 3, end: 6, speed: 2),
            MediaSegment(start: 6, end: 9)
        ]
        let track = TrackFixture.cutInThree(holding: nil, segments: segments)
        let inset = MediaTimelineTrackView.debugStampInset
        let window = try #require(windowFrames(track)[1])
        let stamp = try #require(track.debugRateStampFrames.first)
        #expect(stamp.minX >= window.minX + inset - 0.01 && stamp.maxX <= window.maxX + 0.01,
                "the stamp leaves its film: \(stamp) in \(window)")

        track.select(0)
        track.layoutIfNeeded()
        let held = try #require(track.debugRateStampFrames.first)
        #expect(held.minX >= track.debugEndGrip.maxX + inset - 0.01,
                "the stamp sits under the held piece's cap: \(held) against \(track.debugEndGrip)")
        #expect(track.debugStampIsUnderTheFrame, "a stamp is drawn over the frame")

        // And it stops before the opening cap of the piece AFTER it.
        track.select(2)
        track.debugScroll(toContentOffset: 250)
        track.layoutIfNeeded()
        let before = try #require(track.debugRateStampFrames.first)
        #expect(before.maxX <= track.debugStartGrip.minX - inset + 0.01,
                "the stamp sits under the next piece's cap: \(before) against \(track.debugStartGrip)")
    }

    // MARK: - The frame

    /// ⚠️ **THE FRAME CLOSES AROUND AN INTERIOR PIECE TOO.** The caps stand on its
    /// cut; the neighbours' carved ends lie under them.
    @Test func theFrameClosesAroundAnInteriorPieceToo() throws {
        let track = TrackFixture.cutInThree(holding: 1)
        let start = track.debugStartGrip
        let end = track.debugEndGrip
        let top = track.debugTopRail
        let pieces = track.debugPieceFrames
        let open = windowFrames(track)
        let held = try #require(open[1])
        let half = MediaTimelineTrackView.debugSeamGap / 2

        #expect(top.minX >= start.minX && top.maxX <= end.maxX, "a rail sticks out: \(top)")
        #expect(top.minX < start.maxX && top.maxX > end.minX, "a rail stops short of a cap: \(top)")
        let corner = track.debugCapShapes.first?.radius ?? 0
        for rail in [top, track.debugBottomRail] {
            #expect(rail.minX - start.minX >= corner - 0.01 && end.maxX - rail.maxX >= corner - 0.01,
                    "a rail shows beside a cap's outer curve: \(rail) between \(start) and \(end)")
        }
        #expect(abs(start.maxX - held.minX) < 0.01 && abs(held.minX - pieces[1].lowerBound) < 0.01,
                "the opening cap is not on the cut: \(start) \(held) \(pieces[1])")
        #expect(abs(end.minX - held.maxX) < 0.01 && abs(held.maxX - pieces[1].upperBound) < 0.01,
                "the closing cap is not on the cut: \(end) \(held) \(pieces[1])")
        let before = try #require(open[0])
        let after = try #require(open[2])
        #expect(abs(before.maxX - (start.maxX - half)) < 0.01 && before.maxX >= start.minX,
                "the previous piece's end is not under the cap: \(before) \(start)")
        #expect(abs(after.minX - (end.minX + half)) < 0.01 && after.minX <= end.maxX,
                "the next piece's start is not under the cap: \(after) \(end)")
    }

    /// ⚠️ **THE REACH IS WHERE THE CAP IS DRAWN.** One source, so a cap cannot
    /// move without its reach.
    @Test func theHandleIsWhereItsCapIsDrawn() throws {
        let track = TrackFixture.cutInThree(holding: 1)
        let centres = try #require(track.debugHandleCentres)
        let caps = try #require(track.debugHeldCaps)

        #expect(abs(centres.start - track.debugStartGrip.midX) < 0.01, "got \(centres)")
        #expect(abs(centres.end - track.debugEndGrip.midX) < 0.01, "got \(centres)")
        #expect(abs(caps.start.upperBound - track.debugStartGrip.maxX) < 0.01, "got \(caps)")
        #expect(abs(caps.end.lowerBound - track.debugEndGrip.minX) < 0.01, "got \(caps)")
        #expect(track.debugWouldTakeAHandle(at: track.debugStartGrip.midX))
    }

    /// ⚠️ **THE INNER CORNERS ARE PLATES BEHIND THE FILM**, reaching as far as
    /// the film's rounded corner and tucked under the caps and the rails.
    @Test func theInnerCornersAreFilledFromBehindTheFilm() throws {
        let track = TrackFixture.cutInThree(holding: 1, poster: TrackFixture.swatch(.blue))
        let plates = track.debugFillets
        try #require(plates.count == 4)
        for plate in plates {
            #expect(plate.isShowing && plate.isBehindTheFilm && plate.isWhite, "got \(plate)")
            #expect(!plate.hasCorners && !plate.hasShadow, "a plate is shaped itself: \(plate)")
        }
        let window = try #require(track.debugFilmWindows.first { $0.piece == 1 })
        let tuck = MediaTimelineTrackView.debugFilletTuck
        let reach = MediaTimelining.cornerReach * window.radius
        let start = track.debugStartGrip
        let end = track.debugEndGrip
        let (tl, tr, bl, br) = (plates[0].frame, plates[1].frame, plates[2].frame, plates[3].frame)

        #expect(abs(tl.minX - (start.maxX - tuck)) < 0.01 && abs(tl.minY - track.debugTopRail.minY) < 0.01,
                "the top leading plate is not tucked: \(tl)")
        #expect(abs(tr.maxX - (end.minX + tuck)) < 0.01 && abs(tr.minY - track.debugTopRail.minY) < 0.01,
                "the top trailing plate is not tucked: \(tr)")
        #expect(abs(bl.maxY - track.debugBottomRail.maxY) < 0.01 && abs(br.maxY - track.debugBottomRail.maxY) < 0.01,
                "a bottom plate is not tucked: \(bl) \(br)")
        #expect(tl.maxX >= window.frame.minX + reach && bl.maxX >= window.frame.minX + reach,
                "a leading plate stops short of the corner: \(tl) \(bl)")
        #expect(tr.minX <= window.frame.maxX - reach && br.minX <= window.frame.maxX - reach,
                "a trailing plate stops short of the corner: \(tr) \(br)")
        let strip = track.debugStripY
        #expect(tl.maxY >= strip + reach && bl.minY <= strip + MediaTimelineTrackView.debugStrip - reach,
                "a plate stops short of the corner's height: \(tl) \(bl)")
    }

    /// ⚠️ **NO PLATES WHILE THERE IS NO FILM IN FRONT OF THEM** — a transparent
    /// square over a white plate is a white block inside the frame.
    @Test func withNoPictureTheFrameShowsNoFillets() {
        let track = TrackFixture.cutInThree(holding: 1)

        #expect(track.debugSelectionInkShowing, "guard: the frame is drawn")
        #expect(track.debugFillets.allSatisfy { !$0.isShowing }, "a plate shows over no film")
        #expect(track.debugSelectionIsDrawn)

        track.showPoster(TrackFixture.swatch(.blue))
        track.layoutIfNeeded()
        #expect(track.debugFillets.allSatisfy { $0.isShowing }, "the plates never came back")
    }

    /// ⚠️ **THE FIRST PICTURE BRINGS THE PLATES, WITHOUT ANYONE ELSE ASKING FOR A
    /// LAYOUT.**
    @Test func theFilletsAppearWhenTheFirstFrameLands() async throws {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        let red = TrackFixture.swatch(.red)
        track.framesProvider = { seconds, _, _ in
            await MainActor.run { Dictionary(uniqueKeysWithValues: seconds.map { ($0, red) }) }
        }
        track.configure(duration: 12, timeline: MediaTimeline(segments: TrackFixture.threeCuts))
        track.setNeedsLayout()
        track.layoutIfNeeded()
        track.select(0)
        // Laid out NOW, while there is no film: from here on only the arrival of
        // the first picture can ask for another layout.
        track.layoutIfNeeded()
        #expect(track.debugFillets.allSatisfy { !$0.isShowing }, "guard: there is no film yet")

        for _ in 0..<300 where !track.debugEveryTileHasAPicture {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(track.debugEveryTileHasAPicture, "the film never arrived")
        track.layoutIfNeeded()

        #expect(track.debugFillets.allSatisfy { $0.isShowing }, "the plates waited for somebody else")
    }

    /// ⚠️ **A CAP IS ROUNDED ONLY OUTSIDE, AND CASTS ITS SHADOW ONLY OUTWARDS.**
    /// Six points is the most a twelve-point cap rounded on one side draws
    /// cleanly; the shadow's own path keeps it off the plates and the film.
    @Test func aCapIsRoundedOnlyOutsideAndShadowsOnlyOutwards() throws {
        let track = TrackFixture.cutInThree(holding: 1)
        let caps = track.debugCapShapes
        try #require(caps.count == 2)

        for cap in caps {
            #expect(cap.radius == 6, "the caps are rounded to \(cap.radius), not six")
            #expect(cap.radius * 2 <= cap.width + 0.001, "a spike: \(cap)")
            #expect(cap.shadowRadius > 0, "the caps cast no shadow")
        }
        #expect(caps[0].corners == [.layerMinXMinYCorner, .layerMinXMaxYCorner], "got \(caps[0].corners)")
        #expect(caps[1].corners == [.layerMaxXMinYCorner, .layerMaxXMaxYCorner], "got \(caps[1].corners)")
        let opening = try #require(caps[0].shadowPath, "the opening cap has no shadow path")
        let closing = try #require(caps[1].shadowPath, "the closing cap has no shadow path")
        // Kept off the inner side by the blur the layer ACTUALLY has.
        #expect(opening.boundingBoxOfPath.maxX <= caps[0].width - 2 * caps[0].shadowRadius + 0.01,
                "the shadow falls inwards: \(opening.boundingBoxOfPath)")
        #expect(closing.boundingBoxOfPath.minX >= 2 * caps[1].shadowRadius - 0.01,
                "the shadow falls inwards: \(closing.boundingBoxOfPath)")
        // And shaped like the cap: rounded outside, straight along its middle.
        let middle = caps[0].height / 2
        #expect(!opening.contains(CGPoint(x: 0.5, y: 0.5)), "the shadow has a square outer corner")
        #expect(opening.contains(CGPoint(x: 0.5, y: middle)), "the shadow misses the cap's outer edge")
        #expect(!closing.contains(CGPoint(x: caps[1].width - 0.5, y: 0.5)), "the shadow has a square outer corner")
        #expect(closing.contains(CGPoint(x: caps[1].width - 0.5, y: middle)), "the shadow misses the cap's outer edge")
    }

    // MARK: - Nothing on the film or the frame slides in

    private func hosted(_ track: MediaTimelineTrackView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.addSubview(track)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    /// ⚠️ **AN EASED FOLLOW MOVES THE SCROLLER, AND NOTHING ELSE.** A scroll does
    /// not move film in content coordinates; animated, a window slid towards its
    /// new hull while the squares born in it were placed against where it was
    /// going, and a window from the pool rounded its corners up from nothing.
    @Test func theFilmIsNeverAnimatedWhenTheOffsetEases() throws {
        let track = TrackFixture.cutInThree(
            holding: nil, segments: [], duration: 30, poster: TrackFixture.swatch(.blue)
        )
        let window = hosted(track)
        defer { window.isHidden = true }
        let before = Set(track.debugTiles.map(\.place))

        UIView.animate(withDuration: 0.5) {
            track.debugScroll(toContentOffset: 1200)
        }

        #expect(track.debugScrollIsAnimating, "guard: the offset did not ease")
        #expect(Set(track.debugTiles.map(\.place)) != before, "guard: the ease laid out no new film")
        #expect(track.debugFilmAnimations.isEmpty,
                "the film animates with the offset: \(track.debugFilmAnimations)")
    }

    /// ⚠️ **A FRAME THAT APPEARS IS PLACED AT ONCE** — a lift selects inside the
    /// carry's spring, and a frame growing out of the content's origin showed
    /// the plates' tucked edges beside it. The witness: a frame that stays on
    /// the same piece still moves with the animation around it.
    @Test func aFrameThatAppearsIsPlacedAtOnce() {
        let track = TrackFixture.cutInThree(holding: nil, poster: TrackFixture.swatch(.blue))
        let window = hosted(track)
        defer { window.isHidden = true }

        UIView.animate(withDuration: 0.5) {
            track.select(1)
            track.layoutIfNeeded()
        }
        #expect(track.debugSelectionIsDrawn, "guard: nothing is framed")
        #expect(track.debugFrameAnimations.isEmpty,
                "the frame slid in: \(track.debugFrameAnimations)")
        track.layer.removeAllAnimations()

        UIView.animate(withDuration: 0.5) {
            track.configure(duration: 12, timeline: MediaTimeline(segments: [
                MediaSegment(start: 0, end: 3), MediaSegment(start: 3, end: 7),
                MediaSegment(start: 7, end: 9)
            ]))
            track.layoutIfNeeded()
        }
        #expect(!track.debugFrameAnimations.isEmpty, "the witness: a held frame no longer moves with its piece")
    }

    /// ⚠️ **EACH HALF OF THE DAYLIGHT LANDS ON THE PIXEL GRID OF THE SCREEN THE
    /// TRACK IS ON.** A 2.1pt piece at 2x floors its halves to half points.
    @Test func theDaylightIsFlooredToTheScreenTheTrackIsOn() throws {
        let segments = [
            MediaSegment(start: 0, end: 5), MediaSegment(start: 5, end: 5.7, speed: 4),
            MediaSegment(start: 5.7, end: 10)
        ]
        let track = TrackFixture.cutInThree(
            holding: nil, segments: segments, duration: 10, poster: TrackFixture.swatch(.blue)
        )
        track.traitOverrides.displayScale = 2
        track.updateTraitsIfNeeded()
        try #require(track.traitCollection.displayScale == 2, "guard: the scale did not take")
        for _ in 0..<10 { track.debugPinch(by: 0.2) }
        track.setNeedsLayout()
        track.layoutIfNeeded()

        let pieces = track.debugPieceFrames
        let open = track.debugFilmWindows
        try #require(open.count == 3 && pieces.count == 3, "got \(open.map(\.frame))")
        let carved = [
            pieces[0].upperBound - open[0].frame.maxX,
            open[1].frame.minX - pieces[1].lowerBound,
            pieces[1].upperBound - open[1].frame.maxX,
            open[2].frame.minX - pieces[2].lowerBound
        ]
        #expect(carved.allSatisfy { $0 > 0 }, "guard: nothing was carved: \(carved)")
        for half in carved {
            #expect(abs(half * 2 - (half * 2).rounded()) < 0.001, "a half off the 2x grid: \(carved)")
        }
    }

    // MARK: - Pixels

    /// The track drawn by the CPU renderer at 3x, read as RGBA.
    private func pixels(of track: MediaTimelineTrackView) -> (CGFloat, CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
        let scale: CGFloat = 3
        let width = Int(track.bounds.width * scale)
        let height = Int(track.bounds.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            track.layer.render(in: context)
        }
        return { x, y in
            let column = min(max(Int(x * scale), 0), width - 1)
            let row = min(max(Int(y * scale), 0), height - 1)
            let at = (row * width + column) * 4
            return (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]), Int(bytes[at + 3]))
        }
    }

    /// ⚠️ **THE INNER CORNER IS WHITE AND THE FILM INSIDE IT IS NOT — IN PIXELS.**
    ///
    /// ⚠️ **ONLY WINDOWS ROUNDED ALL ROUND ARE SAMPLED.** The CPU renderer rounds
    /// all four corners whatever `maskedCorners` says (measured), so a window
    /// rounded on one side would read the same as one rounded on both. The two
    /// guards at the far ends prove this renderer does clip and round at all.
    @Test func theInnerCornerIsWhiteAndTheFilmInsideItIsNot() throws {
        let segments = (0..<4).map { MediaSegment(start: Double($0), end: Double($0 + 1)) }
        let track = TrackFixture.cutInThree(
            holding: 1, segments: segments, duration: 4, poster: TrackFixture.swatch(.blue)
        )
        track.debugScroll(toContentOffset: -60)
        track.layoutIfNeeded()
        // Track x = content x + 60: the held piece is 120…180, the film 19.5…73.5.
        let strip = track.debugStripY
        let bottom = strip + MediaTimelineTrackView.debugStrip
        let read = pixels(of: track)
        let white = { (p: (r: Int, g: Int, b: Int, a: Int)) in p.r > 200 && p.g > 200 && p.b > 200 && p.a > 200 }
        let blue = { (p: (r: Int, g: Int, b: Int, a: Int)) in p.b > 200 && p.r < 60 && p.g < 60 && p.a > 200 }

        // The guards: the unheld pieces' own outer corners are rounded away.
        #expect(read(60.4, strip + 0.4).a < 25, "the renderer did not round: \(read(60.4, strip + 0.4))")
        #expect(read(299.6, strip + 0.4).a < 25, "the renderer did not round: \(read(299.6, strip + 0.4))")
        #expect(blue(read(90, 46.5)), "guard: the film is not blue: \(read(90, 46.5))")

        #expect(white(read(120.7, strip + 0.7)), "the top leading inner corner: \(read(120.7, strip + 0.7))")
        #expect(white(read(179.3, bottom - 0.7)), "the bottom trailing inner corner: \(read(179.3, bottom - 0.7))")
        #expect(blue(read(128, strip + 8)), "the film inside the corner is not film: \(read(128, strip + 8))")
        #expect(read(240, 46.5).a < 25, "no daylight between the last two pieces: \(read(240, 46.5))")
    }

    // MARK: - Charter T6

    /// ⚠️ **NO LAYER PAST THE METAL LIMIT IS ROUNDED, MASKED, CLIPPING, OR
    /// SHADOWED.** A four-minute piece is 14400pt, 43200px at 3x; the windows
    /// that round it must follow the band, not the piece.
    @Test func noLayerPastTheMetalLimitIsRoundedMaskedClippedOrShadowed() {
        let track = TrackFixture.cutInThree(
            holding: 0, segments: [], duration: 240, poster: TrackFixture.swatch(.blue)
        )
        track.debugScroll(toContentOffset: 7000)
        track.layoutIfNeeded()

        #expect(track.debugContentWidth > 5461, "guard: the film is not long enough to matter")
        #expect(!track.debugFilmWindows.isEmpty, "guard: no window was laid out")
        #expect(track.debugTopRail.width > 5461, "guard: no wide plain layer to leave alone")
        #expect(track.debugLayersPastTheMetalLimit(scale: 3).isEmpty,
                "\(track.debugLayersPastTheMetalLimit(scale: 3))")
    }
}
