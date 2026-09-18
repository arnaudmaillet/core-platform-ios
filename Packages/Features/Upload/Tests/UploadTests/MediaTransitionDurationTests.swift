import DesignSystem
import Foundation
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **A TRANSITION RUNS AS LONG AS THE AUTHOR SAYS — AS FAR AS ITS TWO PIECES
/// CAN GIVE.** Asked for as *"pouvoir changer/adapter la durée d'une
/// transition"*.
///
/// The rule: a transition of `d` seconds is centred on its cut and borrows
/// `d / 2` from the end of the piece before it and `d / 2` from the start of
/// the piece after it. A piece lends at most half of itself, so a cut can carry
/// at most as long a transition as its SHORTER neighbour plays for — and the
/// transitions at a piece's two ends can meet but never cross.
struct MediaTransitionDurationModelTests {
    private let duration = 10.0

    private func timeline(_ pieces: [(Double, Double, VideoTransitionKind?)]) -> MediaTimeline {
        MediaTimeline(segments: pieces.map { MediaSegment(start: $0.0, end: $0.1, transitionOut: $0.2) })
    }

    private func lengths(_ timeline: MediaTimeline) -> [Double?] {
        MediaTimelining.resolved(timeline, withinSource: duration).map(\.transitionSeconds)
    }

    // MARK: - What is stored

