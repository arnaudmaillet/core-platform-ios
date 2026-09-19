import Foundation
import MediaPlayback
import Testing
@testable import Upload

/// **A TRANSITION BELONGS TO THE PIECE BEFORE ITS CUT**, and every edit has to
/// keep it, move it with that piece, or drop it where no cut is left — asked of
/// the arithmetic, one edit at a time, on a ten-second file.
struct MediaTransitionModelTests {
    private let duration = 10.0

    private func timeline(_ pieces: [(Double, Double, Double, VideoTransitionKind?)]) -> MediaTimeline {
        MediaTimeline(segments: pieces.map {
            MediaSegment(start: $0.0, end: $0.1, speed: $0.2, transitionOut: $0.3)
        })
    }

    private func kinds(_ timeline: MediaTimeline) -> [VideoTransitionKind?] {
        MediaTimelining.resolved(timeline, withinSource: duration).map(\.transitionOut)
    }

    // MARK: - Every edit keeps it

    @Test func aTrimKeepsTheTransition() {
        let cut = timeline([(0, 4, 1, .dipToBlack), (4, 10, 1, nil)])

        let trimmed = MediaTimelining.moved(
            cut, piece: 0, edge: .end, bySourceSeconds: -1, withinSource: duration
        )

        #expect(trimmed.segments.first?.end == 3, "guard: the trim did nothing")
        #expect(kinds(trimmed) == [.dipToBlack, nil], "the trim lost the transition: \(kinds(trimmed))")
    }

    @Test func aRateKeepsTheTransition() {
        let cut = timeline([(0, 4, 1, .dipToWhite), (4, 10, 1, nil)])

        let fast = MediaTimelining.setRate(2, atPiece: 0, in: cut, withinSource: duration)

        #expect(fast.segments.first?.speed == 2, "guard: the rate did nothing")
        #expect(kinds(fast) == [.dipToWhite, nil], "the rate lost the transition: \(kinds(fast))")
    }

    /// ⚠️ **THE RIGHT HALF KEEPS IT** — the cut it names is still after that
    /// half; the new cut in the middle is a plain one.
    @Test func aSplitHandsTheTransitionToTheRightHalf() {
        let cut = timeline([(0, 4, 1, .dipToBlack), (4, 10, 1, nil)])

        let split = MediaTimelining.split(cut, atPiece: 0, atSourceSeconds: 2, withinSource: duration)

        #expect(kinds(split) == [nil, .dipToBlack, nil], "got \(kinds(split))")
    }

    /// ⚠️ **A CARRY IS A PURE PERMUTATION UNTIL THE PIECE IS PUT DOWN.** It is
    /// applied at every crossing; one that comes back must be what was lifted.
    @Test func aCarryOutAndBackIsTheLiftedTimeline() {
        let lifted = timeline([(0, 3, 1, .dipToBlack), (3, 6, 1, .dipToWhite), (6, 10, 1, nil)])

        let out = MediaTimelining.reordered(lifted, move: 0, to: 2, withinSource: duration)
        let back = MediaTimelining.reordered(out, move: 2, to: 0, withinSource: duration)

        #expect(back == lifted, "a carry out and back changed the timeline: \(back)")
    }

    @Test func aCarryMovesTheTransitionWithItsOutgoingPiece() {
        let lifted = timeline([(0, 3, 1, .dipToBlack), (3, 6, 1, .dipToWhite), (6, 10, 1, nil)])

        let moved = MediaTimelining.reordered(lifted, move: 0, to: 1, withinSource: duration)

        #expect(kinds(moved) == [.dipToWhite, .dipToBlack, nil], "got \(kinds(moved))")
    }

    @Test func settledClearsOnlyTheLastPiece() {
        let stale = timeline([(0, 3, 1, .dipToBlack), (3, 6, 1, .dipToWhite)])
        #expect(kinds(MediaTimelining.settled(stale)) == [.dipToBlack, nil])

        let fine = timeline([(0, 3, 1, .zoom), (3, 6, 1, nil)])
        #expect(MediaTimelining.settled(fine) == fine)
        #expect(MediaTimelining.settled(.whole) == .whole)
    }

    /// ⚠️ **ONLY A REAL CUT TAKES ONE**; `nil` takes it away.
    @Test func aSeamOutsideTheTimelineIsRefused() {
        #expect(MediaTimelining.settingTransition(.zoom, atSeam: 0, in: .whole, withinSource: duration) == .whole)
        let single = timeline([(2, 8, 1, nil)])
        #expect(MediaTimelining.settingTransition(.zoom, atSeam: 0, in: single, withinSource: duration) == single)
        let two = timeline([(0, 4, 1, nil), (4, 10, 1, nil)])
        #expect(MediaTimelining.settingTransition(.zoom, atSeam: -1, in: two, withinSource: duration) == two)
        #expect(MediaTimelining.settingTransition(.zoom, atSeam: 1, in: two, withinSource: duration) == two)

        let set = MediaTimelining.settingTransition(.zoom, atSeam: 0, in: two, withinSource: duration)
        #expect(kinds(set) == [.zoom, nil])
        #expect(MediaTimelining.transition(atSeam: 0, in: set, withinSource: duration) == .zoom)
        let removed = MediaTimelining.settingTransition(nil, atSeam: 0, in: set, withinSource: duration)
        #expect(kinds(removed) == [nil, nil], "nil did not remove it: \(kinds(removed))")
    }

