import DesignSystem
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE FILM, COLLAPSED INTO A LINE WHILE A CUT'S TRANSITION IS CHOSEN.**
///
/// Asked for in these words: *"la timeline/piste se réduit en hauteur (vers le
/// haut) sous forme de trait … ce qui nous donne verticalement : graduation
/// temps / ligne timeline compacte / scrollview des transitions"*, and *"cette
/// plage doit être en surbrillance … dans la timeline compacte"*.
@MainActor
struct MediaTimelineCompactTests {
    private static let cutAtThreeAndSix = [
        MediaSegment(start: 0, end: 3), MediaSegment(start: 3, end: 6), MediaSegment(start: 6, end: 10)
    ]

    private func track(
        _ segments: [MediaSegment] = cutAtThreeAndSix, duration: Double = 10, width: CGFloat = 390
    ) -> MediaTimelineTrackView {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: width, height: MediaTimelineTrackView.height)
        track.onSeam = { _ in }
        track.configure(duration: duration, timeline: MediaTimeline(segments: segments))
        track.layoutIfNeeded()
        return track
    }

    @MainActor
    private final class Asked {
        var batches: [[Double]] = []
    }

    private func hosted(_ track: MediaTimelineTrackView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.addSubview(track)
        window.isHidden = false
        track.layoutIfNeeded()
        return window
    }

    // MARK: - The height and the film

    /// ⚠️ **THE BAND NEVER CHANGES HEIGHT FOR THE ROW — CHARTER F28.** The line
    /// is drawn inside the track; the room below it is the row's.
    @Test func compactKeepsTheTrackItsHeight() throws {
        #expect(MediaTimelineTrackView.compactHeight == 25)
        let tools = MediaTimelineToolsView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.addSubview(tools)
        tools.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            tools.topAnchor.constraint(equalTo: window.topAnchor)
        ])
        window.isHidden = false
        tools.track.configure(duration: 10, timeline: MediaTimeline(segments: Self.cutAtThreeAndSix))
        window.layoutIfNeeded()
        let before = tools.frame.height
        #expect(before == MediaTimelineTrackView.height, "guard: the tools are \(before)pt")

        #expect(tools.openTransitions(atSeam: 0, chosen: nil, rehearsal: 2...4, window: 3...3, animated: false))
        window.layoutIfNeeded()

        #expect(tools.frame.height == before, "the band moved: \(before) → \(tools.frame.height)")
        #expect(tools.track.frame.height == MediaTimelineTrackView.height)
    }

    @Test func theFilmCollapsesUpwardsIntoTheLine() throws {
        let track = track()
        #expect(track.setCompact(true, animated: false))
        track.layoutIfNeeded()

        let film = track.debugFilmFrame
        #expect(abs(film.minY - 19.5) < 0.01 && abs(film.height - 4) < 0.01, "the film is at \(film)")
        #expect(track.debugFilmAlpha == 0, "the pictures still show")
        let lines = track.debugLineFrames
        try #require(lines.count == 3, "got \(lines)")
        #expect(lines.allSatisfy { abs($0.minY - 19.5) < 0.01 && abs($0.height - 4) < 0.01 }, "got \(lines)")
        #expect(lines[1].minX > lines[0].maxX, "the line lost its daylight: \(lines)")
    }

    /// ⚠️ **READ OFF THE ANIMATIONS, NEVER THE MODEL VALUES** — the model is at
    /// the end the moment the block runs, animated or not.
    @Test func theCollapseIsAnimatedNotSnapped() {
        let track = track()
        let window = hosted(track)
        defer { window.isHidden = true }

        track.setCompact(true, animated: true)

        let film = track.debugFilmOwnAnimations
        #expect(film.contains { $0.contains("transform") }, "the film snapped: \(film)")
        #expect(film.contains { $0.contains("opacity") }, "the pictures snapped: \(film)")
        #expect(track.debugLineAnimations.contains { $0.contains("opacity") },
                "the line snapped in: \(track.debugLineAnimations)")
    }

    /// ⚠️ **AND LAID OUT WHILE COLLAPSED, IT STAYS COLLAPSED.** A frame assigned
    /// under the transform would put the film somewhere nobody asked for.
    @Test func theFilmComesBackWhereItWas() {
        let track = track()
        let before = track.debugFilmFrame

        track.setCompact(true, animated: false)
        track.setNeedsLayout()
        track.layoutIfNeeded()
        let collapsed = track.debugFilmFrame
        #expect(abs(collapsed.minY - 19.5) < 0.01 && abs(collapsed.height - 4) < 0.01,
                "a layout undid the collapse: \(collapsed)")
        track.setCompact(false, animated: false)
        track.layoutIfNeeded()

        #expect(track.debugFilmFrame == before, "the film came back at \(track.debugFilmFrame), not \(before)")
        #expect(track.debugFilmAlpha == 1)
        #expect(track.debugLineFrames.isEmpty, "the line stayed")
    }

    /// The collapse brings the start of the stretch under the needle — the
    /// moment the preview is about to play.
    @Test(arguments: [false, true])
    func theCollapseBringsTheStretchUnderTheNeedle(animated: Bool) {
        let track = track()
        let window = hosted(track)
        defer { window.isHidden = true }
        track.debugScroll(toContentOffset: 5 * 60 - 195)

        track.setCompact(true, bringingUnderTheNeedle: 3.5, animated: animated)

        #expect(abs(track.playedSecondsUnderNeedle - 3.5) < 0.01,
                "the needle is on \(track.playedSecondsUnderNeedle)s (animated: \(animated))")
    }

    @Test func theNeedleStopsAtTheLine() {
        let track = track()
        #expect(track.debugNeedleFrame.height == MediaTimelineTrackView.height)
        track.setCompact(true, animated: false)
        track.layoutIfNeeded()
        #expect(track.debugNeedleFrame.height == MediaTimelineTrackView.compactHeight,
                "the needle runs through the row: \(track.debugNeedleFrame)")
        track.setCompact(false, animated: false)
        track.layoutIfNeeded()
        #expect(track.debugNeedleFrame.height == MediaTimelineTrackView.height)
    }

    // MARK: - The lit stretch

    /// ⚠️ **ON THE PLAYED CLOCK.** The first piece runs at 2x, so the cut is at
    /// two seconds of the result and four of the file — and the line is drawn
    /// in the result's.
    @Test func theRehearsalIsLitWhereItPlays() throws {
        let segments = [
            MediaSegment(start: 0, end: 4, speed: 2, transitionOut: .dipToBlack),
            MediaSegment(start: 4, end: 10)
        ]
        let track = track(segments)
        let timeline = MediaTimeline(segments: segments)
        let rehearsal = try #require(MediaTimelining.rehearsal(
            atSeam: 0, in: timeline, withinSource: 10, lead: track.rehearsalLead
        ))
        track.setCompact(true, animated: false)
        track.showRehearsal(rehearsal.range, window: rehearsal.window, animated: false)

        let bar = try #require(track.debugRehearsalFrame, "nothing is lit")
        let window = try #require(track.debugWindowFrame, "the transition is not marked")
        #expect(abs(bar.minX - CGFloat(rehearsal.range.lowerBound) * 60) < 0.01, "the stretch starts at \(bar.minX)")
        #expect(abs(bar.maxX - CGFloat(rehearsal.range.upperBound) * 60) < 0.01, "the stretch ends at \(bar.maxX)")
        #expect(abs(window.midX - 120) < 0.01, "the transition is marked at \(window.midX), not at the cut")
        #expect(abs(window.width - 30) < 0.01, "the transition is \(window.width)pt wide")
        #expect(track.debugWindowCorner == 4, "the transition's corners are \(track.debugWindowCorner)pt")
        #expect(bar.midY == track.debugLineFrames.first?.midY, "the stretch is off the line")
    }

    /// ⚠️ **A BARE CUT'S MARK IS A PILL, NEVER A SPIKE** — Core Animation does
    /// not clamp a radius, and the tick is three points wide.
    @Test func aBareCutsMarkIsAPill() throws {
        let track = track()
        track.setCompact(true, animated: false)
        track.showRehearsal(1.8...4.2, window: 3...3, animated: false)

        let window = try #require(track.debugWindowFrame)
        #expect(abs(window.width - 3) < 0.01, "guard: the bare mark is \(window.width)pt")
        #expect(track.debugWindowCorner == 1.5, "a 3pt mark is rounded \(track.debugWindowCorner)pt")
    }

    /// ⚠️ **CHARTER T6, COLLAPSED TOO.** A four-minute piece is a line 14400pt
    /// long; clipped to the screen and its margin, no layer comes near the
    /// Metal limit.
    @Test func theRehearsalIsClippedToTheVisibleWindow() throws {
        let track = track([MediaSegment(start: 0, end: 120), MediaSegment(start: 120, end: 240)], duration: 240)
        track.setCompact(true, animated: false)
        track.showRehearsal(0...240, window: 119...121, animated: false)
        track.layoutIfNeeded()

        let most = 390 + 2 * MediaTimelining.filmMargin
        let bar = try #require(track.debugRehearsalFrame)
        #expect(bar.width <= most, "the stretch is \(bar.width)pt wide")
        #expect(track.debugLineFrames.allSatisfy { $0.width <= most }, "got \(track.debugLineFrames)")
        #expect(track.debugLayersPastTheMetalLimit(scale: 3).isEmpty,
                "past the limit: \(track.debugLayersPastTheMetalLimit(scale: 3))")
    }

    /// ⚠️ **THE WHOLE STRETCH FITS TO THE NEEDLE'S RIGHT**, so it can be read
    /// from its start — and never less than half a second either side.
    @Test func theLeadFitsTheHalfTrack() {
        let track = track()
        #expect(abs(track.rehearsalLead - 1.2417) < 0.001, "the lead is \(track.rehearsalLead)s")
        for _ in 0..<10 { track.debugPinch(by: 2) }
        track.layoutIfNeeded()
        #expect(track.debugPointsPerSecond == MediaTimelining.closestPointsPerSecond,
                "guard: \(track.debugPointsPerSecond)pt/s")
        #expect(track.rehearsalLead == 0.5, "zoomed in, the lead is \(track.rehearsalLead)s")
    }

    // MARK: - What it refuses

    @Test func compactRefusesEveryTrackGesture() {
        // The last piece stops short of the file, so a VoiceOver swipe has
        // somewhere to take its end.
        let track = track([
            MediaSegment(start: 0, end: 3), MediaSegment(start: 3, end: 6), MediaSegment(start: 6, end: 8)
        ])
        #expect(track.debugGesturesThatWouldBegin.contains("pinch"), "guard: \(track.debugGesturesThatWouldBegin)")
        let before = track.debugTimeline

        track.setCompact(true, animated: false)
        track.layoutIfNeeded()

        #expect(track.debugGesturesThatWouldBegin.isEmpty, "still allowed: \(track.debugGesturesThatWouldBegin)")
        #expect(track.debugScrollIsEnabled == false, "the line can be scrolled by hand")
        track.debugTapped(atContentX: 90)
        #expect(track.selectedPiece == nil, "a tap took piece \(track.selectedPiece ?? -1)")
        track.accessibilityIncrement()
        track.accessibilityDecrement()
        #expect(track.debugTimeline == before, "VoiceOver trimmed the collapsed track")
        #expect(track.accessibilityLabel == "Transition timeline")
        // ⚠️ Consumed: handed back, VoiceOver's own tap would land on the row.
        #expect(track.accessibilityActivate(), "a VoiceOver activation was handed back")
        #expect(track.selectedPiece == nil && track.debugTimeline == before)
        #expect(!track.accessibilityTraits.contains(.adjustable), "the line still says it can be adjusted")
        #expect(!track.debugSeamMarks.isEmpty, "guard: the + marks are gone rather than asleep")
        #expect(track.debugSeamTakesTouches == false, "a hidden + still takes taps")
    }

    /// ⚠️ **CHARTER T2: NOTHING IS DECODED FOR A FILM NOBODY SEES**, and the
    /// return asks only for the squares it has never had.
    @Test func compactAsksForNoFrames() async throws {
        let track = track([], duration: 30)
        let asked = Asked()
        track.framesProvider = { seconds, _, _ in
            await MainActor.run {
                asked.batches.append(seconds)
                var made: [Double: UIImage] = [:]
                for at in seconds { made[at] = TrackFixture.swatch(.green) }
                return made
            }
        }
        track.setNeedsLayout()
        track.layoutIfNeeded()
        for _ in 0..<50 where asked.batches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!asked.batches.isEmpty, "guard: the open film asked for nothing")
        try await Task.sleep(for: .milliseconds(50))
        let before = Set(asked.batches.flatMap { $0 })
        asked.batches.removeAll()

        track.setCompact(true, animated: false)
        for step in 1...60 {
            track.follow(playedSeconds: Double(step) * 10 / 60)
            track.layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked.batches.isEmpty, "the collapsed film asked for \(asked.batches.flatMap { $0 }.count) pictures")

        track.setCompact(false, animated: false)
        track.layoutIfNeeded()
        for _ in 0..<50 where asked.batches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let after = Set(asked.batches.flatMap { $0 })
        #expect(!after.isEmpty, "the film came back without asking for the stretch it had not seen")
        #expect(after.isDisjoint(with: before), "asked again for \(after.intersection(before).sorted())")
    }

    /// ⚠️ **A MOVE OF THE COLLAPSED FILM IS NEVER A SCRUB.** The preview is
    /// looping a stretch; a seek from the track would pull it off.
    @Test func aMoveOfTheLineIsNotAScrub() {
        let track = track()
        var scrubs = 0
        track.onScrub = { _ in scrubs += 1 }
        track.debugScroll(toContentOffset: 0)
        #expect(scrubs == 1, "guard: a move of the open film is a scrub")
        scrubs = 0

        track.setCompact(true, bringingUnderTheNeedle: 3, animated: false)
        #expect(!track.debugIsEasing, "guard: a follow is still holding the scrub back")
        track.debugScroll(toContentOffset: 100)
        track.layoutIfNeeded()

        #expect(scrubs == 0, "the collapsed film scrubbed \(scrubs) times")
    }

    /// ⚠️ **THE `+` MARKS FOLD INTO THE LINE WITH THE FILM**, rather than
    /// shrinking where the film was — over the row that is fading in.
    @Test func theMarksFoldIntoTheLine() throws {
        let track = track()
        try #require(!track.debugSeamMarkFrames.isEmpty)
        track.setCompact(true, animated: false)
        track.layoutIfNeeded()

        let line = try #require(track.debugLineFrames.first)
        for mark in track.debugSeamMarkFrames {
            #expect(abs(mark.midY - line.midY) < 0.5, "a + folded to \(mark.midY), the line is at \(line.midY)")
        }
    }

    /// ⚠️ **COLLAPSING PUTS THE PIECE DOWN**, so a cap's + leaves with its cap,
    /// every cut folds into the line as a disc, and none of it answers a finger.
    @Test func aCollapseTakesTheCapsPlusAwayAndFoldsItsCuts() throws {
        let track = track()
        var seams: [Int] = []
        track.onSeam = { seams.append($0) }
        track.select(1)
        track.layoutIfNeeded()
        try #require(track.debugCapMarks == ["plus", "plus"])
        let wasEnd = track.debugEndGrip.midX

        track.setCompact(true, animated: false)
        track.layoutIfNeeded()
        #expect(track.debugSelectionInkShowing == false, "the caps outlived the collapse")
        #expect(track.debugSeamMarks.map(\.index) == [0, 1], "got \(track.debugSeamMarks.map(\.index))")
        let line = try #require(track.debugLineFrames.first)
        #expect(track.debugSeamMarkFrames.allSatisfy { abs($0.midY - line.midY) < 0.5 })
        #expect(track.debugSeamTakesTouches == false)
        track.debugTapped(atContentX: wasEnd)
        #expect(seams.isEmpty, "a tap on the collapsed line opened a cut")

        track.setCompact(false, animated: false)
        track.layoutIfNeeded()
        #expect(track.selectedPiece == nil)
        #expect(track.debugSeamMarks.count == 2)
    }

    @Test func aCollapseUnderAHeldHandleIsRefused() throws {
        let track = track()
        track.select(1)
        track.layoutIfNeeded()
        let centres = try #require(track.debugHandleCentres)
        track.debugTakeHold(at: centres.end)

        #expect(track.setCompact(true, animated: false) == false)
        #expect(track.isCompact == false)
        track.debugRelease()
    }
}