    /// ⚠️ **AN EDIT MADE BEFORE LENGTHS EXISTED IS THE SAME VALUE TODAY.** A cut
    /// with a kind and no length runs the standard half second, and asking for
    /// the standard stores nothing — two spellings of it would make two equal
    /// films compare unequal, and the preview would rebuild for nothing.
    @Test func theStandardHalfSecondIsStoredAsNothing() {
        let cut = timeline([(0, 4, .dissolve), (4, 10, nil)])
        #expect(MediaTimelining.transitionSeconds(atSeam: 0, in: cut, withinSource: duration) == 0.5)
        #expect(lengths(cut) == [nil, nil])

        let longer = MediaTimelining.settingTransitionDuration(1, atSeam: 0, in: cut, withinSource: duration)
        #expect(lengths(longer) == [1, nil], "got \(lengths(longer))")
        let back = MediaTimelining.settingTransitionDuration(0.5, atSeam: 0, in: longer, withinSource: duration)
        #expect(back == MediaTimeline(segments: MediaTimelining.resolved(cut, withinSource: duration)),
                "the standard length is stored as a value: \(back)")
        #expect(MediaSegment(start: 0, end: 4, transitionOut: .zoom, transitionSeconds: 0.5)
                == MediaSegment(start: 0, end: 4, transitionOut: .zoom))
    }

    /// ⚠️ **A PLAIN CUT HAS NO LENGTH.** Setting one there changes nothing, and
    /// the initialiser drops one handed in beside no kind.
    @Test func aPlainCutTakesNoLength() {
        let plain = timeline([(0, 4, nil), (4, 10, nil)])
        #expect(MediaTimelining.settingTransitionDuration(1, atSeam: 0, in: plain, withinSource: duration) == plain)
        #expect(MediaTimelining.transitionSeconds(atSeam: 0, in: plain, withinSource: duration) == nil)
        #expect(MediaSegment(start: 0, end: 4, transitionSeconds: 1).transitionSeconds == nil)
        #expect(MediaTimelining.settingTransitionDuration(1, atSeam: 1, in: plain, withinSource: duration) == plain,
                "a length was stored past the last cut")
    }

    /// ⚠️ **NEVER LONGER THAN THE SHORTER NEIGHBOUR, NEVER PAST TWO SECONDS,
    /// NEVER UNDER A QUARTER.** 0.8s then 5s: two seconds asked is 0.8 stored,
    /// and 0.4s drawn either side of the cut.
    @Test func aLengthIsClampedToWhatThePiecesCanGive() throws {
        let cut = timeline([(0, 0.8, .dissolve), (0.8, 5.8, nil), (5.8, 10, nil)])
        #expect(MediaTimelining.longestTransition(atSeam: 0, in: cut, withinSource: duration) == 0.8)

        let asked = MediaTimelining.settingTransitionDuration(2, atSeam: 0, in: cut, withinSource: duration)
        #expect(lengths(asked).first == 0.8, "got \(lengths(asked))")
        let seam = try #require(MediaTimelining.seams(asked, withinSource: duration).first)
        #expect(abs(seam.half - 0.4) < 0.000_001, "drawn \(seam.half) either side")

        let roomy = timeline([(0, 5, .dissolve), (5, 10, nil)])
        #expect(MediaTimelining.longestTransition(atSeam: 0, in: roomy, withinSource: duration) == 2)
        let tooLong = MediaTimelining.settingTransitionDuration(9, atSeam: 0, in: roomy, withinSource: duration)
        #expect(lengths(tooLong).first == 2, "got \(lengths(tooLong))")
        let tooShort = MediaTimelining.settingTransitionDuration(0.01, atSeam: 0, in: roomy, withinSource: duration)
        #expect(lengths(tooShort).first == 0.25, "got \(lengths(tooShort))")
    }

    /// ⚠️ **ASKED IS KEPT, DRAWN IS CLAMPED.** A piece trimmed after the length
    /// was chosen gives less, and the window shrinks with it; the length asked
    /// stays, so undoing the trim gives it back.
    @Test func aTrimShortensWhatIsDrawnNotWhatWasAsked() throws {
        let long = MediaTimelining.settingTransitionDuration(
            2, atSeam: 0, in: timeline([(0, 5, .dissolve), (5, 10, nil)]), withinSource: duration
        )
        let trimmed = MediaTimelining.moved(long, piece: 0, edge: .end, bySourceSeconds: -4, withinSource: duration)
        try #require(MediaTimelining.resolved(trimmed, withinSource: duration).first?.end == 1, "guard: no trim")

        #expect(MediaTimelining.transitionSeconds(atSeam: 0, in: trimmed, withinSource: duration) == 2)
        let seam = try #require(MediaTimelining.seams(trimmed, withinSource: duration).first)
        #expect(abs(seam.half - 0.5) < 0.000_001, "drawn \(seam.half) either side of a one-second piece")
    }

    // MARK: - What it changes

    /// ⚠️ **A LENGTH IS A NEW FILM** — the window it draws, what the preview
    /// compares, and what the export is handed all change with it.
    @Test func aLengthChangesTheWindowTheFilmAndTheExport() throws {
        let cut = timeline([(0, 4, .dissolve), (4, 10, nil)])
        let long = MediaTimelining.settingTransitionDuration(1.5, atSeam: 0, in: cut, withinSource: duration)

        let seam = try #require(MediaTimelining.seams(long, withinSource: duration).first)
        #expect(seam.opens == 3.25 && seam.closes == 4.75, "the window is \(seam.opens)...\(seam.closes)")
        #expect(!MediaTimelining.playsTheSame(cut, long, withinSource: duration), "a new length plays the same")
        let exported = MediaTimelining.exportSegments(long, withinSource: duration)
        #expect(exported.map(\.transitionSeconds) == [1.5, 0.5], "the export was handed \(exported)")
    }

    /// ⚠️ **ANOTHER KIND KEEPS THE LENGTH; NONE TAKES IT AWAY** — and a kind
    /// chosen after None starts again from the standard.
    @Test func anotherKindKeepsTheLengthAndNoneTakesItAway() {
        let cut = timeline([(0, 4, .dissolve), (4, 10, nil)])
        let long = MediaTimelining.settingTransitionDuration(1, atSeam: 0, in: cut, withinSource: duration)

        let swiped = MediaTimelining.settingTransition(.swipe, atSeam: 0, in: long, withinSource: duration)
        #expect(lengths(swiped) == [1, nil], "a new kind lost the length: \(lengths(swiped))")

        let none = MediaTimelining.settingTransition(nil, atSeam: 0, in: swiped, withinSource: duration)
        #expect(lengths(none) == [nil, nil], "None kept a length: \(lengths(none))")
        let again = MediaTimelining.settingTransition(.swipe, atSeam: 0, in: none, withinSource: duration)
        #expect(MediaTimelining.transitionSeconds(atSeam: 0, in: again, withinSource: duration) == 0.5)
    }

    /// ⚠️ **THE LENGTH TRAVELS WITH ITS TRANSITION** — to the right half of a
    /// split, with its piece on a carry, and out with it when the piece is put
    /// down last.
    @Test func theLengthTravelsWithItsTransition() {
        let long = MediaTimelining.settingTransitionDuration(
            1, atSeam: 0, in: timeline([(0, 4, .dissolve), (4, 10, nil)]), withinSource: duration
        )

        let split = MediaTimelining.split(long, atPiece: 0, atSourceSeconds: 2, withinSource: duration)
        #expect(lengths(split) == [nil, 1, nil], "got \(lengths(split))")

        let carried = MediaTimelining.reordered(long, move: 0, to: 1, withinSource: duration)
        #expect(lengths(carried) == [nil, 1], "got \(lengths(carried))")
        #expect(lengths(MediaTimelining.settled(carried)) == [nil, nil], "the last piece kept a length")
    }

    // MARK: - What the preview rehearses

    /// ⚠️ **A LONGER TRANSITION TAKES WHAT IT ADDS OUT OF THE LEADS** — the lead
    /// the track gives is sized for the standard half second, so the loop still
    /// fits to the needle's right; never under half a second a side (F30).
    @Test func aLongerTransitionRehearsesWithShorterLeads() throws {
        let cut = timeline([(0, 5, .dissolve), (5, 10, nil)])
        let standard = try #require(MediaTimelining.rehearsal(atSeam: 0, in: cut, withinSource: duration, lead: 1.24))
        #expect(abs(standard.range.lowerBound - 3.51) < 0.000_001 && abs(standard.range.upperBound - 6.49) < 0.000_001,
                "got \(standard.range)")

        let one = MediaTimelining.settingTransitionDuration(1, atSeam: 0, in: cut, withinSource: duration)
        let longer = try #require(MediaTimelining.rehearsal(atSeam: 0, in: one, withinSource: duration, lead: 1.24))
        #expect(longer.window == 4.5...5.5, "got \(longer.window)")
        #expect(abs(longer.range.lowerBound - 3.51) < 0.000_001 && abs(longer.range.upperBound - 6.49) < 0.000_001,
                "the stretch grew with the window: \(longer.range)")

        let two = MediaTimelining.settingTransitionDuration(2, atSeam: 0, in: cut, withinSource: duration)
        let longest = try #require(MediaTimelining.rehearsal(atSeam: 0, in: two, withinSource: duration, lead: 1.24))
        #expect(longest.window == 4...6, "got \(longest.window)")
        #expect(longest.range == 3.5...6.5, "the leads went under half a second: \(longest.range)")
    }
}

