import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// ⚠️ **ASKED FOR IN THE AUTHOR'S WORDS**: *"dans la timeline par dessus les
/// segments mettre un + … pile à la coupure entre 2 segments"*, and *"si une
/// transition a été apportée, changer l'icône de + par une icône spécifique"*.
/// Every assertion reads the buttons the track put on screen.
@MainActor
struct MediaTimelineSeamTests {
    private static let cutAtThreeAndSix = [
        MediaSegment(start: 0, end: 3), MediaSegment(start: 3, end: 6), MediaSegment(start: 6, end: 10)
    ]

    private final class Taps {
        var seams: [Int] = []
    }

    private func track(
        _ segments: [MediaSegment] = cutAtThreeAndSix, duration: Double = 10,
        holding piece: Int? = nil, listening: Bool = true, taps: Taps = Taps()
    ) -> MediaTimelineTrackView {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        if listening { track.onSeam = { taps.seams.append($0) } }
        track.configure(duration: duration, timeline: MediaTimeline(segments: segments))
        track.layoutIfNeeded()
        if let piece {
            track.select(piece)
            track.layoutIfNeeded()
        }
        return track
    }

    @Test func aSeamStandsOnEachInteriorCut() throws {
        let marks = track().debugSeamMarks
        try #require(marks.count == 2, "got \(marks)")
        #expect(marks.map(\.index) == [0, 1])
        #expect(abs(marks[0].centre.x - 180) <= 0.5 && abs(marks[0].centre.y - 46.5) <= 0.5,
                "the first + is at \(marks[0].centre)")
        #expect(abs(marks[1].centre.x - 360) <= 0.5 && abs(marks[1].centre.y - 46.5) <= 0.5,
                "the second + is at \(marks[1].centre)")
        let hit = MediaTimelineTrackView.debugSeamHitSize
        #expect(marks.allSatisfy { $0.hit.width == hit && $0.hit.height == hit },
                "a + is not a finger wide: \(marks.map(\.hit))")
    }

    @Test func aWholeOrSinglePieceShowsNoSeam() {
        #expect(track([]).debugSeamMarks.isEmpty, "an untouched clip has a +")
        #expect(track([MediaSegment(start: 2, end: 7)]).debugSeamMarks.isEmpty, "a trimmed clip has a +")
    }

    @Test func noListenerNoMarks() {
        #expect(track(listening: false).debugSeamMarks.isEmpty, "a + is drawn that nobody can answer")
    }

    @Test func aSeamSaysWhatItCarries() {
        var segments = Self.cutAtThreeAndSix
        segments[1].transitionOut = .dipToBlack
        #expect(track(segments).debugSeamMarks.map(\.glyph) == ["plus", "moon.fill"])
    }

    /// ⚠️ **THE HELD PIECE'S CUTS ARE CARRIED BY ITS CAPS**, so their discs go
    /// and each cap draws the same symbol in place of its grip.
    @Test func aHeldPieceHidesItsOwnSeams() {
        let held = track(holding: 1).debugSeamMarks
        #expect(held.isEmpty, "a + stands on the held piece's caps: \(held)")
        let first = track(holding: 0).debugSeamMarks
        #expect(first.map(\.index) == [1], "holding the first piece: \(first)")
    }

    @Test func aPressOnASeamLiftsNothing() {
        let track = track()
        #expect(track.debugWouldLift(atContentX: 180) == false, "a press on the + lifts a piece")
        #expect(track.debugWouldLift(atContentX: 90) == true, "guard: a press on the film lifts nothing")
    }

    @Test func aTapOnASeamTakesNoPiece() {
        let taps = Taps()
        let track = track(taps: taps)
        track.debugTapSeam(0)
        #expect(taps.seams == [0], "the + did not answer")

        track.debugTap(atContentX: 181)
        #expect(track.selectedPiece == nil, "a tap on the + took piece \(track.selectedPiece ?? -1)")
        track.debugTap(atContentX: 90)
        #expect(track.selectedPiece == 0, "guard: a tap on the film takes nothing")
        #expect(taps.seams == [0], "a tap on the film was heard as a +")
    }

    @Test func crowdedSeamsAreThinned() throws {
        let tenPieces = (0..<10).map { MediaSegment(start: Double($0), end: Double($0 + 1)) }
        let track = track(tenPieces)
        for _ in 0..<10 { track.debugPinch(by: 0.2) }
        track.layoutIfNeeded()
        try #require(track.debugPointsPerSecond == 12, "guard: \(track.debugPointsPerSecond)pt/s")

        let marks = track.debugSeamMarks
        #expect(!marks.isEmpty && marks.count < 9, "got \(marks.count) marks 12pt apart")
        for (left, right) in zip(marks, marks.dropFirst()) {
            #expect(right.centre.x - left.centre.x >= 26, "two discs overlap: \(left) \(right)")
            #expect(left.hit.maxX <= right.hit.minX + 0.01, "two targets overlap: \(left) \(right)")
        }
    }

    @Test func aTransitionOutranksABareCutWhenThinned() {
        var tenPieces = (0..<10).map { MediaSegment(start: Double($0), end: Double($0 + 1)) }
        tenPieces[1].transitionOut = .zoom
        let marks = MediaTimelining.seamMarks(
            MediaTimelining.placements(
                MediaTimeline(segments: tenPieces), withinSource: 10, pointsPerSecond: 12
            )
        )
        #expect(marks.contains { $0.index == 1 && $0.kind == .zoom }, "the only transition was thinned away: \(marks)")
    }

    @Test func seamsFollowTheRipple() throws {
        let track = track()
        let later = [MediaSegment(start: 0, end: 2), MediaSegment(start: 3, end: 6), MediaSegment(start: 6, end: 10)]
        track.configure(duration: 10, timeline: MediaTimeline(segments: later))
        track.layoutIfNeeded()
        let marks = track.debugSeamMarks
        try #require(marks.count == 2)
        #expect(abs(marks[0].centre.x - 120) <= 0.5 && abs(marks[1].centre.x - 300) <= 0.5,
                "the + stayed where the cuts were: \(marks.map(\.centre))")
    }

    @Test func seamsLeaveWithTheTrackDuringACarry() {
        let track = track()
        track.debugLift(atContentX: 90)
        track.layoutIfNeeded()
        #expect(track.debugCarrying == 0, "guard: nothing was lifted")
        #expect(track.debugSeamMarksShowing == false, "a + stands over the shot list")
        #expect(track.debugCapMarks == ["grip", "grip"], "a cap carries a + during the carry: \(track.debugCapMarks)")
        #expect(track.accessibilityCustomActions?.isEmpty != false, "a cut is spoken during the carry")
        track.debugDrop()
        track.layoutIfNeeded()
    }

    // MARK: - The + in the caps

    /// ⚠️ **ASKED FOR**: *"mettre le plus dans les pinces de sélection à la place
    /// du trait vertical"*.
    @Test func aHeldPiecesCapsCarryItsCutsInPlaceOfTheirGrips() throws {
        var segments = Self.cutAtThreeAndSix
        segments[1].transitionOut = .dipToBlack
        let track = track(segments, holding: 1)

        #expect(track.debugCapMarks == ["plus", "moon.fill"], "got \(track.debugCapMarks)")
        #expect(track.debugSelectionIsDrawn)
        #expect(track.debugSeamMarks.isEmpty, "a disc stands on a held cap")
        let glyphs = track.debugCapGlyphs
        for (glyph, cap) in zip(glyphs, [track.debugStartGrip, track.debugEndGrip]) {
            let drawn = try #require(glyph, "a cap on a cut draws no glyph")
            #expect(drawn.frame.minX >= cap.minX + 0.5 && drawn.frame.maxX <= cap.maxX - 0.5,
                    "the glyph \(drawn.frame) spills out of its cap \(cap)")
            #expect(abs(drawn.frame.midY - 46.5) <= 0.5, "the glyph is at \(drawn.frame.midY)")
        }
    }

    @Test func theFilmsOwnEndsKeepTheirGrips() {
        #expect(track(holding: 0).debugCapMarks == ["grip", "plus"])
        #expect(track(holding: 2).debugCapMarks == ["plus", "grip"])
        #expect(track([MediaSegment(start: 2, end: 7)], holding: 0).debugCapMarks == ["grip", "grip"])
        #expect(track([], holding: 0).debugCapMarks == ["grip", "grip"])
    }

    @Test func noListenerKeepsTheGrips() {
        let taps = Taps()
        let track = track(holding: 1, listening: false)
        #expect(track.debugCapMarks == ["grip", "grip"], "a cap offers a + nobody answers")

        track.onSeam = { taps.seams.append($0) }
        track.layoutIfNeeded()
        #expect(track.debugCapMarks == ["plus", "plus"], "a listener arrived and the caps did not say so")
    }

    @Test func aCapSaysWhatItsCutCarriesAsItChanges() {
        var segments = Self.cutAtThreeAndSix
        segments[0].transitionOut = .dipToBlack
        segments[1].transitionOut = .zoom
        let track = track(segments, holding: 1)
        #expect(track.debugCapMarks == ["moon.fill", "arrow.up.left.and.arrow.down.right"])

        segments[1].transitionOut = .dipToWhite
        track.configure(duration: 10, timeline: MediaTimeline(segments: segments))
        track.layoutIfNeeded()
        #expect(track.debugCapMarks == ["moon.fill", "sun.max.fill"])

        track.select(0)
        track.layoutIfNeeded()
        #expect(track.debugCapMarks == ["grip", "moon.fill"])
    }

    /// ⚠️ **THE REPORTED DEFECT**: *"quand on cut … le + entre les segments doit
    /// forcément et tout de suite apparaître"*. A split and the hold it hands
    /// back, then ONE layout.
    @Test func aSplitsPlusIsInTheCapOnTheSameLayout() {
        let track = track([])
        track.configure(duration: 10, timeline: MediaTimeline(segments: [
            MediaSegment(start: 0, end: 5), MediaSegment(start: 5, end: 10)
        ]))
        track.select(0)
        track.layoutIfNeeded()

        #expect(track.debugCapMarks == ["grip", "plus"], "the new cut shows \(track.debugCapMarks)")
        #expect(track.debugSeamMarks.isEmpty)
    }

    /// ⚠️ **A TAP ON A CAP'S + OPENS ITS CUT** — anywhere a finger wide, inwards
    /// from the cap's outer edge — and leaves the piece held.
    @Test func aTapOnACapsPlusOpensItsCutAndKeepsThePiece() {
        let taps = Taps()
        let track = track(holding: 1, taps: taps)
        let start = track.debugStartGrip
        let end = track.debugEndGrip

        track.debugTapped(atContentX: end.midX)
        #expect(taps.seams == [1])
        track.debugTapped(atContentX: start.midX)
        #expect(taps.seams == [1, 0])
        track.debugTapped(atContentX: end.maxX - 43.5)
        #expect(taps.seams == [1, 0, 1], "a tap on the held film beside the end cap was not heard")
        track.debugTapped(atContentX: start.minX + 43.5)
        #expect(taps.seams == [1, 0, 1, 0], "a tap on the held film beside the start cap was not heard")

        track.debugTapped(atContentX: end.maxX - 45)
        track.debugTapped(atContentX: start.minX + 45)
        #expect(taps.seams == [1, 0, 1, 0], "a tap past a finger's width opened a cut")
        #expect(track.selectedPiece == 1 && track.debugSelectionIsDrawn, "the piece was put down")
    }

    /// ⚠️ **F8c STILL HOLDS**: the neighbour's film begins at the cap's outer
    /// edge, and a tap there takes the neighbour.
    @Test func aTapOnTheNeighboursVisibleFilmStillTakesIt() {
        let taps = Taps()
        let track = track(holding: 1, taps: taps)

        track.debugTapped(atContentX: track.debugEndGrip.maxX + 1)
        #expect(track.selectedPiece == 2, "the next section was not taken")

        track.select(1)
        track.layoutIfNeeded()
        track.debugTapped(atContentX: track.debugStartGrip.minX - 1)
        #expect(track.selectedPiece == 0, "the previous section was not taken")
        #expect(taps.seams.isEmpty, "a tap on a neighbour opened a cut: \(taps.seams)")
    }

    /// ⚠️ **A TAP AND A DRAG AT THE SAME POINT NAME THE SAME CAP**, down to the
    /// tie between two caps a few points apart.
    @Test func aTapAndADragAtTheSamePointNameTheSameEdge() throws {
        let taps = Taps()
        let track = track([
            MediaSegment(start: 0, end: 5), MediaSegment(start: 5, end: 6), MediaSegment(start: 6, end: 10)
        ], holding: 1, taps: taps)
        for _ in 0..<10 { track.debugPinch(by: 0.2) }
        track.layoutIfNeeded()
        try #require(track.debugPointsPerSecond == 12, "guard: \(track.debugPointsPerSecond)pt/s")

        let middle = (track.debugStartGrip.midX + track.debugEndGrip.midX) / 2
        for x in [track.debugStartGrip.midX, middle - 0.5, middle, middle + 0.5, track.debugEndGrip.midX] {
            let before = taps.seams.count
            track.debugTapped(atContentX: x)
            try #require(taps.seams.count == before + 1, "a tap at \(x) opened nothing")
            let seam = try #require(taps.seams.last)
            track.debugTakeHold(at: x)
            let grip = track.debugGrip
            track.debugRelease()
            track.layoutIfNeeded()
            #expect(grip != nil, "a drag at \(x) took no handle")
            #expect((seam == 0) == (grip == .start), "at \(x) the tap opened cut \(seam) and the drag took \(String(describing: grip))")
        }

        // Held first, only the end cap stands on a cut — and at the exact
        // middle a drag takes the START, so a tap there opens nothing.
        track.select(0)
        track.layoutIfNeeded()
        try #require(track.debugCapMarks == ["grip", "plus"])
        let tie = (track.debugStartGrip.midX + track.debugEndGrip.midX) / 2
        let before = taps.seams.count
        track.debugTapped(atContentX: tie)
        #expect(taps.seams.count == before, "a tap at the tie opened cut \(taps.seams.last ?? -1)")
        track.debugTakeHold(at: tie)
        #expect(track.debugGrip == .start)
        track.debugRelease()
    }

    /// ⚠️ **A DRAG ON A CAP'S + IS THE HANDLE'S** — *"si on déplace la pince ça
    /// prend le comportement de la pince"* — and the + goes with the cap.
    @Test func aDragOnACapsPlusTrimsAndOpensNothing() {
        let taps = Taps()
        let track = track(holding: 1, taps: taps)

        track.debugTakeHold(at: track.debugEndGrip.midX)
        track.debugDrag(byPoints: -30)
        track.debugRelease()
        track.layoutIfNeeded()
        let trimmed = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(abs(trimmed[1].end - 5.5) < 0.01, "the end is at \(trimmed[1].end)")
        #expect(taps.seams.isEmpty, "the drag opened a cut")
        #expect(track.debugCapMarks == ["plus", "plus"])
        #expect(abs(track.debugEndGrip.minX - 330) < 0.01, "the cap is at \(track.debugEndGrip.minX)")
        #expect(track.debugTapYieldsToTheHandle, "a drag on a cap's + could also be a tap")

        track.debugTapped(atContentX: track.debugEndGrip.midX)
        #expect(taps.seams == [1], "the + did not move with its cap")

        track.debugTakeHold(at: track.debugStartGrip.midX)
        track.debugDrag(byPoints: 30)
        track.debugRelease()
        track.layoutIfNeeded()
        let cropped = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(abs(cropped[1].start - 3.5) < 0.01, "the start is at \(cropped[1].start)")
        #expect(taps.seams == [1], "the drag opened a cut")
    }

    @Test func aHeldPiecesCutsStayReachableByVoiceOver() throws {
        let taps = Taps()
        var segments = Self.cutAtThreeAndSix
        segments[0].transitionOut = .dipToWhite
        let track = track(segments, holding: 1, taps: taps)
        let actions = try #require(track.accessibilityCustomActions)
        try #require(actions.map(\.name) == [
            "Transition after clip 1: Fade through white", "Transition after clip 2: none"
        ], "got \(actions.map(\.name))")
        _ = actions[1].actionHandler?(actions[1])
        #expect(taps.seams == [1])

        segments[1].transitionOut = .zoom
        track.configure(duration: 10, timeline: MediaTimeline(segments: segments))
        track.layoutIfNeeded()
        #expect(track.accessibilityCustomActions?.last?.name == "Transition after clip 2: Zoom",
                "got \(track.accessibilityCustomActions?.map(\.name) ?? [])")
    }

    /// ⚠️ **ACTIVATING THE TRACK NEVER OPENS A CUT** — right after a split the
    /// needle stands on the held half's +.
    @Test func aVoiceOverActivationTakesThePieceAndNeverOpensACut() throws {
        let taps = Taps()
        let track = track([MediaSegment(start: 0, end: 5), MediaSegment(start: 5, end: 10)], holding: 0, taps: taps)
        track.debugScroll(toContentOffset: 299 - 195)
        track.layoutIfNeeded()
        try #require(track.debugCapMarks == ["grip", "plus"])

        #expect(track.accessibilityActivate())
        #expect(taps.seams.isEmpty, "activating opened the cut under the needle")
        #expect(track.selectedPiece == 0)

        track.select(nil, notify: false)
        track.layoutIfNeeded()
        try #require(track.debugSeamMarks.map(\.index) == [0], "guard: a disc stands by the needle")
        #expect(track.accessibilityActivate())
        #expect(taps.seams.isEmpty, "activating opened the disc under the needle")
        #expect(track.selectedPiece == 0, "activating did not take the piece under the needle")
    }

    /// ⚠️ **WITH NOBODY LISTENING A CAP IS A PLAIN HANDLE**, and a press on it
    /// carries the piece it belongs to — not the neighbour whose film it is
    /// drawn on (F8c).
    @Test func withNoListenerAPressOnTheHeldCapCarriesTheHeldPiece() {
        let track = track(holding: 0, listening: false)
        track.debugLift(atContentX: track.debugEndGrip.midX)
        #expect(track.debugCarrying == 0, "the press lifted \(String(describing: track.debugCarrying))")
        track.debugDrop()
    }

    /// ⚠️ **A PRESS ON A CAP'S + IS A TAP** — *"quand on appuie sur le + de la
    /// pince ça montre les transitions"*, however long — read where it LANDED.
    @Test func aPressOnACapsPlusLiftsNothing() {
        let track = track(holding: 1)
        #expect(!track.debugWouldLift(atContentX: track.debugEndGrip.midX), "a press on the end cap's + lifts")
        #expect(!track.debugWouldLift(atContentX: track.debugStartGrip.midX), "a press on the start cap's + lifts")
        #expect(!track.debugWouldLift(landedAt: track.debugEndGrip.midX), "a press that landed on the + lifts")
        #expect(track.debugWouldLift(landedAt: 90), "guard: a press on the film lifts nothing")
    }

    /// ⚠️ **A TAP IS READ WHERE IT LANDED** — the film moves under a resting
    /// finger while the clip plays — and the landing is forgotten afterwards.
    @Test func aTapIsReadWhereItLanded() {
        let taps = Taps()
        let track = track(holding: 1, taps: taps)

        track.debugTapped(landedAt: track.debugEndGrip.midX, reportedAt: track.debugEndGrip.maxX + 30)
        #expect(taps.seams == [1], "the tap was read where it was reported")
        #expect(track.selectedPiece == 1)

        track.debugTapped(atContentX: track.debugEndGrip.maxX + 20)
        #expect(track.selectedPiece == 2, "a stale landing answered the next tap")
        #expect(taps.seams == [1])
    }

    /// ⚠️ **EVERY CUT IS SPOKEN, DRAWN OR NOT** — thinned away, or hidden beside
    /// a held cap.
    @Test func everyCutIsReachableByVoiceOver() throws {
        let track = track([
            MediaSegment(start: 0, end: 3), MediaSegment(start: 3, end: 6),
            MediaSegment(start: 6, end: 7, speed: 4, transitionOut: .dipToBlack), MediaSegment(start: 7, end: 10)
        ], holding: 1)
        try #require(track.debugSeamMarks.isEmpty, "guard: the short piece's cut shows a disc \(track.debugSeamMarks)")
        #expect(track.accessibilityCustomActions?.map(\.name) == [
            "Transition after clip 1: none", "Transition after clip 2: none",
            "Transition after clip 3: Fade through black"
        ], "got \(track.accessibilityCustomActions?.map(\.name) ?? [])")

        let tenPieces = (0..<10).map { MediaSegment(start: Double($0), end: Double($0 + 1)) }
        let crowded = self.track(tenPieces)
        for _ in 0..<10 { crowded.debugPinch(by: 0.2) }
        crowded.layoutIfNeeded()
        try #require(crowded.debugSeamMarks.count < 9, "guard: nothing was thinned")
        #expect(crowded.accessibilityCustomActions?.count == 9, "a thinned cut cannot be reached")
    }

    /// ⚠️ **AFTER A CARRY THE CAPS READ THE NEW ORDER** — the transition travels
    /// with its piece, and a piece put down last loses its own.
    @Test func theCapsPlusFollowsItsCutAfterADrop() throws {
        let track = track([
            MediaSegment(start: 0, end: 3, transitionOut: .dipToWhite),
            MediaSegment(start: 3, end: 6, transitionOut: .dipToBlack),
            MediaSegment(start: 6, end: 10)
        ])
        track.debugLift(atContentX: 90)
        track.layoutIfNeeded()
        try #require(track.debugCarrying == 0)
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.debugDrop()
        track.layoutIfNeeded()
        try #require(track.selectedPiece == 1, "guard: the carried piece is held at \(String(describing: track.selectedPiece))")
        #expect(track.debugCapMarks == ["moon.fill", "sun.max.fill"], "got \(track.debugCapMarks)")

        track.debugLift(atContentX: track.debugPieceFrames[1].lowerBound + 90)
        track.layoutIfNeeded()
        try #require(track.debugCarrying == 1)
        track.debugCarry(toTrackX: track.debugShotFrames[2].midX)
        track.debugDrop()
        track.layoutIfNeeded()
        try #require(track.selectedPiece == 2)
        #expect(track.debugCapMarks == ["plus", "grip"], "got \(track.debugCapMarks)")
        let last = try #require(track.debugTimeline.segments.last)
        try #require(last.start == 0, "guard: the white piece is not last: \(track.debugTimeline.segments)")
        #expect(last.transitionOut == nil, "the piece put down last kept its transition")
    }

    /// Every symbol a cap can carry stands whole inside the 12pt cap, at its own
    /// size.
    @Test func everyCapGlyphFitsInsideItsCap() throws {
        let cases: [(VideoTransitionKind?, String)] = [
            (nil, "plus"), (.dipToBlack, "moon.fill"), (.dipToWhite, "sun.max.fill"),
            (.zoom, "arrow.up.left.and.arrow.down.right")
        ]
        for (kind, name) in cases {
            var segments = Self.cutAtThreeAndSix
            segments[1].transitionOut = kind
            let track = track(segments, holding: 1)
            #expect(track.debugCapMarks[1] == name)
            let glyph = try #require(track.debugCapGlyphs[1])
            let cap = track.debugEndGrip
            #expect(glyph.frame.minX >= cap.minX + 0.5 && glyph.frame.maxX <= cap.maxX - 0.5,
                    "\(name) at \(glyph.frame) spills out of \(cap)")
            #expect(glyph.frame.width >= glyph.image.width - 0.01 && glyph.frame.height >= glyph.image.height - 0.01,
                    "\(name) is squeezed: \(glyph.frame.size) for \(glyph.image)")
        }
    }

    /// ⚠️ **CHARTER T8: A BEAT OR A DRAG LOOKS NO SYMBOL UP.**
    @Test func aDragChangesNoCapGlyph() {
        let track = track(holding: 1)
        let assigned = track.debugCapGlyphImageAssignments

        for step in 0..<60 { track.debugScroll(toContentOffset: CGFloat(step) * 2) }
        track.debugTakeHold(at: track.debugEndGrip.midX)
        for _ in 0..<10 {
            track.debugDrag(byPoints: 1)
            track.layoutIfNeeded()
        }
        track.debugRelease()
        track.layoutIfNeeded()
        #expect(track.debugCapGlyphImageAssignments == assigned, "\(track.debugCapGlyphImageAssignments - assigned) lookups")
        #expect(track.debugCapMarks == ["plus", "plus"])

        var segments = Self.cutAtThreeAndSix
        segments[1].transitionOut = .zoom
        track.configure(duration: 10, timeline: MediaTimeline(segments: segments))
        track.layoutIfNeeded()
        #expect(track.debugCapGlyphImageAssignments == assigned + 1, "guard: a new symbol was not looked up")
    }

    @Test func aSeamIsReachableByVoiceOver() throws {
        let taps = Taps()
        var segments = Self.cutAtThreeAndSix
        segments[0].transitionOut = .dipToWhite
        let track = track(segments, taps: taps)
        let actions = try #require(track.accessibilityCustomActions)
        #expect(actions.map(\.name) == [
            "Transition after clip 1: Fade through white", "Transition after clip 2: none"
        ])
        _ = actions.last?.actionHandler?(actions[1])
        #expect(taps.seams == [1])
    }

    @Test func everyTransitionGlyphExists() {
        let names = VideoTransitionKind.allCases.map(\.glyph) + [
            MediaTransitionCatalog.addGlyph, MediaTransitionCatalog.noneGlyph, MediaTransitionCatalog.closeGlyph
        ]
        for name in names {
            #expect(UIImage(systemName: name) != nil, "no symbol named \(name)")
        }
    }
}
