import Foundation
import MediaPlayback
import Testing
@testable import Upload

/// **A PIECE'S FILTER BELONGS TO THE PIECE**: set on it alone, kept by every
/// edit of it, and part of the film the export and the preview are built from —
/// asked of the arithmetic, on a ten-second file.
struct MediaSegmentFilterModelTests {
    private let duration = 10.0

    private func filters(_ timeline: MediaTimeline) -> [MediaFilter?] {
        MediaTimelining.resolved(timeline, withinSource: duration).map(\.filter)
    }

    private let halves = MediaTimeline(segments: [
        MediaSegment(start: 0, end: 4), MediaSegment(start: 4, end: 10)
    ])

    // MARK: - Setting it

    @Test func settingTouchesOnlyThatPiece() {
        let set = MediaTimelining.settingFilter(.mono, atPiece: 1, in: halves, withinSource: duration)
        #expect(filters(set) == [nil, .mono])
        #expect(set.segments.map(\.start) == [0, 4] && set.segments.map(\.end) == [4, 10],
                "the filter moved the pieces: \(set.segments)")
    }

    /// An untouched clip has no segments; the one piece the track draws takes
    /// the filter.
    @Test func anUntouchedClipTakesItOnItsOnePiece() {
        let set = MediaTimelining.settingFilter(.noir, atPiece: 0, in: .whole, withinSource: duration)
        #expect(filters(set) == [.noir])
        #expect(set.segments.count == 1 && set.segments[0].start == 0 && set.segments[0].end == 10)
    }

    @Test func originalIsNoFilter() {
        let set = MediaTimelining.settingFilter(.mono, atPiece: 0, in: halves, withinSource: duration)
        let cleared = MediaTimelining.settingFilter(.original, atPiece: 0, in: set, withinSource: duration)
        #expect(filters(cleared) == [nil, nil])
        #expect(MediaTimelining.playsTheSame(cleared, halves, withinSource: duration))
    }

    @Test func aPieceThatIsNotThereIsLeftAlone() {
        #expect(MediaTimelining.settingFilter(.mono, atPiece: 2, in: halves, withinSource: duration) == halves)
        #expect(MediaTimelining.settingFilter(.mono, atPiece: -1, in: halves, withinSource: duration) == halves)
    }

    // MARK: - Every edit keeps it

    @Test func aSplitGivesBothHalvesTheFilter() {
        let set = MediaTimelining.settingFilter(.chrome, atPiece: 1, in: halves, withinSource: duration)
        let split = MediaTimelining.split(set, atPiece: 1, atSourceSeconds: 7, withinSource: duration)
        #expect(split.segments.count == 3, "guard: the split did nothing")
        #expect(filters(split) == [nil, .chrome, .chrome])
    }

    @Test func aCarryMovesTheFilterWithItsPiece() {
        let set = MediaTimelining.settingFilter(.fade, atPiece: 0, in: halves, withinSource: duration)
        let moved = MediaTimelining.reordered(set, move: 0, to: 1, withinSource: duration)
        #expect(moved.segments.map(\.start) == [4, 0], "guard: the carry did nothing")
        #expect(filters(moved) == [nil, .fade])
    }

    @Test func aRateKeepsTheFilter() {
        let set = MediaTimelining.settingFilter(.tonal, atPiece: 0, in: halves, withinSource: duration)
        let fast = MediaTimelining.setRate(2, atPiece: 0, in: set, withinSource: duration)
        #expect(fast.segments.first?.speed == 2, "guard: the rate did nothing")
        #expect(filters(fast) == [.tonal, nil])
    }

    // MARK: - It is part of the film

    /// ⚠️ **TWO TIMELINES DIFFERING ONLY IN A PIECE'S LOOK ARE TWO FILMS** — the
    /// preview must build a new item for it.
    @Test func playsTheSameTellsLooksApart() {
        let set = MediaTimelining.settingFilter(.mono, atPiece: 0, in: halves, withinSource: duration)
        #expect(!MediaTimelining.playsTheSame(set, halves, withinSource: duration))
        let other = MediaTimelining.settingFilter(.noir, atPiece: 0, in: halves, withinSource: duration)
        #expect(!MediaTimelining.playsTheSame(set, other, withinSource: duration))
        #expect(MediaTimelining.playsTheSame(set, set, withinSource: duration))
    }

    /// Touching pieces are merged before comparing — but never across a change
    /// of look.
    @Test func touchingPiecesWithDifferentLooksAreNotMerged() {
        let set = MediaTimelining.settingFilter(.mono, atPiece: 1, in: halves, withinSource: duration)
        let whole = MediaTimelining.settingFilter(.mono, atPiece: 0, in: .whole, withinSource: duration)
        #expect(!MediaTimelining.playsTheSame(set, whole, withinSource: duration),
                "a half-filtered clip compared equal to a whole-filtered one")
        let head = MediaTimelining.settingFilter(.mono, atPiece: 0, in: halves, withinSource: duration)
        #expect(!MediaTimelining.playsTheSame(head, whole, withinSource: duration),
                "a clip filtered on its first half compared equal to a whole-filtered one")
        let both = MediaTimelining.settingFilter(.mono, atPiece: 0, in: set, withinSource: duration)
        #expect(MediaTimelining.playsTheSame(both, whole, withinSource: duration),
                "two touching pieces wearing one look are one stretch of film")
    }

    /// ⚠️ **A LOOK ON AN UNCUT CLIP STILL EXPORTS.** Left out of `cuts`, the one
    /// filtered piece resolved to no segments and the export played the file as
    /// shot.
    @Test func anUncutClipWithAFilterStillExports() {
        let set = MediaTimelining.settingFilter(.mono, atPiece: 0, in: .whole, withinSource: duration)
        #expect(MediaTimelining.cuts(set, withinSource: duration))
        let segments = MediaTimelining.exportSegments(set, withinSource: duration)
        #expect(segments.count == 1 && segments.first?.look == .mono, "got \(segments)")
    }

    // MARK: - What the preview loops

    @Test func thePieceIsLoopedFromItsStart() {
        let slow = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4, speed: 2), MediaSegment(start: 4, end: 10)
        ])
        #expect(MediaTimelining.rehearsal(ofPiece: 1, in: slow, withinSource: duration) == 2...8)
        #expect(MediaTimelining.rehearsal(ofPiece: 0, in: slow, withinSource: duration) == 0...2)
    }

    @Test func aLongPieceIsLoopedByItsOpening() {
        #expect(MediaTimelining.rehearsal(ofPiece: 0, in: .whole, withinSource: duration)
                == 0...MediaTimelining.longestPieceRehearsal)
        #expect(MediaTimelining.rehearsal(ofPiece: 3, in: halves, withinSource: duration) == nil)
    }
}