/// **THE LENGTHS STAND OVER THE TRACK WHILE AN OPEN CUT CARRIES A KIND.**
@MainActor
struct MediaTransitionDurationRowTests {
    @Test func fiveLengthsWithTheStandardChosen() {
        let row = MediaTransitionDurationRowView()
        #expect(row.debugTitles == ["0.25s", "0.5s", "1s", "1.5s", "2s"])
        #expect(row.debugChosen == ["0.5s"])
        #expect(row.debugEnabled.count == 5)

        row.show(seconds: 1.5, longest: 2)
        #expect(row.debugChosen == ["1.5s"])
    }

    /// ⚠️ **A LENGTH THE PIECES CANNOT GIVE IS SHOWN, AND REFUSED** — the row
    /// keeps its shape from one cut to the next.
    @Test func aLengthThePiecesCannotGiveIsRefused() {
        let row = MediaTransitionDurationRowView()
        var picked: [Double] = []
        row.onPick = { picked.append($0) }
        row.show(seconds: 0.5, longest: 1.2)

        #expect(row.debugEnabled == ["0.25s", "0.5s", "1s"], "got \(row.debugEnabled)")
        row.debugTap(seconds: 2)
        row.debugTap(seconds: 1)
        #expect(picked == [1], "got \(picked)")
    }

