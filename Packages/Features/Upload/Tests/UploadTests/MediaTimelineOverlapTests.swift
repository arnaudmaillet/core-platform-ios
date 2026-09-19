import CoreGraphics
import Foundation
import MediaPlayback
import Testing
@testable import Upload

/// **THE TRACK IS DRAWN ON THE CLOCK OF A RESULT WHOSE TRANSITIONS OVERLAP.**
///
/// Chosen by the author — *"oui, chevauche les deux segments"*: a transition of
/// `d` plays the last `d` of the piece before its cut over the first `d` of the
/// piece after it, and the result is `d` shorter (`VideoExporter.insertPieces`).
/// Everything on the track that reads time — where a piece is drawn, which
/// piece is under the needle and where its film is, where a square of film
/// sits, what a loop plays, what the shot list's marks say, how long the
/// result is — is asked here of the arithmetic, on a ten-second file.
///
/// The standard fixture: four seconds, then three, then three, joined by a
/// dissolve of a second and a dip of the standard half second. The second
/// piece's film runs [3, 6] and the third's [5.5, 8.5], so the first two
/// overlap over [3, 4], the last two over [5.5, 6], the result is 8.5s, and the
/// track draws the pieces over [0, 3.5], [3.5, 5.75] and [5.75, 8.5].
struct MediaTimelineOverlapTests {
    private let duration = 10.0

