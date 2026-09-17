import DesignSystem
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **CHOOSING A PIECE'S FILTER, THROUGH THE SCREEN.**
///
/// Asked for in these words: *"dans la toolbar de gauche avoir une icône
/// filtre (à côté de l'icône des ciseaux et de la vitesse), qui sera active que
/// lorsqu'un segment sera sélectionné dans la timeline, et le clic sur ce bouton
/// activera le mode compact de la timeline et affichera en dessous une
/// scrollview horizontale avec les filtres disponibles (exactement comme on a
/// fait avec l'affichage des transitions disponibles)"*.
///
/// The harness is `MediaEditorTransitionsTests`'; the arithmetic is
/// `MediaSegmentFilterModelTests`'.
@MainActor
struct MediaEditorSegmentFiltersTests {
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

    private typealias Action = MediaEditorViewController.TrackAction

    private func filterAction(_ screen: Screen) -> Bool {
        screen.editor.debugActionBar.isEnabled(at: Action.filter.rawValue)
    }

    // MARK: - The action

    /// ⚠️ **ONLY WHILE A PIECE IS HELD.**
    @Test func theActionWaitsForAHeldPiece() async throws {
        let (screen, tools) = try await cutClip()
        // The harness puts the cut's held half down without telling the screen.
        tools.track.select(0)
        tools.track.select(nil, notify: true)
        #expect(!filterAction(screen), "the action is live with nothing held")

        tools.track.select(1)
        screen.window.layoutIfNeeded()

        #expect(filterAction(screen), "holding a piece did not wake the action")
        tools.track.select(nil, notify: true)
        #expect(!filterAction(screen), "putting it down left the action live")
    }

    // MARK: - Opening

    @Test func theActionOpensTheRowOnTheHeldPieceWithoutMovingThePicture() async throws {
        let (screen, tools) = try await cutClip()
        let band = screen.editor.debugBand.frame.height
        let dots = screen.editor.debugPageDotsTop
        tools.track.select(1)

        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        screen.window.layoutIfNeeded()

        #expect(tools.editingPiece == 1, "the row is open on \(String(describing: tools.editingPiece))")
        #expect(tools.segmentFilters.isOpen && tools.track.isCompact)
        #expect(!tools.transitions.isOpen)
        #expect(screen.editor.debugBand.frame.height == band && screen.editor.debugPageDotsTop == dots,
                "the picture moved")
        #expect(filterAction(screen), "the action cannot close what it opened")

        // Nothing else may move the piece the row is open on.
        let timeline = tools.track.debugTimeline
        screen.editor.debugActionBar.debugTap(Action.split.rawValue)
        screen.editor.debugActionBar.debugTap(Action.speed.rawValue)
        #expect(tools.track.debugTimeline == timeline && !tools.isOfferingSpeeds,
                "an action reached the clip while the row was open")
    }

    @Test func openingLoopsThePiece() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.select(1)

        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)

        let expected = try #require(MediaTimelining.rehearsal(
            ofPiece: 1, in: tools.track.debugTimeline, withinSource: 10
        ))
        #expect(screen.preview.loops.last == expected, "the preview loops \(screen.preview.loops)")
        #expect(screen.preview.pauses.last == false, "the piece is not playing")
        #expect(tools.track.debugRehearsalFrame != nil, "nothing is lit")
    }

    // MARK: - Choosing

    @Test func aChoiceIsStoredOnThatPieceAndPlayed() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.select(0)
        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        let loads = screen.preview.plans.count

        tools.segmentFilters.debugTap(.noir)
        try await landed(screen, beyond: loads)

        let stored = MediaTimelining.resolved(tools.track.debugTimeline, withinSource: 10)
        #expect(stored.map(\.filter) == [.noir, nil], "stored \(stored.map(\.filter))")
        #expect(screen.preview.plans.last?.segments.map(\.look) == [.noir, nil],
                "the preview plays \(String(describing: screen.preview.plans.last?.segments.map(\.look)))")
        #expect(tools.segmentFilters.debugChosen == ["Noir"])
        let expected = try #require(MediaTimelining.rehearsal(
            ofPiece: 0, in: tools.track.debugTimeline, withinSource: 10
        ))
        #expect(screen.preview.landings.last?.loop == expected, "the new item does not loop the piece")

        // None takes it away.
        let again = screen.preview.plans.count
        tools.segmentFilters.debugTap(nil)
        try await landed(screen, beyond: again)
        #expect(MediaTimelining.resolved(tools.track.debugTimeline, withinSource: 10).map(\.filter) == [nil, nil])
    }

    /// An untouched clip is one piece; its filter still reaches the preview.
    @Test func anUncutClipTakesAFilter() async throws {
        let screen = open(Self.videos(1))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        try await landed(screen, beyond: 0)
        tools.track.select(0)
        screen.window.layoutIfNeeded()
        try #require(filterAction(screen), "guard: the action is not live on an uncut clip")
        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        let loads = screen.preview.plans.count

        tools.segmentFilters.debugTap(.mono)
        try await landed(screen, beyond: loads)

        #expect(screen.preview.plans.last?.segments.map(\.look) == [.mono])
    }

    // MARK: - Closing

    @Test func closingGivesTheFilmAndThePauseBack() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.select(1)
        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        try #require(tools.segmentFilters.isOpen)

        tools.segmentFilters.debugTapClose()
        screen.window.layoutIfNeeded()

        #expect(tools.editingPiece == nil && !tools.segmentFilters.isOpen && !tools.track.isCompact)
        #expect(screen.preview.loops.last == Optional<ClosedRange<Double>>.none, "the loop stayed")
        #expect(screen.editor.debugActionBar.activeItem == nil, "the action stayed lit")
    }

    @Test func theActionClosesTheRowItOpened() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.select(1)
        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        try #require(tools.segmentFilters.isOpen)

        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        screen.window.layoutIfNeeded()

        #expect(!tools.segmentFilters.isOpen && !tools.track.isCompact)
    }

    /// ⚠️ **EVERY WAY OFF THE CLIP PUTS IT AWAY** — the transitions row's rule.
    @Test func leavingTheTimelineClosesTheRow() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.select(1)
        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        try #require(tools.segmentFilters.isOpen)

        choose(Mode.filters, on: screen)

        #expect(!tools.segmentFilters.isOpen && tools.editingPiece == nil)
    }

    /// ⚠️ **NEVER BOTH ROWS.**
    @Test func aCutsPlusDoesNothingWhileThePieceRowIsOpen() async throws {
        let (screen, tools) = try await cutClip()
        tools.track.select(1)
        screen.editor.debugActionBar.debugTap(Action.filter.rawValue)
        try #require(tools.segmentFilters.isOpen)

        tools.track.onSeam?(0)

        #expect(!tools.transitions.isOpen, "both rows are open")
        #expect(screen.editor.debugTransitionSeam == nil)
        #expect(screen.editor.debugActionBar.activeItem == Action.filter.rawValue,
                "the refused + put the filter action out")
    }
}