    private func hosted() -> (MediaTimelineToolsView, UIWindow) {
        let tools = MediaTimelineToolsView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.addSubview(tools)
        tools.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            tools.topAnchor.constraint(equalTo: window.topAnchor)
        ])
        window.isHidden = false
        tools.track.configure(duration: 10, timeline: MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4, transitionOut: .dissolve), MediaSegment(start: 4, end: 10)
        ]))
        window.layoutIfNeeded()
        return (tools, window)
    }

    /// ⚠️ **ONLY OVER A KIND, AND THE SCREEN IS TOLD EVERY TIME THE BAND
    /// MOVES.** Opening the row on a plain cut changes no height (F28); a kind
    /// raises the lengths by what the rate chips add, None lowers them, and the
    /// row closing takes them with it.
    @Test func theLengthsStandOverTheTrackOnlyOverAKind() throws {
        let (tools, window) = hosted()
        defer { window.isHidden = true }
        var told = 0
        tools.onHeightChange = { told += 1 }
        let resting = tools.frame.height

        try #require(tools.openTransitions(atSeam: 0, chosen: nil, rehearsal: 2...6, window: 4...4, animated: false))
        window.layoutIfNeeded()
        #expect(!tools.isOfferingDurations && tools.frame.height == resting && told == 0,
                "a plain cut raised the lengths: \(tools.frame.height), told \(told)")

        tools.showTransition(.dissolve, seconds: 1, longest: 2, rehearsal: 2...6, window: 3.5...4.5)
        window.layoutIfNeeded()
        #expect(tools.isOfferingDurations && told == 1, "a kind did not raise the lengths (told \(told))")
        #expect(tools.frame.height == resting + MediaTransitionDurationRowView.height + Spacing.sm,
                "the band is \(tools.frame.height)pt")
        #expect(tools.durations.debugChosen == ["1s"])
        #expect(tools.durations.frame.maxY <= tools.track.frame.minY, "the lengths are not over the track")

        tools.showTransition(.swipe, seconds: 1, longest: 2, rehearsal: 2...6, window: 3.5...4.5)
        #expect(told == 1, "another kind moved the band")

        tools.showTransition(nil, rehearsal: 2...6, window: 4...4)
        window.layoutIfNeeded()
        #expect(!tools.isOfferingDurations && told == 2 && tools.frame.height == resting,
                "None left the lengths up: \(tools.frame.height), told \(told)")

        tools.showTransition(.dissolve, rehearsal: 2...6, window: 3.75...4.25)
        tools.closeTransitions(animated: false)
        window.layoutIfNeeded()
        #expect(!tools.isOfferingDurations && told == 4 && tools.frame.height == resting,
                "closing left the lengths up: \(tools.frame.height), told \(told)")
    }

    @Test func aCutOpenedOnAKindShowsItsLength() throws {
        let (tools, window) = hosted()
        defer { window.isHidden = true }

        try #require(tools.openTransitions(
            atSeam: 0, chosen: .dissolve, seconds: 1.5, longest: 1.5, rehearsal: 2...6, window: 3.25...4.75,
            animated: false
        ))
        #expect(tools.isOfferingDurations)
        #expect(tools.durations.debugChosen == ["1.5s"] && tools.durations.debugEnabled.last == "1.5s")
    }

    @Test func aTappedLengthReachesTheScreen() {
        let tools = MediaTimelineToolsView()
        var picked: [Double] = []
        tools.onTransitionDuration = { picked.append($0) }
        tools.durations.debugTap(seconds: 1.5)
        #expect(picked == [1.5])
    }
}