    private var joined: MediaTimeline {
        MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4, transitionOut: .dissolve, transitionSeconds: 1),
            MediaSegment(start: 4, end: 7, transitionOut: .dipToBlack),
            MediaSegment(start: 7, end: 10)
        ])
    }

    // MARK: - The clock

    @Test func eachPieceStartsAnOverlapBeforeTheOneBeforeItEnds() {
        let laid = MediaTimelining.laid(joined, withinSource: duration)

        #expect(laid.map(\.starts) == [0, 3, 5.5], "got \(laid.map(\.starts))")
        #expect(laid.map(\.ends) == [4, 6, 8.5], "got \(laid.map(\.ends))")
        #expect(laid.map(\.overlapIn) == [0, 1, 0.5] && laid.map(\.overlapOut) == [1, 0.5, 0])
        #expect(MediaTimelining.playedSeconds(of: joined, withinSource: duration) == 8.5,
                "the result is not its pieces less the overlaps")
    }

    /// ⚠️ **THE SAME RULE AS THE EXPORT'S** — `VideoExporter.transitionOverlap`,
    /// with half of each neighbour at most: two seconds asked between a second
    /// and six are half a second.
    @Test func anOverlapIsClampedAsTheExportClampsIt() {
        let short = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 1, transitionOut: .dissolve, transitionSeconds: 2),
            MediaSegment(start: 4, end: 10)
        ])
        let laid = MediaTimelining.laid(short, withinSource: duration)

        #expect(laid[0].overlapOut == 0.5, "got \(laid[0].overlapOut)")
        #expect(laid[0].overlapOut == VideoExporter.transitionOverlap(
            .dissolve, seconds: 2, outgoingPlayedSeconds: 1, incomingPlayedSeconds: 6
        ))
        #expect(MediaTimelining.playedSeconds(of: short, withinSource: duration) == 6.5)
    }

    // MARK: - The track

    /// ⚠️ **DRAWN END TO END, EACH FROM THE MIDDLE OF ONE OVERLAP TO THE MIDDLE
    /// OF THE NEXT** — and its film placed from where it starts, under the
    /// neighbour's half.
    @Test func thePiecesAreDrawnEndToEndAroundTheMiddleOfEachOverlap() {
        let placed = MediaTimelining.placements(joined, withinSource: duration, pointsPerSecond: 10)

        #expect(placed.map(\.from) == [0, 35, 57.5], "got \(placed.map(\.from))")
        #expect(placed.map(\.to) == [35, 57.5, 85], "got \(placed.map(\.to))")
        #expect(placed.map(\.origin) == [0, 30, 55], "got \(placed.map(\.origin))")
        #expect(MediaTimelining.contentWidth(of: joined, withinSource: duration, pointsPerSecond: 10) == 85)
        let seams = MediaTimelining.seams(joined, withinSource: duration)
        #expect(seams.map(\.at) == [3.5, 5.75] && seams.map(\.opens) == [3, 5.5] && seams.map(\.closes) == [4, 6],
                "got \(seams)")
    }

    /// ⚠️ **A SQUARE OF FILM SITS WHERE ITS SECOND PLAYS.** The second piece's
    /// film starts at 3s on the clock, half a second before it is drawn: its
    /// square for the file's [4, 5) is placed at 30pt and cut off where the
    /// piece is drawn, 35pt — its first half second is under the first piece.
    @Test func aSquareOfFilmIsPlacedFromWhereItsPieceStarts() throws {
        let squares = MediaTimelining.squares(
            in: joined, withinSource: duration, visible: 0...85, tileWidth: 10, pointsPerSecond: 10
        )
        let first = try #require(squares.filter { $0.piece == 1 }.min { $0.from < $1.from })

        #expect(first.filmFrom == 30 && first.from == 35 && first.seconds == 4.5,
                "the second piece's first square: \(first)")
        #expect(squares.allSatisfy { square in
            let piece = MediaTimelining.placements(joined, withinSource: duration, pointsPerSecond: 10)[square.piece]
            return square.from >= piece.from - 0.001 && square.from + square.width <= piece.to + 0.001
        }, "a square is drawn outside its piece")
    }

    // MARK: - The needle

    /// ⚠️ **UNDER THE NEEDLE, THE PIECE DRAWN THERE — AND WHERE ITS FILM IS.**
    /// At 3.25s both pieces play; the track draws the first, whose film is at
    /// its 3.25s. At 3.75s it draws the second, three quarters of a second
    /// into its film: the file's 4.75s. And back again, exactly.
    @Test func theMomentUnderTheNeedleIsThePieceDrawnThere() throws {
        let before = try #require(MediaTimelining.moment(atPlayedSeconds: 3.25, in: joined, withinSource: duration))
        let after = try #require(MediaTimelining.moment(atPlayedSeconds: 3.75, in: joined, withinSource: duration))

        #expect(before == MediaTimelining.Moment(piece: 0, sourceSeconds: 3.25), "got \(before)")
        #expect(after == MediaTimelining.Moment(piece: 1, sourceSeconds: 4.75), "got \(after)")
        for seconds in [0.5, 3.25, 3.75, 5.6, 5.9, 8.4] {
            let moment = try #require(MediaTimelining.moment(atPlayedSeconds: seconds, in: joined, withinSource: duration))
            let back = MediaTimelining.playedSeconds(
                ofPiece: moment.piece, atSourceSeconds: moment.sourceSeconds, in: joined, withinSource: duration
            )
            #expect(abs(back - seconds) < 0.000_001, "\(seconds)s went to \(moment) and came back as \(back)s")
        }
    }

    // MARK: - The loops

    /// ⚠️ **A PIECE IS LOOPED AS IT IS DRAWN**, and a cut from the first
    /// piece's drawn start to the second's drawn end, around the overlap.
    @Test func theLoopsFollowTheDrawnPieces() throws {
        #expect(MediaTimelining.rehearsal(ofPiece: 1, in: joined, withinSource: duration) == 3.5...5.75)
        let seam = try #require(MediaTimelining.rehearsal(atSeam: 1, in: joined, withinSource: duration, lead: 5))
        #expect(seam.window == 5.5...6, "got \(seam.window)")
        #expect(seam.range == 3.5...8.5, "got \(seam.range)")
    }

    // MARK: - The shot list

    /// ⚠️ **THE MARKS ABOVE THE SHOT LIST NAME WHERE THE TRACK DRAWS EACH PIECE
    /// BEGINNING, AND THE END OF THE SHORTER RESULT.**
    @Test func theShotListIsMarkedOnTheOverlappedClock() {
        let shots = MediaTimelining.shots(joined, withinSource: duration, across: 300)
        let marks = MediaTimelining.shotMarks(shots, minimumSpacing: 10)

        #expect(marks.map(\.seconds) == [0, 3.5, 5.75, 8.5], "got \(marks.map(\.seconds))")
        #expect(marks.map(\.x) == [0, 100, 200, 300], "got \(marks.map(\.x))")
    }

    // MARK: - The chips

    /// ⚠️ **HALF THE SHORTER NEIGHBOUR, ON THE 1/600 GRID** — so the two
    /// transitions around a piece never overlap each other, and a chip is
    /// dimmed exactly when its length would not be drawn. Two seconds and
    /// three: one second. A second each: the standard half second, still.
    @Test func theLongestTransitionIsHalfTheShorterNeighbour() {
        let pieces = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2, transitionOut: .dissolve),
            MediaSegment(start: 2, end: 5, transitionOut: .dissolve),
            MediaSegment(start: 5, end: 6, transitionOut: .dissolve),
            MediaSegment(start: 6, end: 7)
        ])
        let longest = (0..<3).map { MediaTimelining.longestTransition(atSeam: $0, in: pieces, withinSource: duration) }

        #expect(longest == [1, 0.5, 0.5], "got \(longest)")
        for seam in 0..<3 {
            let asked = MediaTimelining.settingTransitionDuration(2, atSeam: seam, in: pieces, withinSource: duration)
            let drawn = MediaTimelining.seams(asked, withinSource: duration)[seam].half * 2
            #expect(abs(drawn - longest[seam]) < 0.000_001, "cut \(seam): the longest chip draws \(drawn)s")
        }
    }
}

/// **WHAT THE TRACK SAYS ABOUT THE RESULT, ON THE OVERLAPPED CLOCK.**
@MainActor
struct MediaTimelineOverlapTrackTests {
    /// ⚠️ **VOICEOVER HEARS THE RESULT'S LENGTH, NOT THE SUM OF ITS PIECES.**
    /// Four seconds and six, overlapping by a second: nine seconds kept.
    @Test func theTrackSpeaksTheOverlappedLength() {
        let track = TrackFixture.cutInThree(holding: nil, segments: [
            MediaSegment(start: 0, end: 4, transitionOut: .dissolve, transitionSeconds: 1),
            MediaSegment(start: 4, end: 10)
        ])

        #expect(track.accessibilityValue == "9 seconds kept", "got \(String(describing: track.accessibilityValue))")
    }
}
