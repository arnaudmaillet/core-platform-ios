import DesignSystem
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **CHOOSING A CUT'S TRANSITION, THROUGH THE SCREEN.**
///
/// Asked for in these words: a `+` on each cut; tapping it collapses the track
/// and opens a row of transitions; *"lorsqu'on sélectionne une transition, le
/// média joue la transition (une plage de quelques secondes avant jusqu'à
/// quelques secondes après)"*; a glass cross closes the row and gives the
/// classic timeline back; and the `+` then shows the transition's own icon.
///
/// What this suite asks is the wiring — what reaches the stored timeline, what
/// the preview is told to play and loop, and that every way off the clip puts
/// the row away. The arithmetic is `MediaTransitionModelTests`'; the drawing is
/// `MediaTimelineCompactTests`'.
@MainActor
struct MediaEditorTransitionsTests {
    private enum Mode {
        static let trim = 5
        static let filters = 3
    }

    private struct Screen {
        let editor: MediaEditorViewController
        let window: UIWindow
        let navigation: UINavigationController
        let preview: StubPreview
    }

    private final class StubLibrary: MediaLibraryReading {
        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }
        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }

        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            FileManager.default.temporaryDirectory.appendingPathComponent("\(item).mov")
        }
    }

    private final class StubPreview: MediaVideoPreviewing {
        private(set) var plans: [VideoExportPlan] = []
        private(set) var landings: [VideoLoadLanding] = []
        func load(
            _ plan: VideoExportPlan, in surface: VideoRenderView,
            landing: @escaping @MainActor () -> VideoLoadLanding?
        ) async {
            guard let landed = landing() else { return }
            plans.append(plan)
            landings.append(landed)
        }

        /// Every loop range the screen asked for, in order.
        private(set) var loops: [ClosedRange<Double>?] = []
        func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {
            loops.append(range)
        }

        func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {}
        func stop(_ surface: VideoRenderView) {}
        var paused: Bool? = false
        func isPaused(in surface: VideoRenderView) -> Bool? { paused }
        func isBound(_ surface: VideoRenderView) -> Bool { false }
        /// Every pause and resume, in order — and the stub's own state follows.
        private(set) var pauses: [Bool] = []
        func setPaused(_ paused: Bool, in surface: VideoRenderView) {
            pauses.append(paused)
            self.paused = paused
        }

        var headSeconds: Double?
        func playheadSeconds(in surface: VideoRenderView) -> Double? { headSeconds }
        func advancingRate(in surface: VideoRenderView) -> Double { 0 }
        /// Every live look, mute and pair of levels the screen asked for, in
        /// order — recorded, because a stub that swallowed them could not say
        /// whether the screen ever asked.
        private(set) var liveLooks: [FrameLook] = []
        func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) { liveLooks.append(look) }
        private(set) var mutes: [Bool] = []
        func setMuted(_ muted: Bool, in surface: VideoRenderView) { mutes.append(muted) }
        private(set) var mixLevels: [(music: Double, original: Double)] = []
        func setMixLevels(music: Double, original: Double, in surface: VideoRenderView) {
            mixLevels.append((music, original))
        }
        private(set) var seeks: [Double] = []
        func seek(toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double) {
            seeks.append(seconds)
        }

        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] { [:] }
    }

    private static func videos(_ count: Int) -> [MediaLibraryItem] {
        (0..<count).map { MediaLibraryItem(id: "video-\($0)", kind: .video(duration: 10)) }
    }

    private func open(_ items: [MediaLibraryItem]) -> Screen {
        let preview = StubPreview()
        let editor = MediaEditorViewController(
            items: items, library: StubLibrary(), preview: preview
        ) { _, _ in UIViewController() }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        editor.beginAppearanceTransition(true, animated: false)
        editor.endAppearanceTransition()
        window.layoutIfNeeded()
        return Screen(editor: editor, window: window, navigation: navigation, preview: preview)
    }

    private func choose(_ mode: Int, on screen: Screen) {
        screen.editor.debugCategoryBar.select(mode)
        screen.window.layoutIfNeeded()
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func landed(_ screen: Screen, beyond count: Int) async throws {
        try await settle(until: {
            screen.preview.plans.count > count && !screen.editor.debugPreviewIsPending
        })
        try #require(screen.preview.plans.count > count, "no new arrangement reached the preview")
        try #require(!screen.editor.debugPreviewIsPending, "the new arrangement never landed")
    }

    private func tools(in screen: Screen) throws -> MediaTimelineToolsView {
        try #require(screen.editor.debugBand.content as? MediaTimelineToolsView)
    }

    /// The trim band open on a ten-second clip cut at five, with the real length
    /// known, nothing held and the first load landed.
    private func cutClip(_ count: Int = 1) async throws -> (Screen, MediaTimelineToolsView) {
        let screen = open(Self.videos(count))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        try await landed(screen, beyond: 0)
        let track = tools.track
        track.debugScroll(
            toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 5, trackWidth: track.bounds.width,
                pointsPerSecond: track.debugPointsPerSecond
            )
        )
        screen.editor.debugSplitAtTheNeedle()
        track.select(nil, notify: false)
        screen.window.layoutIfNeeded()
        try #require(track.debugSeamMarks.map(\.index) == [0], "guard: marks \(track.debugSeamMarks)")
        return (screen, tools)
    }

    private func rehearsal(
        of timeline: MediaTimeline, on track: MediaTimelineTrackView
    ) throws -> (range: ClosedRange<Double>, window: ClosedRange<Double>) {
        try #require(MediaTimelining.rehearsal(
            atSeam: 0, in: timeline, withinSource: 10, lead: track.rehearsalLead
        ))
    }

    // MARK: - Opening

    /// ⚠️ **THE PICTURE DOES NOT MOVE.** The band keeps its height — and an open
    /// row of rates is put away first, once.
    @Test func tappingASeamOpensTheRowWithoutMovingThePicture() async throws {
        let (screen, tools) = try await cutClip()
        let band = screen.editor.debugBand.frame.height
        let dots = screen.editor.debugPageDotsTop
        screen.editor.debugActionBar.debugTap(MediaEditorViewController.TrackAction.speed.rawValue)
        screen.window.layoutIfNeeded()
        #expect(screen.editor.debugBand.frame.height > band, "guard: the rates did not open")

        tools.track.debugTapSeam(0)
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugTransitionSeam == 0, "the row did not open")
        #expect(tools.transitions.isOpen && tools.track.isCompact)
        #expect(!tools.isOfferingSpeeds, "the rates stayed open")
        #expect(screen.editor.debugBand.frame.height == band, "the band is \(screen.editor.debugBand.frame.height)")
        #expect(screen.editor.debugPageDotsTop == dots, "the picture moved")

        let timeline = tools.track.debugTimeline
        screen.editor.debugActionBar.debugTap(MediaEditorViewController.TrackAction.split.rawValue)
        screen.editor.debugActionBar.debugTap(MediaEditorViewController.TrackAction.speed.rawValue)
        #expect(tools.track.debugTimeline == timeline && !tools.isOfferingSpeeds,
                "an action reached the clip while the row was open")
    }

    @Test func openingLoopsTheRehearsal() async throws {
        let (screen, tools) = try await cutClip()
        let expected = try rehearsal(of: tools.track.debugTimeline, on: tools.track)

        tools.track.debugTapSeam(0)

        #expect(screen.preview.loops.last == expected.range, "the preview loops \(screen.preview.loops)")
        #expect(screen.preview.pauses.last == false, "the stretch is not playing")
        #expect(tools.track.debugRehearsalFrame != nil, "nothing is lit")
    }

    /// The trim band open on a ten-second clip just cut at five — the left half
    /// held, as the cut hands it back.
    private func freshlyCut() async throws -> (Screen, MediaTimelineToolsView) {
        let screen = open(Self.videos(1))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        try await landed(screen, beyond: 0)
        let track = tools.track
        track.debugScroll(
            toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 5, trackWidth: track.bounds.width,
                pointsPerSecond: track.debugPointsPerSecond
            )
        )
        screen.editor.debugSplitAtTheNeedle()
        screen.window.layoutIfNeeded()
        return (screen, tools)
    }

    /// ⚠️ **THE REPORTED DEFECT**: *"quand on cut sur la timeline classique, le +
    /// entre les segments doit forcément et tout de suite apparaître"* — on the
    /// held half's closing cap, and a tap on it opens the cut.
    @Test func aCutOffersItsPlusOnTheHeldHalfAtOnce() async throws {
        let (screen, tools) = try await freshlyCut()
        let track = tools.track
        #expect(track.selectedPiece == 0, "guard: the left half is not held")
        #expect(track.debugCapMarks == ["grip", "plus"], "the cut shows \(track.debugCapMarks)")
        #expect(track.debugSeamMarks.isEmpty)
        let expected = try rehearsal(of: track.debugTimeline, on: track)

        track.debugTapped(atContentX: track.debugEndGrip.midX)

        #expect(screen.editor.debugTransitionSeam == 0, "the cap's + opened nothing")
        #expect(tools.transitions.isOpen && track.isCompact)
        #expect(track.selectedPiece == nil)
        #expect(screen.preview.loops.last == expected.range)

        let loads = screen.preview.plans.count
        tools.transitions.debugTap(.dipToBlack)
        try await landed(screen, beyond: loads)
        tools.transitions.debugTapClose()
        screen.window.layoutIfNeeded()
        #expect(track.debugSeamMarks.map(\.glyph) == ["moon.fill"])
        track.select(0)
        screen.window.layoutIfNeeded()
        #expect(track.debugCapMarks == ["grip", "moon.fill"], "the cap does not say what the cut carries")
    }

    /// ⚠️ **A DRAG FROM THE SAME + TRIMS** and opens nothing.
    @Test func aDragFromTheHeldHalfsPlusTrimsAndOpensNoRow() async throws {
        let (screen, tools) = try await freshlyCut()
        let track = tools.track

        track.debugTakeHold(at: track.debugEndGrip.midX)
        track.debugDrag(byPoints: -30)
        track.debugRelease()
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugTransitionSeam == nil, "the drag opened the row")
        #expect(!tools.transitions.isOpen && !track.isCompact)
        let trimmed = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(abs(trimmed[0].end - 4.5) < 0.01, "the end is at \(trimmed[0].end)")
        #expect(track.debugCapMarks == ["grip", "plus"])
    }

    // MARK: - Choosing

    @Test func choosingATransitionLoadsOneItemAndLandsOnItsRange() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        let loads = screen.preview.plans.count

        tools.transitions.debugTap(.dipToBlack)
        try await landed(screen, beyond: loads)

        let plan = try #require(screen.preview.plans.last)
        #expect(plan.segments.map(\.transitionOut) == [.dipToBlack, nil], "the item carries \(plan.segments)")
        let expected = try rehearsal(of: tools.track.debugTimeline, on: tools.track)
        #expect(screen.preview.landings.last == VideoLoadLanding(seconds: expected.range.lowerBound, loop: expected.range),
                "it landed on \(String(describing: screen.preview.landings.last))")
        #expect(tools.track.debugTimeline == screen.editor.debugPreviewTimeline,
                "the track and the item disagree")
        #expect(MediaTimelining.transition(atSeam: 0, in: tools.track.debugTimeline, withinSource: 10) == .dipToBlack)
    }

    @Test func twoChoicesInOneTurnLandOnce() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        let loads = screen.preview.plans.count

        tools.transitions.debugTap(.dipToBlack)
        tools.transitions.debugTap(.dipToWhite)
        try await landed(screen, beyond: loads)
        try await Task.sleep(for: .milliseconds(100))

        #expect(screen.preview.plans.count == loads + 1, "\(screen.preview.plans.count - loads) items landed")
        #expect(screen.preview.plans.last?.segments.first?.transitionOut == .dipToWhite)
    }

    /// ⚠️ **"NONE" ON A BARE CUT CHANGES NO FILM, AND STILL PLAYS IT AGAIN.**
    @Test func choosingNoneOnABareSeamReplaysWithoutALoad() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        let loads = screen.preview.plans.count
        let loops = screen.preview.loops.count

        tools.transitions.debugTap(nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(screen.preview.plans.count == loads, "a bare cut was rebuilt")
        #expect(screen.preview.loops.count == loops + 1, "the stretch was not replayed")
    }

    // MARK: - The pause

    @Test func aPauseSurvivesTheMode() async throws {
        let (screen, tools) = try await cutClip()
        screen.editor.debugTapMedia()
        #expect(screen.preview.pauses.last == true, "guard: the clip did not stop")

        tools.track.debugTapSeam(0)
        #expect(screen.preview.pauses.last == false, "the stretch does not play")
        tools.transitions.debugTapClose()

        #expect(screen.preview.pauses.last == true, "closing the row restarted a clip the author had stopped")
        #expect(tools.track.debugShowsPause == false, "the glyph says the clip plays")
    }

    @Test func aToggleDuringTheModeWins() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        screen.editor.debugTapMedia()
        #expect(screen.preview.pauses.last == true, "guard: the toggle did not stop the clip")

        tools.transitions.debugTapClose()

        #expect(screen.preview.pauses.last == true, "closing the row undid the author's toggle")
    }

    // MARK: - Closing

    @Test func closingClearsTheLoop() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        let loads = screen.preview.plans.count
        tools.transitions.debugTap(.dipToBlack)
        try await landed(screen, beyond: loads)

        tools.transitions.debugTapClose()
        screen.window.layoutIfNeeded()

        #expect(screen.preview.loops.last == .some(nil), "the loop outlived the row: \(screen.preview.loops)")
        #expect(screen.editor.debugTransitionSeam == nil && !tools.transitions.isOpen && !tools.track.isCompact)
        #expect(tools.track.debugSeamMarks.map(\.glyph) == ["moon.fill"], "the cut shows \(tools.track.debugSeamMarks)")
    }

    @Test func leavingTheTimelineClosesTheRow() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)

        choose(Mode.filters, on: screen)

        #expect(screen.editor.debugTransitionSeam == nil, "the row is still open")
        #expect(!tools.transitions.isOpen && !tools.track.isCompact)
        #expect(screen.preview.loops.last == .some(nil), "the stretch is still looping")
    }

    @Test func aSwipeToAnotherClipClosesTheRow() async throws {
        let (screen, tools) = try await cutClip(2)
        tools.track.debugTapSeam(0)

        screen.editor.debugScrollToPage(1)
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugTransitionSeam == nil, "the row followed the swipe")
        #expect(!tools.track.isCompact)
        #expect(screen.preview.loops.last == .some(nil), "the old clip is still looping")
    }

    @Test func retargetingTheTrackClosesTheRow() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)

        screen.editor.scrollViewDidEndDecelerating(UIScrollView())

        #expect(screen.editor.debugTransitionSeam == nil, "a re-target left the row open")
        #expect(!tools.track.isCompact)
    }

    /// ⚠️ **LEAVING THE SCREEN STOPS THE LOOP WITH THE CLIP.**
    @Test func leavingTheScreenClosesTheRow() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)

        screen.editor.beginAppearanceTransition(false, animated: false)
        screen.editor.endAppearanceTransition()

        #expect(screen.editor.debugTransitionSeam == nil, "the row outlived the screen")
        #expect(!tools.track.isCompact)
    }

    /// ⚠️ **A MOVE OF THE COLLAPSED LINE SEEKS NOTHING.** Two guards stand in
    /// the way — the track does not report it as a scrub, and the screen does
    /// not act on one while the row is open — and either alone is enough.
    @Test func aMoveOfTheLineSeeksNothing() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        // The collapse's own ease holds scrubs back while it runs; the move
        // below has to come after it.
        try await settle(until: { !tools.track.debugIsEasing })
        try #require(!tools.track.debugIsEasing)
        let seeks = screen.preview.seeks.count

        tools.track.debugScroll(toContentOffset: 100)

        #expect(screen.preview.seeks.count == seeks, "the loop was pulled to \(screen.preview.seeks.suffix(1))")
    }

    /// ⚠️ **THE RANGE IS ASKED WHEN THE ITEM GOES IN.** A load the row asked for
    /// that lands after it closed loops nothing.
    @Test func aLoadThatLandsAfterTheRowClosedCarriesNoRange() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        let loads = screen.preview.plans.count

        tools.transitions.debugTap(.zoom)
        tools.transitions.debugTapClose()
        try await landed(screen, beyond: loads)

        #expect(screen.preview.landings.last?.loop == nil,
                "a closed row's load looped \(String(describing: screen.preview.landings.last))")
        #expect(screen.editor.debugPreviewLoop == nil)
    }

    // MARK: - Guards

    @Test func theResetArrowWaitsForTheRowToClose() async throws {
        let (screen, tools) = try await cutClip()
        #expect(screen.editor.debugCropResetItem.isEnabled, "guard: a cut clip cannot be reset")

        tools.track.debugTapSeam(0)
        #expect(!screen.editor.debugCropResetItem.isEnabled, "the arrow could undo the cut the row is on")

        tools.transitions.debugTapClose()
        #expect(screen.editor.debugCropResetItem.isEnabled)
    }

    /// ⚠️ **NOT BEFORE THE FILE'S REAL LENGTH IS KNOWN** — the stretch is
    /// measured against it.
    @Test func theModeWaitsForTheRealLength() async throws {
        let screen = open(Self.videos(1))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        let track = tools.track
        track.debugScroll(
            toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 5, trackWidth: track.bounds.width,
                pointsPerSecond: track.debugPointsPerSecond
            )
        )
        screen.editor.debugSplitAtTheNeedle()
        track.select(nil, notify: false)
        screen.window.layoutIfNeeded()
        try #require(track.debugSeamMarks.map(\.index) == [0], "guard: marks \(track.debugSeamMarks)")

        track.debugTapSeam(0)
        #expect(screen.editor.debugTransitionSeam == nil, "the row opened on a declared length")

        try await landed(screen, beyond: 0)
        track.debugTapSeam(0)
        #expect(screen.editor.debugTransitionSeam == 0)
    }

    /// ⚠️ **THE COLLAPSED LINE FOLLOWS THE LOOP** — which it can only do while
    /// the track shows the arrangement the item plays.
    @Test func theTrackShowsWhatThePlayerPlays() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.debugTapSeam(0)
        let loads = screen.preview.plans.count
        tools.transitions.debugTap(.dipToBlack)
        try await landed(screen, beyond: loads)
        let range = try #require(screen.preview.landings.last?.loop)
        // The collapse's own ease, then the one that takes the line to the new
        // stretch: a beat that lands during an ease is ignored, by design.
        try await settle(until: { !tools.track.debugIsEasing })
        screen.preview.headSeconds = range.lowerBound
        screen.editor.debugFollowTick()
        try await settle(until: { !tools.track.debugIsEasing })
        try #require(!tools.track.debugIsEasing, "guard: the line never stopped easing")

        screen.preview.headSeconds = range.lowerBound + 0.05
        screen.editor.debugFollowTick()

        #expect(abs(tools.track.playedSecondsUnderNeedle - (range.lowerBound + 0.05)) < 0.01,
                "the line stayed at \(tools.track.playedSecondsUnderNeedle)s")
    }
}