    // MARK: - How far it reaches

    /// ⚠️ **A TRANSITION OVERLAPS ITS TWO PIECES, AND THE CUT IS DRAWN AT THE
    /// MIDDLE OF THE OVERLAP.** Four seconds then six, overlapping by the
    /// standard half second: the incoming piece starts at 3.5s, the outgoing
    /// one ends at 4.0s, the cut is drawn at 3.75s, and the result is 9.5s.
    @Test func aTransitionOverlapsItsPiecesAndIsDrawnAtTheMiddle() {
        let cut = timeline([(0, 4, 1, .dipToBlack), (4, 10, 1, nil)])
        let seams = MediaTimelining.seams(cut, withinSource: duration)

        #expect(seams.count == 1)
        #expect(seams.first?.at == 3.75 && seams.first?.half == 0.25, "got \(seams)")
        #expect(seams.first?.opens == 3.5 && seams.first?.closes == 4, "got \(seams)")
        #expect(seams.first?.kind == .dipToBlack)
        #expect(MediaTimelining.playedSeconds(of: cut, withinSource: duration) == 9.5)
        let plain = timeline([(0, 4, 1, nil), (4, 10, 1, nil)])
        #expect(MediaTimelining.seams(plain, withinSource: duration).first?.half == 0, "a plain cut overlaps")
        #expect(MediaTimelining.seams(plain, withinSource: duration).first?.at == 4)
        #expect(MediaTimelining.playedSeconds(of: plain, withinSource: duration) == 10)
    }

    /// ⚠️ **TWO TRANSITIONS AROUND A SHORT PIECE MEET AND NEVER CROSS** —
    /// crossing windows would ask for three pictures on two lanes. A second at
    /// 4x plays a quarter second and gives each cut half of it.
    @Test func twoTransitionsAroundAShortPieceNeverOverlap() throws {
        let cut = timeline([(0, 4, 1, .dipToBlack), (4, 5, 4, .dipToBlack), (5, 10, 1, nil)])
        let seams = MediaTimelining.seams(cut, withinSource: duration)
        try #require(seams.count == 2)

        #expect(seams[0].half == 0.0625 && seams[1].half == 0.0625, "got \(seams)")
        #expect(seams[0].closes <= seams[1].opens + 0.000_001, "the windows cross: \(seams)")
        #expect(abs(seams[0].closes - seams[1].opens) < 0.000_001, "the windows do not meet: \(seams)")
    }

    @Test func aTransitionTooShortToSeeOverlapsNothing() {
        #expect(VideoExporter.transitionOverlap(.zoom, outgoingPlayedSeconds: 0.05, incomingPlayedSeconds: 5) == 0)
        #expect(VideoExporter.transitionOverlap(nil, outgoingPlayedSeconds: 5, incomingPlayedSeconds: 5) == 0)
        let overlap = VideoExporter.transitionOverlap(.zoom, outgoingPlayedSeconds: 0.3, incomingPlayedSeconds: 5)
        #expect(abs(overlap - 0.15) < 0.000_001, "got \(overlap)")
        #expect(abs(overlap * 600 - (overlap * 600).rounded()) < 0.000_001, "off the 1/600 grid: \(overlap)")
    }

    // MARK: - The preview's equality

    @Test func playsTheSameSeesOnlyATransition() {
        let plain = timeline([(0, 4, 1, nil), (4, 10, 1, nil)])
        let faded = timeline([(0, 4, 1, .dipToBlack), (4, 10, 1, nil)])
        let white = timeline([(0, 4, 1, .dipToWhite), (4, 10, 1, nil)])

        #expect(!MediaTimelining.playsTheSame(plain, faded, withinSource: duration))
        #expect(!MediaTimelining.playsTheSame(faded, white, withinSource: duration))
        #expect(MediaTimelining.playsTheSame(faded, faded, withinSource: duration))
    }

    @Test func aSplitOfAPieceCarryingATransitionPlaysTheSame() {
        let faded = timeline([(0, 4, 1, .dipToBlack), (4, 10, 1, nil)])
        let split = MediaTimelining.split(faded, atPiece: 0, atSourceSeconds: 2, withinSource: duration)

        #expect(split != faded, "guard: the split did nothing")
        #expect(MediaTimelining.playsTheSame(faded, split, withinSource: duration),
                "a split of a faded piece reloads the preview")
    }

    @Test func aCutCarryingATransitionIsNeverMergedAway() {
        let faded = timeline([(0, 4, 1, .dipToBlack), (4, 10, 1, nil)])

        #expect(!MediaTimelining.playsTheSame(faded, .whole, withinSource: duration))
    }

    /// ⚠️ **HALVES ARE MEASURED BEFORE MERGING.** Split a fast piece so its
    /// transition's piece is shorter, and the fade shrinks: a different film.
    @Test func aShorterFadeAfterASplitIsANewFilm() {
        let faded = timeline([(0, 8, 4, .dipToBlack), (8, 10, 1, nil)])
        let split = MediaTimelining.split(faded, atPiece: 0, atSourceSeconds: 7, withinSource: duration)

        #expect(MediaTimelining.resolved(split, withinSource: duration).count == 3, "guard: no split")
        #expect(!MediaTimelining.playsTheSame(faded, split, withinSource: duration))
    }

    // MARK: - Where it travels

    @Test func changingOnlyATransitionChangesTheCacheKey() {
        var plain = MediaEdits.untouched
        plain.timeline = timeline([(0, 4, 1, nil), (4, 10, 1, nil)])
        var black = plain
        black.timeline = timeline([(0, 4, 1, .dipToBlack), (4, 10, 1, nil)])
        var white = plain
        white.timeline = timeline([(0, 4, 1, .dipToWhite), (4, 10, 1, nil)])

        #expect(plain.signature != black.signature)
        #expect(black.signature != white.signature)
    }

    @Test func exportSegmentsCarryEveryOtherTransition() {
        let cut = timeline([(0, 3, 1, .dipToBlack), (3, 6, 2, .dipToWhite), (6, 10, 1, nil)])

        let segments = MediaTimelining.exportSegments(cut, withinSource: duration)

        #expect(segments.map(\.transitionOut) == [.dipToBlack, .dipToWhite, nil])
        #expect(segments.map(\.speed) == [1, 2, 1])
    }

    @Test func theLastExportSegmentNeverCarriesATransition() {
        let stale = timeline([(0, 3, 1, nil), (3, 6, 1, .dipToBlack)])

        let segments = MediaTimelining.exportSegments(stale, withinSource: duration)

        #expect(segments.count == 2)
        #expect(segments.last?.transitionOut == nil, "got \(segments)")
    }

    @Test func aStaleTimelineKeepsTheTransitionsItCanStillPlay() {
        let stale = timeline([(0, 3, 1, .dipToBlack), (20, 25, 1, .dipToWhite), (3, 6, 1, nil)])

        let pieces = MediaTimelining.resolved(stale, withinSource: duration)

        #expect(pieces.map(\.start) == [0, 3], "got \(pieces)")
        #expect(pieces.map(\.transitionOut) == [.dipToBlack, nil], "got \(pieces)")
    }

    // MARK: - What the preview rehearses

    /// Three seconds, three and four, the first two overlapping by the
    /// standard half second: the dip's window is [2.5, 3.0], and the track
    /// draws the pieces over [0, 2.75], [2.75, 5.5] and [5.5, 9.5].
    @Test func aRehearsalIsTheWindowPlusTheLeadClampedToTheTwoPieces() throws {
        let cut = timeline([(0, 3, 1, .dipToBlack), (3, 6, 1, nil), (6, 10, 1, nil)])

        let first = try #require(MediaTimelining.rehearsal(atSeam: 0, in: cut, withinSource: duration, lead: 1.24))
        #expect(abs(first.window.lowerBound - 2.5) < 0.000_001 && abs(first.window.upperBound - 3) < 0.000_001,
                "got \(first.window)")
        #expect(abs(first.range.lowerBound - 1.26) < 0.000_001 && abs(first.range.upperBound - 4.24) < 0.000_001,
                "got \(first.range)")

        let wide = try #require(MediaTimelining.rehearsal(atSeam: 0, in: cut, withinSource: duration, lead: 10))
        #expect(wide.range == 0...5.5, "the lead ran past the two pieces: \(wide.range)")
        let later = try #require(MediaTimelining.rehearsal(atSeam: 1, in: cut, withinSource: duration, lead: 10))
        #expect(later.range == 2.75...9.5, "the lead ran before the piece that meets the cut: \(later.range)")

        let bare = try #require(MediaTimelining.rehearsal(atSeam: 1, in: cut, withinSource: duration, lead: 1))
        #expect(bare.window == 5.5...5.5, "a plain cut has a window: \(bare.window)")
        #expect(bare.range == 4.5...6.5, "got \(bare.range)")

        #expect(MediaTimelining.rehearsal(atSeam: 2, in: cut, withinSource: duration, lead: 1) == nil)
    }
}
