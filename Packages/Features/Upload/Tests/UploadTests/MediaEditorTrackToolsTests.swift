import DesignSystem
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE SECOND BAR: WHAT IT REPLACES, WHAT IT CUTS, AND WHAT A RATE REACHES.**
///
/// Charter F18, asked for in these words: with the mode on, the bottom-left
/// "Add a song" is replaced by a second bar carrying split and speed.
///
/// The arithmetic of a split and of a rate is asked in `MediaTimeliningTests` —
/// what this suite is for is the wiring: that the tap reaches the stored
/// timeline, that the button says when it cannot act, that the rate lands on the
/// piece under the needle and NOT on the whole clip, and that the preview obeys
/// it. Every one of those is a place a control can look alive and reach nothing,
/// which is the defect this screen has removed three times.
@MainActor
struct MediaEditorTrackToolsTests {
    private enum Mode {
        static let trim = 5
        static let filters = 3
    }

    private struct Screen {
        let editor: MediaEditorViewController
        let window: UIWindow
        let navigation: UINavigationController
        let preview: StubPreview
        let handed: Handed
    }

    @MainActor
    private final class Handed {
        var edits: [String: MediaEdits]?
        let destination = UIViewController()
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
        /// Every arrangement the screen asked to be played, and where each was
        /// asked to begin.
        private(set) var plans: [VideoExportPlan] = []
        private(set) var starts: [Double] = []
        /// Where each accepted load landed, and what it looped.
        private(set) var landings: [VideoLoadLanding] = []
        func load(
            _ plan: VideoExportPlan, in surface: VideoRenderView,
            landing: @escaping @MainActor () -> VideoLoadLanding?
        ) async {
            guard let landed = landing() else { return }
            plans.append(plan)
            starts.append(landed.seconds)
            landings.append(landed)
        }
        private(set) var shownAsShot: [Double] = []
        /// Every loop range the screen asked for, in order.
        private(set) var loops: [ClosedRange<Double>?] = []
        func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {
            loops.append(range)
        }

        func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {
            shownAsShot.append(seconds)
        }
        func stop(_ surface: VideoRenderView) {}
        var paused: Bool? = false
        func isPaused(in surface: VideoRenderView) -> Bool? { paused }
        func isBound(_ surface: VideoRenderView) -> Bool { false }
        /// Every pause and resume, in order.
        private(set) var pauses: [Bool] = []
        func setPaused(_ paused: Bool, in surface: VideoRenderView) { pauses.append(paused) }

        var headSeconds: Double?
        func playheadSeconds(in surface: VideoRenderView) -> Double? { headSeconds }
        private(set) var seeks: [Double] = []
        func seek(toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double) {
            seeks.append(seconds)
        }

        private(set) var askedFrames = false
        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] {
            askedFrames = true
            return [:]
        }
    }

    private static func items(_ count: Int, videosAt videoIndexes: Set<Int> = []) -> [MediaLibraryItem] {
        (0..<count).map { index in
            let isVideo = videoIndexes.contains(index)
            return MediaLibraryItem(
                id: isVideo ? "video-\(index)" : "photo-\(index)",
                kind: isVideo ? .video(duration: 10) : .photo
            )
        }
    }

    private func open(_ items: [MediaLibraryItem]) -> Screen {
        let handed = Handed()
        let preview = StubPreview()
        let editor = MediaEditorViewController(
            items: items, library: StubLibrary(), preview: preview
        ) { _, edits in
            handed.edits = edits
            return handed.destination
        }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        editor.beginAppearanceTransition(true, animated: false)
        editor.endAppearanceTransition()
        window.layoutIfNeeded()
        return Screen(
            editor: editor, window: window, navigation: navigation, preview: preview, handed: handed
        )
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

    /// Waits for a load newer than the `count` already seen to land.
    ///
    /// ⚠️ `settle` returns quietly when it runs out of time; the `#require`s are
    /// what make a load that never came a failure.
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

    /// Puts the needle on a moment of the FILE, the way a scroll does.
    ///
    /// ⚠️ **THROUGH THE TIMELINE, NOT BY MULTIPLYING.** A moment of the file is
    /// drawn at the rate of the stretch it falls in, so the offset that brings it
    /// under the needle is a question only the timeline can answer.
    private func putTheNeedle(
        at seconds: Double, on track: MediaTimelineTrackView, in screen: Screen
    ) {
        track.debugScroll(
            toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: seconds, trackWidth: track.bounds.width,
                pointsPerSecond: track.debugPointsPerSecond
            )
        )
        screen.window.layoutIfNeeded()
    }

    private func hostedToolbarViews(_ screen: Screen) -> [UIView] {
        (screen.editor.toolbarItems ?? []).compactMap(\.customView)
    }

    // MARK: - Whose slot it is

    /// ⚠️ **THE PILL HAS NOWHERE TO GO AND THE ACTIONS DO.** "Add a song" is
    /// drawn against no audio seam of any kind — there is no track model, no
    /// picker, no mock — so while the timeline is open the slot belongs to the
    /// two things that change what gets published.
    @Test func openingTheTimelinePutsTheActionsWhereTheSongPillWas() {
        let screen = open(Self.items(1, videosAt: [0]))

        choose(Mode.trim, on: screen)

        let hosted = hostedToolbarViews(screen)
        #expect(hosted.first is IconActionBar, "the leading slot: \(hosted)")
        #expect(hosted.contains { $0 is SoundPillView } == false, "the pill stood aside")
        #expect(hosted.last is IconSelectorBar, "and the modes keep their end")
    }

    @Test func leavingTheTimelineGivesThePillItsSlotBack() {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        #expect(hostedToolbarViews(screen).first is IconActionBar, "guard: the actions are up")

        choose(Mode.filters, on: screen)

        let hosted = hostedToolbarViews(screen)
        #expect(hosted.first is SoundPillView, "got \(hosted)")
        #expect(hosted.contains { $0 is IconActionBar } == false)
    }

    /// A photograph gets the notice, not the track — and so it must not get the
    /// actions either: there is nothing for them to cut.
    @Test func aPhotographNeverSeesTheActions() {
        let screen = open(Self.items(1))

        choose(Mode.trim, on: screen)

        #expect(hostedToolbarViews(screen).first is SoundPillView)
    }

    @Test func theActionBarDrawsNoBubbleInsideTheToolbarsOwn() {
        let screen = open(Self.items(1, videosAt: [0]))

        choose(Mode.trim, on: screen)

        #expect(screen.editor.debugActionBar.suppressesBackdrop)
    }

    /// ⚠️ **A SYMBOL THAT DOES NOT RESOLVE IS AN EMPTY BUTTON, NOT AN ERROR** —
    /// this repository has shipped one. The runtime is the instrument that cannot
    /// be wrong.
    @Test func bothActionGlyphsExist() {
        for action in MediaEditorViewController.TrackAction.allCases {
            #expect(UIImage(systemName: action.symbolName) != nil,
                    "\(action.symbolName) draws a blank capsule that still takes taps")
        }
    }

    // MARK: - The two strips share the bar

    /// ⚠️ **THE RULE EXISTED AND NOTHING APPLIED IT.** `EditorSelectorLayout` was
    /// written for the day a second strip arrived and said so in its own comment.
    /// This is that day: without it, two intrinsic widths and a flexible space
    /// let Auto Layout squeeze whichever one it prefers.
    @Test func theTwoStripsAreHeldToTheirShareOfTheBar() throws {
        let screen = open(Self.items(1, videosAt: [0]))

        choose(Mode.trim, on: screen)
        screen.window.layoutIfNeeded()

        let bar = try #require(screen.navigation.toolbar.bounds.width > 0 ? screen.navigation.toolbar : nil)
        let held = try #require(screen.editor.debugStripWidths, "the rule is not being applied")
        let ceiling = bar.bounds.width * EditorSelectorLayout.ceiling
        #expect(held.leading > 0 && held.trailing > 0)
        #expect(held.leading <= ceiling && held.trailing <= ceiling,
                "one strip took more than its ceiling: \(held) of \(bar.bounds.width)")
        #expect(held.leading + held.trailing <= bar.bounds.width,
                "together they overflow the bar: \(held)")
        // Two icons cannot scroll their overflow away; six modes can, which is
        // why the actions are the ones that keep their width.
        #expect(held.leading == screen.editor.debugActionBar.intrinsicContentSize.width,
                "the actions were squeezed: \(held.leading)")
    }

    @Test func thePillsArrangementIsLeftAloneWhenItIsTheOneInTheSlot() {
        let screen = open(Self.items(1, videosAt: [0]))

        choose(Mode.filters, on: screen)
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugStripWidths == nil,
                "the rule is for two strips; the pill has its own floor")
    }

    // MARK: - Splitting

    /// ⚠️ **AT THE NEEDLE, AND THE NEEDLE IS WHERE THE FILM WAS SCROLLED TO.**
    @Test func theScissorsCutThePieceUnderTheNeedleInTwo() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )

        let pieces = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(pieces.count == 2, "got \(pieces)")
        #expect(abs((pieces.first?.end ?? 0) - 5) < 0.2, "cut somewhere else: \(pieces)")
        #expect(abs((pieces.last?.start ?? 0) - 5) < 0.2)
    }

    /// ⚠️ **THE STORE, NOT THE VIEW.** A track showing two pieces while `edits`
    /// still holds one publishes the whole clip — which is the shape of the
    /// defect that made `keptPieces` a list in the first place.
    @Test func theCutIsStoredAgainstTheClipAndTravelsOnward() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.editor.debugTapNext()

        let carried = try #require(screen.handed.edits?["video-0"]?.timeline)
        #expect(MediaTimelining.resolved(carried, withinSource: 10).count == 2, "got \(carried)")
    }

    /// ⚠️ **THE WHOLE REASON THE BAR IS NOT A SELECTOR.** A selector announces
    /// only when its index changes, so the second tap on the scissors would be
    /// silent and a clip could be cut exactly once.
    @Test func aSecondTapCutsAgainSomewhereElse() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        let split = MediaEditorViewController.TrackAction.split.rawValue

        putTheNeedle(at: 3, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(split)
        putTheNeedle(at: 7, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(split)

        #expect(MediaTimelining.resolved(track.debugTimeline, withinSource: 10).count == 3,
                "got \(track.debugTimeline)")
    }

    /// ⚠️ **A CONTROL THAT CANNOT ACT SAYS SO.** `split` refuses a cut that would
    /// leave either half under the floor and returns the timeline unchanged; a
    /// button that stays lit for that tap is a dead control wearing a live one's
    /// clothes.
    @Test func theScissorsAreDeadAtTheVeryStartOfTheClip() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track

        putTheNeedle(at: 0, on: track, in: screen)

        #expect(
            screen.editor.debugActionBar.isEnabled(
                at: MediaEditorViewController.TrackAction.split.rawValue
            ) == false,
            "half a second of film is not a piece"
        )
    }

    @Test func theScissorsComeAliveWhereThereIsSomethingOnBothSides() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track

        putTheNeedle(at: 5, on: track, in: screen)

        #expect(screen.editor.debugActionBar.isEnabled(
            at: MediaEditorViewController.TrackAction.split.rawValue
        ))
    }

    /// ⚠️ **A SPLIT THAT CANNOT BE SEEN IS A SPLIT NOBODY CAN AIM — AND WHAT
    /// SHOWS IT IS DAYLIGHT, NOT A WHITE BAR.** Asked for in those words: *"plutôt
    /// séparer les segments avec un léger espace et arrondir les bords"*. The
    /// outer selection does not move when a clip is cut in two — both halves are
    /// kept — so the two rounded ends and the gap between them are the only
    /// evidence on screen that the tap did anything.
    @Test func aCutPartsTheFilmWithDaylight() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        #expect(track.debugSeamGaps.isEmpty, "guard: an uncut clip has no seams")

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        let seam = try #require(track.debugPieceFrames.first?.upperBound)
        let half = MediaTimelineTrackView.debugSeamGap / 2
        // ⚠️ **A NUMBER THE EYE CAN SEE, WRITTEN DOWN.** Every other width here
        // is read off the same constant the track draws with — measured: set it
        // to zero and they all agreed with each other, and nothing went red.
        #expect(half >= 0.5, "a cut leaves \(half * 2)pt of daylight, which nobody can see")

        // The left half is held after a cut: it keeps all its film, and the
        // daylight its neighbour gives up sits under its closing cap.
        let heldWindows = track.debugFilmWindows
        try #require(heldWindows.count == 2, "got \(heldWindows.map(\.frame))")
        #expect(abs(heldWindows[0].frame.maxX - seam) < 0.01,
                "the held half was carved: it ends at \(heldWindows[0].frame.maxX), the cut is \(seam)")
        #expect(abs(heldWindows[1].frame.minX - (seam + half)) < 0.01,
                "the other half starts at \(heldWindows[1].frame.minX), not half a daylight past \(seam)")
        #expect(track.debugEndGrip.minX <= seam + 0.01 && track.debugEndGrip.maxX >= seam + half,
                "the daylight is not under the closing cap: \(track.debugEndGrip)")

        // Put down, the cut is two rounded ends and the daylight between them.
        track.debugTap(atContentX: 100_000)
        screen.window.layoutIfNeeded()
        let gaps = track.debugSeamGaps
        try #require(gaps.count == 1, "got \(gaps)")
        #expect(abs((gaps[0].to - gaps[0].from) - MediaTimelineTrackView.debugSeamGap) < 0.01,
                "the daylight is \(gaps[0].to - gaps[0].from)pt")
        #expect(abs((gaps[0].from + gaps[0].to) / 2 - seam) < 0.01,
                "the daylight is not centred on the cut: \(gaps[0]) against \(seam)")
        let at5 = MediaTimelining.x(
            atPlayedSeconds: MediaTimelining.playedSeconds(
                atSourceSeconds: 5, in: track.debugTimeline, withinSource: 10
            ),
            pointsPerSecond: track.debugPointsPerSecond
        )
        #expect(abs(seam - at5) < 2, "the cut is not at five seconds: \(seam) vs \(at5)")
        #expect(abs(track.debugContentWidth - 600) < 0.01,
                "the daylight entered the clock: \(track.debugContentWidth)")
        let open = Dictionary(uniqueKeysWithValues: track.debugFilmWindows.map { ($0.piece, $0.frame) })
        for tile in track.debugTiles {
            let window = try #require(open[tile.place.piece], "a square with no window")
            #expect(tile.frame.minX >= window.minX - 0.01 && tile.frame.maxX <= window.maxX + 0.01,
                    "a square at \(tile.frame) stands outside its window \(window)")
        }
    }

    // MARK: - Speed

    @Test func theSpeedometerOpensTheRatesAndLightsItself() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        #expect(tools.isOfferingSpeeds == false, "guard: they start shut")

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        screen.window.layoutIfNeeded()

        #expect(tools.isOfferingSpeeds)
        #expect(screen.editor.debugActionBar.activeItem
                == MediaEditorViewController.TrackAction.speed.rawValue)
        #expect(tools.speeds.debugTitles == MediaTimelining.rates.map(MediaTimelining.rateLabel))
    }

    @Test func tappingItAgainShutsThem() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        let speed = MediaEditorViewController.TrackAction.speed.rawValue

        screen.editor.debugActionBar.debugTap(speed)
        screen.editor.debugActionBar.debugTap(speed)
        screen.window.layoutIfNeeded()

        #expect(tools.isOfferingSpeeds == false)
        #expect(screen.editor.debugActionBar.activeItem == nil)
    }

    /// ⚠️ **AND THEY LEAVE WITH THE MODE.** A lit speedometer and an open row
    /// that came back next time saying "open" over a band holding something else
    /// is the state this screen's crop mode has already been caught leaving
    /// behind.
    @Test func leavingTheModeShutsTheRates() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        #expect(tools.isOfferingSpeeds, "guard: they are open")

        choose(Mode.filters, on: screen)

        #expect(tools.isOfferingSpeeds == false)
        #expect(screen.editor.debugActionBar.activeItem == nil)
    }

    @Test func choosingARateStoresItAgainstTheClip() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        putTheNeedle(at: 5, on: tools.track, in: screen)

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)

        #expect(MediaTimelining.rate(at: 5, in: tools.track.debugTimeline, withinSource: 10) == 2)
        #expect(tools.speeds.debugChosen == "2×")
    }

    /// ⚠️ **THE PIECE UNDER THE NEEDLE, NOT THE WHOLE CLIP** — otherwise the
    /// split is pointless, because cutting a clip in two exists so that one half
    /// can run at a different speed from the other.
    @Test func aRateLandsOnOnePieceAndLeavesItsNeighbourAsShot() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        putTheNeedle(at: 5, on: tools.track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )

        // ⚠️ **THE CHIPS ACT ON THE SECTION THAT IS HELD** — `targetPiece` takes
        // the held piece first and the needle only when nothing is held. Since a
        // cut hands back the LEFT half held, taking the right half is a tap, and
        // the frame on screen says which one the next rate will land on.
        screen.window.layoutIfNeeded()
        tools.track.debugTap(atContentX: tools.track.debugPieceFrames[1].lowerBound + 20)
        putTheNeedle(at: 7, on: tools.track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 4)

        let pieces = MediaTimelining.resolved(tools.track.debugTimeline, withinSource: 10)
        #expect(pieces.count == 2, "guard: still two pieces")
        #expect(pieces.first?.speed == 1, "the first half was changed too: \(pieces)")
        #expect(pieces.last?.speed == 4, "got \(pieces)")
    }

    /// ⚠️ **THE PREVIEW HAS TO OBEY, OR THE CHIP IS A PROMISE ABOUT A FILE NOBODY
    /// HAS SEEN.** Without this the only evidence of a rate is the total in the
    /// corner getting shorter. The rate is built into the item, so a new rate is
    /// a new arrangement — and it lands on the frame the author was watching,
    /// which at twice the speed is half as far into the result.
    @Test func thePreviewIsRebuiltAtTheRateThatWasChosen() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        try await landed(screen, beyond: 0)
        putTheNeedle(at: 5, on: tools.track, in: screen)
        let loads = screen.preview.plans.count

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)
        try await landed(screen, beyond: loads)

        let plan = try #require(screen.preview.plans.last)
        #expect(plan.segments.map(\.speed) == [2], "the item was built at \(plan.segments.map(\.speed))")
        let start = try #require(screen.preview.starts.last)
        #expect(abs(start - 2.5) < 0.05, "it landed at \(start)s, not on the frame under the needle")
    }

    /// ⚠️ **ONLY THE NEWEST EDIT REACHES THE PREVIEW.** Two rates chosen in quick
    /// succession start two loads; the first to land would put the older rate
    /// on the canvas, and if it landed last it would stay there under a chip
    /// that says otherwise.
    @Test func onlyTheNewestEditReachesThePreview() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        try await landed(screen, beyond: 0)
        putTheNeedle(at: 5, on: tools.track, in: screen)
        let loads = screen.preview.plans.count

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)
        tools.speeds.debugTap(rate: 4)
        try await landed(screen, beyond: loads)
        try await Task.sleep(for: .milliseconds(100))

        #expect(screen.preview.plans.count == loads + 1,
                "\(screen.preview.plans.count - loads) arrangements reached the preview")
        #expect(screen.preview.plans.last?.segments.map(\.speed) == [4],
                "the preview plays \(screen.preview.plans.map { $0.segments.map(\.speed) })")
    }

    /// ⚠️ **A CUT IS NOT A NEW ITEM.** Splitting leaves the same film on the same
    /// clock, so rebuilding the item would cost the author a stall for nothing;
    /// what changes is the screen's record of what the item plays — and without
    /// that the very next scroll is refused as aimed at a different film.
    @Test func aCutKeepsTheItemThePreviewIsPlaying() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await landed(screen, beyond: 0)
        let loads = screen.preview.plans.count

        let track = try splitInTwo(on: screen)

        #expect(screen.editor.debugPreviewIsPending == false, "the cut asked for a new item")
        putTheNeedle(at: 7, on: track, in: screen)
        let asked = try #require(screen.preview.seeks.last, "a scroll after the cut reached nothing")
        #expect(abs(asked - 7) < 0.1, "the scroll after the cut asked for \(asked)s")
        try await Task.sleep(for: .milliseconds(100))
        #expect(screen.preview.plans.count == loads,
                "the cut rebuilt the item \(screen.preview.plans.count - loads) times")
    }

    /// ⚠️ **A HELD EDGE SHOWS THE FILE AS SHOT; ITS RELEASE LOADS THE CUT.** A
    /// handle that opens a piece stands on film the arrangement does not
    /// contain, so no seek inside it can show the edge — the file goes on the
    /// canvas once, the drag seeks it, and the release brings the arrangement
    /// back. Until that lands the clip stays stopped: run at once, it would play
    /// raw film for the moment the build takes.
    @Test func aHeldEdgeShowsTheFileAndItsReleaseLoadsTheCut() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await landed(screen, beyond: 0)
        let track = try splitInTwo(on: screen)
        #expect(track.debugSelectedPiece == 0, "guard: the left half is held")
        let centres = try #require(track.debugHandleCentres)
        let loads = screen.preview.plans.count

        // The first section's closing pince, a second to the left.
        track.debugTakeHold(at: centres.end)
        track.debugDrag(byPoints: -track.debugPointsPerSecond)
        #expect(screen.preview.shownAsShot.count == 1,
                "the file was shown \(screen.preview.shownAsShot.count) times")
        #expect(abs((screen.preview.shownAsShot.last ?? -1) - 4) < 0.1,
                "the file was shown at \(screen.preview.shownAsShot), not at the edge")
        #expect(screen.editor.debugPreviewIsAiming, "guard: the screen knows the file is up")

        track.debugDrag(byPoints: -track.debugPointsPerSecond)
        #expect(screen.preview.shownAsShot.count == 1, "the file was swapped in again mid-drag")
        let aimed = try #require(screen.preview.seeks.last, "the second sample reached nothing")
        #expect(abs(aimed - 3) < 0.1, "the second sample seeked the file to \(aimed)s")

        // ⚠️ **THE FILE'S CLOCK IS NOT THE TRACK'S — ASKED WITH THE EDGE BACK
        // WHERE IT STARTED.** Mid-drag the track shows an arrangement the item
        // does not play, and that alone stops the follower; only with the edge
        // home again does the file on the canvas become the one thing the
        // follower has to be told about.
        // ⚠️ **TWO GUARDS, AND EITHER ONE IS ENOUGH.** The track refuses to follow
        // while a grip is held, and the screen refuses a clock that belongs to
        // the file. Measured by deliberate break: removing either alone leaves
        // this green; removing both turns it red.
        track.debugDrag(byPoints: 2 * track.debugPointsPerSecond)
        try #require(screen.editor.debugPreviewTimeline == track.debugTimeline,
                     "guard: the edge is not back where it started")
        let needle = track.playedSecondsUnderNeedle
        screen.preview.headSeconds = 9
        screen.editor.debugFollowTick()
        #expect(abs(track.playedSecondsUnderNeedle - needle) < 0.01,
                "the film followed the file: \(needle)s to \(track.playedSecondsUnderNeedle)s")
        track.debugDrag(byPoints: -2 * track.debugPointsPerSecond)

        track.debugRelease()
        #expect(screen.preview.pauses.last == true,
                "the clip ran on the file as shot: \(screen.preview.pauses.suffix(2))")
        try await landed(screen, beyond: loads)

        let plan = try #require(screen.preview.plans.last)
        let kept = plan.segments.map { [($0.start * 10).rounded() / 10, ($0.end * 10).rounded() / 10] }
        #expect(kept == [[0, 3], [5, 10]], "the item plays \(kept)")
        #expect(screen.editor.debugPreviewIsAiming == false, "the file is still on the canvas")
        #expect(screen.preview.pauses.last == false, "the landing left the clip stopped")
    }

    /// ⚠️ **A CARRIED ORDER IS WHAT THE PREVIEW PLAYS, AS ONE ITEM** — which is
    /// the reported "mini pause/glitch" between re-ordered clips: the preview ran
    /// the file and jumped across it at every seam. The new order reaches the
    /// player as one arrangement, landing under the needle.
    @Test func aCarriedOrderIsWhatThePreviewPlays() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await landed(screen, beyond: 0)
        let track = try splitInTwo(on: screen)
        let loads = screen.preview.plans.count

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        try #require(track.debugCarrying == 0, "nothing was lifted")
        screen.window.layoutIfNeeded()
        try #require(track.debugShotFrames.count == 2, "guard: the list is up")
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.debugDrop()
        screen.window.layoutIfNeeded()
        try await landed(screen, beyond: loads)

        let plan = try #require(screen.preview.plans.last)
        let order = plan.segments.map { [($0.start * 10).rounded() / 10, ($0.end * 10).rounded() / 10] }
        #expect(order == [[5, 10], [0, 5]], "the item plays \(order)")
        let start = try #require(screen.preview.starts.last)
        #expect(abs(start - track.playedSecondsUnderNeedle) < 0.01,
                "it landed at \(start)s with the needle at \(track.playedSecondsUnderNeedle)s")
        #expect(screen.preview.pauses.last == false, "the landing left the clip stopped")
    }

    /// ⚠️ **NOTHING LOOPS A STRETCH UNTIL A TRANSITION IS BEING CHOSEN.** Every
    /// other way in — opening, a carry, a released handle, a rate — plays the
    /// whole arrangement, and asks the landing exactly once per load.
    @Test func everyLoadOutsideTheModeLandsWithoutARange() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        try await landed(screen, beyond: 0)
        let track = try splitInTwo(on: screen)

        var loads = screen.preview.plans.count
        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        try #require(track.debugCarrying == 0, "nothing was lifted")
        screen.window.layoutIfNeeded()
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.debugDrop()
        screen.window.layoutIfNeeded()
        try await landed(screen, beyond: loads)

        loads = screen.preview.plans.count
        track.select(1)
        screen.window.layoutIfNeeded()
        let centres = try #require(track.debugHandleCentres)
        track.debugTakeHold(at: centres.end)
        track.debugDrag(byPoints: -track.debugPointsPerSecond)
        track.debugRelease()
        try await landed(screen, beyond: loads)

        loads = screen.preview.plans.count
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)
        try await landed(screen, beyond: loads)

        let landings = screen.preview.landings
        #expect(landings.count == screen.preview.plans.count,
                "\(landings.count) landings for \(screen.preview.plans.count) loads")
        #expect(landings.count >= 4, "guard: only \(landings.count) loads happened")
        #expect(landings.allSatisfy { $0.loop == nil }, "a load looped a stretch: \(landings)")
        #expect(screen.preview.loops.isEmpty, "a range was set: \(screen.preview.loops)")
    }

    /// The stamp is the other half of "you can see what you did": a rate changes
    /// the readout's total, which says SOMETHING happened but not to which piece.
    @Test func aPieceThatIsNotAsShotIsStamped() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        putTheNeedle(at: 5, on: tools.track, in: screen)
        #expect(tools.track.debugRateStamps.isEmpty, "guard: as shot, nothing to say")

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)
        screen.window.layoutIfNeeded()

        #expect(tools.track.debugRateStamps == ["2×"], "got \(tools.track.debugRateStamps)")
    }

    /// Undo is one arrow whose meaning is the mode — and in this mode it has to
    /// undo a rate as well as a cut, because both live in the same value.
    @Test func theUndoArrowComesAliveForARateAndPutsItBack() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        putTheNeedle(at: 5, on: tools.track, in: screen)
        #expect(screen.editor.debugCropResetItem.isEnabled == false, "guard: nothing to undo")

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)
        #expect(screen.editor.debugCropResetItem.isEnabled, "a rate is something to undo")

        screen.editor.debugTapReset()
        #expect(MediaTimelining.rate(at: 5, in: tools.track.debugTimeline, withinSource: 10) == 1)
    }

    /// ⚠️ **AND IT HAS TO BE WHERE SOMEBODY CAN READ IT.** Pinned to its piece's
    /// leading edge, the stamp is off screen for every piece longer than a
    /// screenful — which at the resting scale is any clip past six and a half
    /// seconds. Seen on the device: the rate was chosen, the total changed, and
    /// nothing on the film said which piece had changed.
    @Test func aRateStampStaysReadableWhenItsPieceRunsPastTheEdge() {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        // A minute of film at 2× is half a minute of result — 1800pt against a
        // 390pt track, so the piece is far longer than the window.
        track.configure(
            duration: 60,
            timeline: MediaTimeline(segments: [MediaSegment(start: 0, end: 60, speed: 2)])
        )
        track.setNeedsLayout()
        track.layoutIfNeeded()

        // Far enough in that the piece's own start is well behind the viewport.
        track.debugScroll(toContentOffset: 400)
        track.layoutIfNeeded()

        let stamp = try? #require(track.debugRateStampFrames.first)
        #expect(stamp != nil, "the piece lost its stamp: \(track.debugRateStamps)")
        #expect(track.debugVisibleContent.contains(stamp?.midX ?? -1),
                "the stamp is off screen at \(String(describing: stamp)) of \(track.debugVisibleContent)")
    }

    /// ⚠️ **ONE CLOCK IN THE READOUT — CHARTER F10.** "Where the playhead is" and
    /// "how long the result runs" are the same question asked twice, and for one
    /// build the left half was in SOURCE seconds while the right was in PLAYED
    /// ones. At 1× they agree and nothing shows; at 2× they part company.
    @Test func theReadoutCountsInTheSecondsAViewerWillExperience() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        putTheNeedle(at: 4, on: tools.track, in: screen)
        #expect(tools.track.debugKeptText == "0:04 / 0:10", "guard: as shot, one clock")

        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)
        screen.window.layoutIfNeeded()

        // Four seconds of film at twice the speed is two seconds of result, out
        // of a ten-second clip that now runs five.
        #expect(tools.track.debugKeptText == "0:02 / 0:05",
                "got \(tools.track.debugKeptText ?? "nil")")
    }

    // MARK: - Taking hold of a piece

    /// ⚠️ **NOTHING IS SELECTED UNTIL THE AUTHOR SAYS SO.** The track used to
    /// open with a white frame around the whole timeline, which claims a decision
    /// nobody has made — and with more than one piece it claims it about the
    /// wrong one. Asked for in those words: the selection happens when you tap
    /// the track or one of its segments.
    @Test func aTrackNobodyHasTouchedHasNothingSelected() throws {
        let screen = open(Self.items(1, videosAt: [0]))

        choose(Mode.trim, on: screen)
        screen.window.layoutIfNeeded()
        let track = try tools(in: screen).track

        #expect(track.debugSelectedPiece == nil)
        // ⚠️ **WHAT IS DRAWN, NOT WHAT IS HELD — AND ASKING ONLY THE SECOND WAS A
        // TEST THAT COULD NOT FAIL.** Proved by deliberate break: a layout that
        // framed the first piece whatever `selected` said left this green,
        // because both assertions read the same variable the break did not touch.
        #expect(track.debugSelectionIsDrawn == false, "a frame is drawn around something")
        #expect(track.debugSelectionInkShowing == false, "part of a frame is on screen")
    }

    @Test func tappingAPieceTakesHoldOfIt() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        let pieces = track.debugPieceFrames
        #expect(pieces.count == 2, "guard: there are two to choose between")

        // A touch in the middle of the SECOND piece.
        let second = pieces[1]
        track.debugTap(atContentX: (second.lowerBound + second.upperBound) / 2)
        screen.window.layoutIfNeeded()

        #expect(track.debugSelectedPiece == 1)
        #expect(track.debugSelectionIsDrawn, "nothing is framed")
        let held = try #require(track.debugSelectedRangeX)
        #expect(abs(held.lowerBound - second.lowerBound) < 0.01,
                "the frame is around the wrong piece: \(held) against \(second)")
    }

    @Test func tappingPastTheFilmPutsThePieceDown() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        screen.window.layoutIfNeeded()
        track.debugTap(atContentX: 40)
        #expect(track.debugSelectedPiece == 0, "guard: something is held")

        // Past the end of the whole result.
        track.debugTap(atContentX: 100_000)
        screen.window.layoutIfNeeded()

        #expect(track.debugSelectedPiece == nil)
        #expect(track.debugSelectionIsDrawn == false, "the frame stayed on screen")
        #expect(track.debugSelectionInkShowing == false, "part of the frame stayed on screen")
    }

    /// ⚠️ **A FINGER THAT LANDS ON A CAP IS AIMING AT ITS PIECE.** The caps are
    /// drawn OUTSIDE the piece they belong to, so a touch on one is outside every
    /// placement — and putting the piece down there would make the selection
    /// flicker off whenever somebody reaches for a handle and misses by a point.
    @Test func aTapOnTheHeldPiecesCapKeepsIt() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        screen.window.layoutIfNeeded()
        track.debugTap(atContentX: 40)
        let held = try #require(track.debugSelectedRangeX)

        // Six points outside the piece's own start — the middle of its cap.
        track.debugTap(atContentX: held.lowerBound - 6)

        #expect(track.debugSelectedPiece == 0)
    }

    // MARK: - Resizing a piece

    /// ⚠️ **EVERY PIECE'S EDGES, NOT THE OUTER PAIR — ASKED FOR IN THOSE WORDS.**
    /// Dragging the second piece's start used to be impossible: the handles
    /// belonged to the whole timeline, so the only two edges an author could
    /// reach were the very beginning and the very end.
    @Test func theSecondPiecesOwnEdgeIsWhatMoves() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        let before = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(before.count == 2, "guard: two pieces")

        track.select(1)
        screen.window.layoutIfNeeded()
        let held = try #require(track.debugSelectedRangeX)
        track.debugTakeHold(at: held.lowerBound)
        track.debugDrag(byPoints: 60)              // a second into the second piece
        track.debugRelease()

        let after = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(abs(after[1].start - (before[1].start + 1)) < 0.05,
                "the second piece's start did not move: \(after)")
        #expect(abs(after[0].end - before[0].end) < 0.001,
                "the first piece was changed as well: \(after)")
        #expect(abs(after[1].end - before[1].end) < 0.001, "got \(after)")
    }

    /// And the pieces after it slide along: the track is the result, so trimming
    /// one piece shortens the whole thing by exactly what it gave up.
    @Test func trimmingAPieceTakesItsFilmOutOfTheResult() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        let wide = track.debugContentWidth
        let played = MediaTimelining.playedSeconds(of: track.debugTimeline, withinSource: 10)

        track.select(1)
        screen.window.layoutIfNeeded()
        let held = try #require(track.debugSelectedRangeX)
        track.debugTakeHold(at: held.lowerBound)
        track.debugDrag(byPoints: 60)
        track.debugRelease()
        screen.window.layoutIfNeeded()

        #expect(abs(track.debugContentWidth - (wide - 60)) < 2,
                "the track did not ripple: \(track.debugContentWidth) of \(wide)")
        #expect(abs(MediaTimelining.playedSeconds(of: track.debugTimeline, withinSource: 10)
                    - (played - 1)) < 0.05,
                "the result did not get a second shorter")
    }

    /// ⚠️ **THE CAP TRAVELS WITH THE FINGER, WHICH TAKES A SCROLL TO ACHIEVE.**
    /// A piece begins where the pieces before it end, and dragging its START does
    /// not change that number: the piece shortens from the inside, so every frame
    /// in it slides left while the cap stays exactly where it was. Uncorrected,
    /// the author is dragging a handle that does not move.
    ///
    /// ⚠️ **AND IT COSTS NOTHING TO ACHIEVE NOW.** For one round this needed a
    /// scroll: the axis was the composition, so a piece began where the one
    /// before it ended and trimming its head shortened it from the inside. The
    /// file is the axis again — the piece gives up exactly what the hole beside
    /// it takes — so the cap follows the finger without a single frame moving.
    /// ⚠️ **THE FIRST PIECE ONLY, AND THAT IS THE WHOLE OF THE RULE.** This used
    /// to hold the second piece, and it cannot: a piece begins where the ones
    /// before it end, so an interior head cannot move its cap without dragging
    /// every clip before it across the screen — which the author reported as the
    /// edit reaching into a section they never touched. The first piece has
    /// nothing before it, so the composition itself is what shortens, and the
    /// leading slack is what gives the scroller the room to do it.
    /// `openingASectionsHeadRevealsFilmBeforeItAndPushesWhatPrecedes` is the
    /// other half: what the scroll holds still is the pince's own side.
    @Test func draggingTheFirstHeadKeepsTheCapUnderTheFinger() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        track.select(0)
        screen.window.layoutIfNeeded()
        let held = try #require(track.debugSelectedRangeX)
        // Where the cap is ON SCREEN: content x minus where the film is scrolled.
        let onScreen = held.lowerBound - track.debugContentOffset

        track.debugTakeHold(at: held.lowerBound)
        track.debugDrag(byPoints: 60)
        track.debugRelease()
        screen.window.layoutIfNeeded()

        let after = try #require(track.debugSelectedRangeX)
        #expect(abs((after.lowerBound - track.debugContentOffset) - (onScreen + 60)) < 1,
                "the cap did not follow the finger: \(onScreen) then \(after.lowerBound - track.debugContentOffset)")
    }

    /// ⚠️ **A PIECE REACHES BACK OVER ITS NEIGHBOUR'S FILM, AND THE TRACK PUSHES
    /// THE NEIGHBOUR ALONG.** A cut does not divide the film between the two
    /// halves — each keeps the whole source available, which is what every editor
    /// calls its handles. This test used to assert the opposite, and that was the
    /// defect: *"si on etire sur la pince de droite, le clip doit pousser le
    /// segment suivant et reveler le reste de la video"*.
    @Test func stretchingAPieceRevealsTheFilmAndPushesTheNextPiece() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        let before = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        let secondWas = track.debugPieceFrames[1]

        // Pull the FIRST piece's end two seconds further into the film.
        track.select(0)
        screen.window.layoutIfNeeded()
        let held = try #require(track.debugSelectedRangeX)
        track.debugTakeHold(at: held.upperBound)
        track.debugDrag(byPoints: 120)
        track.debugRelease()
        screen.window.layoutIfNeeded()

        let after = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(abs(after[0].end - (before[0].end + 2)) < 0.05,
                "the first piece stopped at the cut: \(after)")
        #expect(abs(after[1].start - before[1].start) < 0.001,
                "the second piece's own film was changed: \(after)")
        let secondIsNow = track.debugPieceFrames[1]
        #expect(abs(secondIsNow.lowerBound - (secondWas.lowerBound + 120)) < 2,
                "the second piece was not pushed along: \(secondIsNow) from \(secondWas)")
    }

    /// ⚠️ **THE STRETCH, SEEN FROM THE FINGER.** A piece at 2× is drawn half as
    /// wide as the film it covers, so the same drag has to be worth twice as much
    /// film. Converting the drag straight to source seconds — which is what the
    /// single-clock version did — moved a fast piece's edge half as far as the
    /// track showed.
    @Test func aDragOnAFastPieceCutsTwiceTheFilm() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let tools = try tools(in: screen)
        let track = tools.track
        track.debugTap(atContentX: 40)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.speed.rawValue
        )
        tools.speeds.debugTap(rate: 2)
        screen.window.layoutIfNeeded()
        let before = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)

        let held = try #require(track.debugSelectedRangeX)
        track.debugTakeHold(at: held.lowerBound)
        track.debugDrag(byPoints: 60)              // one second of RESULT
        track.debugRelease()

        let after = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(abs(after[0].start - (before[0].start + 2)) < 0.05,
                "a second of a 2× piece is two seconds of film: \(after)")
    }

    /// ⚠️ **THE FILM ENDS WHERE THE RESULT ENDS.** The tile count rounds up — six
    /// seconds is 360pt, which is six and two thirds of a 54pt tile — so the last
    /// square overhangs. Seen on the device once the discarded film stopped being
    /// drawn: 18pt of picture stuck out past the closing cap.
    @Test func theLastTileIsCutToTheEndOfTheFilm() {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        // Ten seconds: 600pt, and 600 is not a multiple of 54.
        track.configure(duration: 10, timeline: .whole)
        track.setNeedsLayout()
        track.layoutIfNeeded()

        let film = track.debugContentWidth
        #expect(film == 600, "guard: \(film)")
        let last = try? #require(track.debugTileFrames.max { $0.maxX < $1.maxX })
        #expect((last?.maxX ?? 0) <= film + 0.01,
                "the film runs \((last?.maxX ?? 0) - film)pt past its own end")

        // ⚠️ **AND THE END IS ONE WHOLE CORNER, DRAWN BY THE PIECE'S WINDOW.**
        // The last square is a sliver; rounded on its own it could not carry an
        // eight-point curve.
        track.debugScroll(toContentOffset: 600 - 195)
        track.layoutIfNeeded()
        let window = track.debugFilmWindows.last
        #expect((window?.frame.maxX ?? .infinity) <= film + 0.01,
                "the window runs past the film: \(String(describing: window?.frame))")
        #expect(window?.corners.contains(.layerMaxXMaxYCorner) == true,
                "the end of the film is not rounded: \(String(describing: window?.corners))")
        #expect(window?.radius == MediaTimelineTrackView.debugFilmCorner,
                "the end is rounded to \(String(describing: window?.radius))")
        #expect(track.debugTiles.allSatisfy { $0.cornerRadius == 0 },
                "a square carries a radius of its own")
    }

    /// ⚠️ **THERE IS NOTHING BETWEEN THE PIECES TO MARK, AND A ROUND OF THIS
    /// WORK SAYS WHY.** The track carried the whole file for a while, with the
    /// cut-away stretches greyed — which made an edge drag free of any scrolling
    /// and put a hole in the middle of the track for the playhead to leap.
    /// Trimming ripples instead: the pieces stay touching and the result's clock
    /// runs without a break. What is thrown away is off the track, and the way
    /// back to it is to drag the edge out again.
    @Test func theClockLaysThePiecesEndToEndWhateverIsDrawnBetweenThem() {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        // Two pieces of a ten-second clip with four seconds cut out between them.
        track.configure(duration: 10, timeline: MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2, speed: 1),
            MediaSegment(start: 6, end: 10, speed: 1)
        ]))
        track.setNeedsLayout()
        track.layoutIfNeeded()

        let pieces = track.debugPieceFrames
        #expect(pieces.count == 2, "got \(pieces)")
        #expect(abs(pieces[0].upperBound - pieces[1].lowerBound) < 0.01,
                "the ARITHMETIC has a gap between \(pieces[0]) and \(pieces[1])")
        #expect(abs(track.debugContentWidth - 360) < 0.01,
                "the track is not the length of the result: \(track.debugContentWidth)")
        // ⚠️ The daylight is DRAWN, centred on the seam, and nothing else.
        let gaps = track.debugSeamGaps
        #expect(gaps.count == 1, "got \(gaps)")
        #expect(abs((gaps.first.map { $0.to - $0.from } ?? 0) - MediaTimelineTrackView.debugSeamGap) < 0.01,
                "got \(gaps)")
        #expect((gaps.first.map { $0.to - $0.from } ?? 0) >= 1,
                "the daylight between the pieces cannot be seen: \(gaps)")
        #expect(abs((gaps.first.map { ($0.from + $0.to) / 2 } ?? 0) - 120) < 0.01,
                "the daylight is not centred on the seam: \(gaps)")
    }

    // MARK: - Crop or continue, and only the clip on that side

    /// A three-piece track, laid out, with `piece` held — the shape the author is
    /// working in once they have cut more than once.
    private func cutInThree(holding piece: Int) -> MediaTimelineTrackView {
        TrackFixture.cutInThree(holding: piece)
    }

    private func segments(of track: MediaTimelineTrackView) -> [MediaSegment] {
        MediaTimelining.resolved(track.debugTimeline, withinSource: 12)
    }

    /// ⚠️ **PULLED IN, A HANDLE CROPS ITS OWN CLIP AND BRINGS THE NEXT ONE BACK.**
    /// Stated by the author: *"si on tire la pince vers la gauche alors cela crop
    /// le clip 1 et ramène le clip 2 (donc la durée totale est moindre)"*. Every
    /// drag in this repository's suites used to go RIGHTWARDS — the crop
    /// direction was not exercised through the view at all, so a build that
    /// clamped a negative delta, or took the film off the neighbour instead,
    /// passed.
    @Test func croppingASectionFromTheRightBringsTheNextOneBack() throws {
        let track = cutInThree(holding: 0)
        let before = segments(of: track)
        let framesWere = track.debugPieceFrames
        let wide = track.debugContentWidth
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.end)
        track.debugDrag(byPoints: -60)
        track.debugRelease()
        track.layoutIfNeeded()

        let after = segments(of: track)
        #expect(abs(after[0].end - (before[0].end - 1)) < 0.01, "the crop missed: \(after)")
        #expect(after[1] == before[1], "the next section was modified: \(after[1])")
        #expect(after[2] == before[2], "a section two along was modified: \(after[2])")
        #expect(abs(track.debugPieceFrames[1].lowerBound - (framesWere[1].lowerBound - 60)) < 0.01,
                "the next section did not come back with the handle")
        #expect(abs(track.debugContentWidth - (wide - 60)) < 0.01,
                "the result did not get shorter: \(track.debugContentWidth) against \(wide)")
    }

    /// ⚠️ **AND PULLED OUT, IT CONTINUES ITS OWN CLIP AND PUSHES THE REST.** The
    /// author's first rule, through the view, on a track with a piece on BOTH
    /// sides — with only two pieces "pushes the next one" and "pushes everything
    /// after it" are the same sentence.
    @Test func continuingASectionPushesEveryPieceAfterItAndModifiesNone() throws {
        let track = cutInThree(holding: 1)
        let before = segments(of: track)
        let framesWere = track.debugPieceFrames
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.end)
        track.debugDrag(byPoints: 60)
        track.debugRelease()
        track.layoutIfNeeded()

        let after = segments(of: track)
        #expect(abs(after[1].end - (before[1].end + 1)) < 0.01, "the middle piece did not continue")
        #expect(after[0] == before[0], "the piece before it was modified: \(after[0])")
        #expect(after[2] == before[2], "the piece after it was modified: \(after[2])")
        let framesAre = track.debugPieceFrames
        #expect(framesAre[0] == framesWere[0], "the piece before it moved on the track")
        #expect(abs(framesAre[2].lowerBound - (framesWere[2].lowerBound + 60)) < 0.01,
                "the piece after it was not pushed along")
    }

    /// ⚠️ **THE LEFT HANDLE PULLED LEFT CONTINUES ITS CLIP BACK OVER THE CUT.**
    /// *"Pareil pour la pince de gauche."* The only test of this direction lived
    /// in the pure suite; through the view it was never run at all, and it is the
    /// one that goes through the leading-slack branch with a NEGATIVE loss.
    @Test func continuingASectionsHeadRevealsTheFilmBeforeTheCut() throws {
        let track = cutInThree(holding: 1)
        let before = segments(of: track)
        let wide = track.debugContentWidth
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.start)
        track.debugDrag(byPoints: -60)
        track.debugRelease()
        track.layoutIfNeeded()

        let after = segments(of: track)
        #expect(abs(after[1].start - (before[1].start - 1)) < 0.01,
                "the head did not reach back over the cut: \(after)")
        #expect(after[0] == before[0], "the piece before it was modified: \(after[0])")
        #expect(abs(track.debugContentWidth - (wide + 60)) < 0.01,
                "the result did not get longer: \(track.debugContentWidth) against \(wide)")
    }

    /// ⚠️ **AND WHEN THE FINGER COMES UP, THE PREVIEW COMES BACK TO THE NEEDLE.**
    /// While a handle is held the canvas shows the frame the EDGE is standing on,
    /// which is how a trim is aimed; left there, the player sits on that frame and
    /// the next beat of playback has the TRACK follow it — the whole film slides
    /// under the needle the instant the finger lifts, which reads as every section
    /// moving at once. The last thing a drag says is where the needle is.
    @Test func lettingGoOfAHandlePutsThePreviewBackOnTheNeedle() throws {
        let track = cutInThree(holding: 1)
        var scrubs: [MediaTimelining.Moment] = []
        track.onScrub = { scrubs.append($0) }
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.end)
        track.debugDrag(byPoints: -60)
        let aimed = try #require(scrubs.last)
        track.debugRelease()

        let settled = try #require(scrubs.last)
        let needle = try #require(track.momentUnderNeedle)
        #expect(aimed.sourceSeconds != settled.sourceSeconds,
                "the drag never aimed anywhere else, so this proves nothing")
        #expect(settled.piece == needle.piece
                && abs(settled.sourceSeconds - needle.sourceSeconds) < 0.01,
                "the preview was left on the edge: \(settled) against \(needle)")
    }

    // MARK: - The gesture belongs to the clip it is aimed at

    /// ⚠️ **A CUT HANDS THE LEFT HALF BACK HELD, AND LEAVING NOTHING HELD WAS THE
    /// DEFECT.** The handles exist only around the piece that is held, so a track
    /// with nothing held has no handles anywhere: the author cuts, reaches for
    /// the seam they have just made, and the finger finds no control — the film
    /// scrolls instead. Reported as the sections not being editable at all.
    @Test func aCutLeavesTheLeftHalfHeldSoItsHandlesAreThere() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)

        #expect(track.debugSelectedPiece == 0, "the half the needle left is the one in hand")
        #expect(track.debugSelectionIsDrawn, "a piece is held and no frame is drawn round it")
        let seam = track.debugPieceFrames[0].upperBound
        #expect(track.debugWouldTakeAHandle(at: seam + 4),
                "there is no handle at the cut the author has just made")
    }

    /// ⚠️ **AND THE OTHER SECTION CAN BE TAKEN BY POINTING AT IT.** A cap is drawn
    /// twelve points outside its own piece, which at an interior cut is twelve
    /// points INTO the neighbour's film. A tap there used to be swallowed to
    /// protect a finger that had missed a handle — so the author could not take
    /// the section on the other side of the cut, dragged the handle they could
    /// see, and watched the piece they had held all along move instead.
    /// ⚠️ **FROM ITS FIRST VISIBLE POINT** — past the held cap, which is opaque
    /// over the neighbour's first frames and answers for the cut it stands on.
    @Test func aTapPastTheCutTakesTheSectionOnTheOtherSideOfIt() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)
        #expect(track.debugSelectedPiece == 0, "guard: the left half is held")

        track.debugTap(atContentX: track.debugEndGrip.maxX + 4)

        #expect(track.debugSelectedPiece == 1,
                "the tap landed on the second section's film and did not take it")
        #expect(screen.editor.debugTransitionSeam == nil, "a tap on the film opened the cut")
    }

    /// And a tap PAST the film still keeps what is held: that is what the cap
    /// band was for, and it is the half that must survive.
    @Test func aTapOnACapPastTheEndOfTheFilmKeepsTheHeldPiece() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)
        track.debugTap(atContentX: track.debugEndGrip.maxX + 4)
        #expect(track.debugSelectedPiece == 1, "guard: the last section is held")

        track.debugTap(atContentX: track.debugPieceFrames[1].upperBound + 6)

        #expect(track.debugSelectedPiece == 1, "a finger on the closing cap put the piece down")
    }

    /// ⚠️ **A PRESS ON A HELD PIECE'S CAP NEVER LIFTS ITS NEIGHBOUR** — by
    /// position alone the cap is inside the next piece, drawn on its film, and a
    /// press there once lifted the wrong section. A cap standing on a cut now
    /// carries that cut's `+`, and a press on it is a tap (F27): it lifts
    /// nothing at all. The neighbour is still lifted from its own film.
    @Test func aPressOnTheHeldPiecesPlusLiftsNeitherPiece() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)
        #expect(track.debugSelectedPiece == 0, "guard: the left half is held")

        // The closing cap of the held piece, which stands on the next one's film.
        track.debugLift(atContentX: track.debugPieceFrames[0].upperBound + 6)

        #expect(track.debugCarrying == nil,
                "the press on the cap's + lifted \(String(describing: track.debugCarrying))")
        #expect(track.debugWouldLift(atContentX: track.debugEndGrip.maxX + 10),
                "guard: the neighbour cannot be lifted from its own film")
    }

    /// Where a piece is drawn ON SCREEN — content points less the scroll.
    private func onScreen(_ piece: Int, of track: MediaTimelineTrackView) -> ClosedRange<CGFloat> {
        let at = track.debugPieceFrames[piece]
        return (at.lowerBound - track.debugContentOffset)...(at.upperBound - track.debugContentOffset)
    }

    /// ⚠️ **THE LEFT PINCE IS THE MIRROR OF THE RIGHT ONE.** Asked for in those
    /// words: *"si on tire la pince gauche vers la gauche… dévoiler la partie
    /// avant et pousser la section précédente — en gros ce qu'on a fait pour la
    /// pince de droite"*. So: the film of the section being opened, its closing
    /// edge and every section AFTER it stand perfectly still, and the sections
    /// BEFORE it are pushed aside by exactly what was revealed.
    @Test func openingASectionsHeadRevealsFilmBeforeItAndPushesWhatPrecedes() throws {
        let track = cutInThree(holding: 1)
        let before = segments(of: track)
        let firstWas = onScreen(0, of: track)
        let heldWas = onScreen(1, of: track)
        let lastWas = onScreen(2, of: track)
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.start)
        track.debugDrag(byPoints: -60)

        let after = segments(of: track)
        #expect(abs(after[1].start - (before[1].start - 1)) < 0.01,
                "the head did not open over the film before it: \(after)")
        #expect(after[0] == before[0], "the section before it was modified: \(after[0])")
        #expect(after[2] == before[2], "the section after it was modified: \(after[2])")

        #expect(abs(onScreen(1, of: track).upperBound - heldWas.upperBound) < 0.01,
                "the closing pince of the section being opened moved")
        #expect(abs(onScreen(2, of: track).lowerBound - lastWas.lowerBound) < 0.01,
                "the section after it moved")
        #expect(abs(onScreen(0, of: track).lowerBound - (firstWas.lowerBound - 60)) < 0.01,
                "the section before it was not pushed aside: \(firstWas) -> \(onScreen(0, of: track))")
        track.debugRelease()
    }

    /// ⚠️ **AND AT THE START OF THE FILM IT DOES NOTHING AT ALL.** The author's
    /// own condition: *"si on tire la pince gauche vers la gauche cela doit soit
    /// rien faire si la pince est au début du clip"*. There is no film before the
    /// first frame, so the edit is refused — and, just as importantly, the track
    /// must not scroll to pretend otherwise.
    @Test func openingAHeadThatIsAlreadyAtTheStartOfTheFilmDoesNothing() throws {
        let track = cutInThree(holding: 0)
        #expect(segments(of: track)[0].start == 0, "guard: the first section starts on the film")
        let before = segments(of: track)
        let framesWere = track.debugPieceFrames
        let offsetWas = track.debugContentOffset
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.start)
        track.debugDrag(byPoints: -60)

        #expect(segments(of: track) == before, "it edited something: \(segments(of: track))")
        #expect(abs(track.debugContentOffset - offsetWas) < 0.01,
                "the track scrolled for an edit that was refused")
        #expect(track.debugPieceFrames == framesWere, "the track moved for an edit that was refused")
        track.debugRelease()
    }

    /// And closing it again brings that section back — the same mirror, the other
    /// way round.
    @Test func croppingASectionsHeadBringsBackWhatPrecedesIt() throws {
        let track = cutInThree(holding: 1)
        let firstWas = onScreen(0, of: track)
        let heldWas = onScreen(1, of: track)
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.start)
        track.debugDrag(byPoints: 60)

        #expect(abs(onScreen(1, of: track).upperBound - heldWas.upperBound) < 0.01,
                "the closing pince of the section being cropped moved")
        #expect(abs(onScreen(0, of: track).lowerBound - (firstWas.lowerBound + 60)) < 0.01,
                "the section before it did not come back")
        track.debugRelease()
    }

    /// ⚠️ **AND THE FILM UNDER THE NEEDLE HOLDS, WHEREVER THE NEEDLE IS IN WHAT
    /// STANDS STILL.** The author's oldest standing rule — *"le curseur ne devrait
    /// jamais faire de saut"* — applied to the half of the track a head trim does
    /// not move: the section being trimmed and everything after it.
    @Test func openingAHeadLeavesTheFilmUnderTheNeedleAloneWhenItIsPastThePince() throws {
        let track = cutInThree(holding: 1)
        // The needle inside the LAST section, which a head trim must not disturb.
        track.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forPlayedSeconds: 7, trackWidth: track.bounds.width
        ))
        track.layoutIfNeeded()
        let moment = try #require(track.momentUnderNeedle)
        #expect(moment.piece == 2, "guard: the needle is in the last section")
        let centres = try #require(track.debugHandleCentres)

        track.debugTakeHold(at: centres.start)
        track.debugDrag(byPoints: -60)
        let during = try #require(track.momentUnderNeedle)
        track.debugRelease()
        track.layoutIfNeeded()
        let after = try #require(track.momentUnderNeedle)

        #expect(during.piece == moment.piece
                && abs(during.sourceSeconds - moment.sourceSeconds) < 0.01,
                "the film under the needle moved while the handle was held: \(during)")
        #expect(after.piece == moment.piece && abs(after.sourceSeconds - moment.sourceSeconds) < 0.01,
                "the film under the needle moved on release: \(after)")
    }

    /// ⚠️ **AND THE SPOKEN ADJUSTMENT MOVES THE PIECE THAT IS HELD.** The overload
    /// without an index resolves to the LAST piece, so with the first half framed
    /// on screen a VoiceOver swipe silently lengthened the other half.
    @Test func theSpokenAdjustmentMovesTheSectionThatIsHeld() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)
        let before = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(track.debugSelectedPiece == 0, "guard: the left half is held")

        track.accessibilityDecrement()

        let after = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(after[0].end < before[0].end, "the held piece did not move: \(after)")
        #expect(after[1] == before[1], "a piece nobody was holding moved: \(after)")
    }

    // MARK: - Carrying a piece

    /// ⚠️ **A LONG PRESS LIFTS A PIECE, AND A DRAG PUTS IT SOMEWHERE ELSE.** The
    /// order on the track is the order the post plays in, so this is an edit, not
    /// a view state: it travels through `onChange` into `edits` and out to the
    /// exporter, which inserts the pieces in the order it is given.
    @Test func carryingAPiecePastItsNeighbourChangesTheOrder() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        let before = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(before.count == 2, "guard: two pieces to swap")
        let pieces = track.debugPieceFrames

        // Press on the first piece, carry it into the second's place, let go.
        track.debugLift(atContentX: pieces[0].lowerBound + 10)
        #expect(track.debugCarrying == 0, "nothing was lifted")
        screen.window.layoutIfNeeded()
        // ⚠️ REQUIRED BEFORE IT IS SUBSCRIPTED — a break that stops the list being
        // raised must report, not trap and take the whole run down with it.
        try #require(track.debugShotFrames.count == 2, "guard: the list is up")
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.debugDrop()
        screen.window.layoutIfNeeded()

        let after = MediaTimelining.resolved(track.debugTimeline, withinSource: 10)
        #expect(after.map(\.start) == [before[1].start, before[0].start],
                "the pieces did not change places: \(after)")
    }

    /// And it reaches the post: the finalisation screen is handed the order the
    /// author left on the track.
    @Test func theCarriedOrderIsWhatTravelsOnward() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        let pieces = track.debugPieceFrames

        track.debugLift(atContentX: pieces[0].lowerBound + 10)
        screen.window.layoutIfNeeded()
        // ⚠️ REQUIRED BEFORE IT IS SUBSCRIPTED — a break that stops the list being
        // raised must report, not trap and take the whole run down with it.
        try #require(track.debugShotFrames.count == 2, "guard: the list is up")
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.debugDrop()
        screen.editor.debugTapNext()

        let carried = try #require(screen.handed.edits?["video-0"]?.timeline)
        let order = MediaTimelining.resolved(carried, withinSource: 10)
        #expect(order.count == 2, "got \(order)")
        #expect(order[0].start > order[1].start,
                "the second half of the clip should play first: \(order)")
    }

    /// ⚠️ **A CARRY THAT SHOWS NOTHING READS AS A CARRY THAT DID NOT HAPPEN.**
    /// Reported as the gesture working "partially": it worked — the order
    /// changed, the export followed — and the track said nothing while a piece
    /// was in hand, so there was no way to tell it from a press that had gone
    /// nowhere. A press raises the shot list, and the piece in hand is the one
    /// that stands out of it.
    @Test func carryingAPieceRaisesTheShotListAndLiftsThePieceInHand() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)
        #expect(track.debugShotFrames.isEmpty, "guard: no shot list at rest")
        #expect(track.debugTrackIsShowing, "guard: the track is showing at rest")

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        screen.window.layoutIfNeeded()

        try #require(track.debugShotFrames.count == 2,
                     "one chip per piece: \(track.debugShotFrames)")
        #expect(track.debugShotInHand == 0,
                "nothing is lifted, so nothing says which piece is held")
        // ⚠️ **PUT AWAY, NOT STOOD BACK, AND NOTHING SEE-THROUGH.** Reported:
        // *"on aperçoit la timeline par derrière (il y a un fouillis car tout est
        // en semi transparent)"*.
        #expect(track.debugTrackIsPutAway, "the track shows through the shot list")
        #expect(track.debugShotOpacity.allSatisfy { $0 > 0.99 },
                "a chip is see-through: \(track.debugShotOpacity)")
        #expect(track.debugShotShaded == [false, true],
                "the piece in hand is not the bright one: \(track.debugShotShaded)")
    }

    /// ⚠️ **THE WHOLE COMPOSITION IS ON SCREEN FOR THE LENGTH OF THE CARRY.**
    /// Asked for in those words — *"reduire au grab tout les segments a des
    /// largeurs egales pour pouvoir plus facilement inserer sans avoir a
    /// parcourir toute la timeline"* — and it is not decoration: the track cannot
    /// scroll while a piece is being carried, so a destination that is off screen
    /// is a destination the author cannot reach at all. Ten seconds of film is
    /// 600pt on a 390pt track, which is what makes this a real reach.
    @Test func everyPieceIsWithinReachWhileOneIsCarried() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)
        let onTheTrack = track.debugPieceFrames
        #expect(onTheTrack[1].upperBound > track.bounds.width,
                "guard: the second piece is already on screen, so nothing is proved")

        track.debugLift(atContentX: onTheTrack[0].lowerBound + 10)
        screen.window.layoutIfNeeded()

        let chips = track.debugShotFrames
        // ⚠️ REQUIRED, NOT EXPECTED — an `#expect` here leaves the subscripts
        // below to trap on an empty array, which ends the whole RUN and hides
        // what a deliberate break was meant to show.
        try #require(chips.count == 2, "got \(chips)")
        #expect(abs(chips[0].width - chips[1].width) < 0.5,
                "the chips are not the same width: \(chips)")
        for chip in chips {
            #expect(chip.minX >= -0.5 && chip.maxX <= track.bounds.width + 0.5,
                    "\(chip) is off a \(track.bounds.width)pt track")
        }
        // The list keeps room at both ends for its first and last timecodes.
        #expect(chips[1].maxX > track.bounds.width - MediaTimelineTrackView.debugShotInset - 6,
                "the list does not fill the track: \(chips)")
        #expect(track.debugShotListScrolls == false, "a list that fits scrolls")
    }

    /// And the list is laid back down when the finger goes, or the track keeps a
    /// dimmed row of chips over it for ever.
    @Test func puttingAPieceDownTakesTheShotListAway() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        screen.window.layoutIfNeeded()
        #expect(track.debugShotFrames.count == 2, "guard: the list is up")

        let standing = track.debugShotFrames
        track.debugDrop()
        screen.window.layoutIfNeeded()

        // ⚠️ **IT FADES OUT WHERE IT STANDS, NOT SWITCHED OFF IN ONE TURN AND NOT
        // SENT TRAVELLING.** Its arrival is a fade and a scale from each chip's
        // centre; its departure is the same thing backwards, while the track
        // fades back in under it.
        let leaving = track.debugShotFrames
        try #require(leaving.count == 2, "the list vanished in one turn instead of fading")
        #expect(leaving == standing, "the chips travelled on their way out: \(leaving)")
        #expect(track.debugShotOpacity.allSatisfy { $0 < 0.01 },
                "the chips are not fading out: \(track.debugShotOpacity)")
        #expect(track.debugTrackIsShowing, "the track is not coming back")

        // ⚠️ **SETTLE, THEN ASSERT.** `settle(until:)` gives up after three seconds
        // WITHOUT failing, so waiting on a condition is not the same as requiring
        // it — proved by deliberate break: with the chips never taken away this
        // test stayed green until the line below existed.
        try await settle(until: { track.debugShotFrames.isEmpty })
        #expect(track.debugShotFrames.isEmpty,
                "the chips stayed over the track: \(track.debugShotFrames)")
        #expect(track.debugTrackIsShowing, "the track stayed put away after the drop")
    }

    /// ⚠️ **THE LIST APPEARS IN PLACE: A FADE, AND A SCALE FROM EACH CHIP'S
    /// CENTRE.** Reported: *"le contenu des segments compressés apparaît depuis le
    /// haut gauche vers le bas droit, ce n'est pas naturel — un scale depuis le
    /// centre et/ou un fade"*. A chip made in the same turn as the animation had
    /// never been laid out, so its PICTURE was sized inside the animation, from a
    /// zero rectangle in its top-left corner. What is asked here is what the
    /// layers are animating: the chip fades and scales, and neither the chip nor
    /// the picture inside it travels.
    @Test func theListAppearsInPlaceWithAFadeAndAScaleFromEachCentre() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)

        let chips = track.debugShotAnimations
        let pictures = track.debugShotPictureAnimations
        try #require(chips.count == 2, "guard: the list is up")
        for (index, keys) in chips.enumerated() {
            #expect(keys.contains("opacity"), "chip \(index) does not fade in: \(keys)")
            #expect(keys.contains("transform"), "chip \(index) does not scale in: \(keys)")
            #expect(!keys.contains { $0.hasPrefix("position") || $0.hasPrefix("bounds") },
                    "chip \(index) travels or stretches on its way in: \(keys)")
        }
        for (index, keys) in pictures.enumerated() {
            #expect(!keys.contains { $0.hasPrefix("position") || $0.hasPrefix("bounds") },
                    "the picture in chip \(index) grows out of a corner: \(keys)")
        }
        for (frame, chip) in zip(track.debugShotPictureFrames, track.debugShotFrames) {
            #expect(frame.size == chip.size, "a picture is not the size of its chip: \(frame)")
        }
        track.debugDrop()
    }

    /// ⚠️ **THE CHIP IN HAND LEAVES DAYLIGHT BESIDE IT.** Asked for in those
    /// words: *"garde un léger espace entre les segments compressés à
    /// réorganiser"*. The lift is a ratio, and a ratio grows a wide chip by more
    /// than the gap beside it — at 1.06 a 180pt chip gained eleven points and
    /// swallowed four points of daylight whole. Measured on what is DRAWN, lift
    /// included.
    @Test func theChipInHandLeavesDaylightBesideIt() throws {
        let track = cutUnevenly()

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        track.layoutIfNeeded()

        let drawn = track.debugShotDrawnFrames
        try #require(drawn.count == 2, "guard: the list is up")
        #expect(drawn[0].width > 150, "guard: wide chips, which is where a ratio overshoots")
        #expect(drawn[1].minX - drawn[0].maxX >= 6 - 0.01,
                "only \(drawn[1].minX - drawn[0].maxX)pt between the chip in hand and the next")
        #expect(track.debugShotInHand == 0, "guard: the first chip is the one in hand")
        #expect(drawn[0].height > track.debugShotFrames[0].height + 1,
                "the chip in hand is not lifted at all")
        track.debugDrop()
    }

    /// Two pieces of UNEQUAL length, laid out, with nothing held — the case where
    /// a carried piece changes what the ruler has to say.
    private func cutUnevenly() -> MediaTimelineTrackView {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        track.configure(duration: 12, timeline: MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2, speed: 1),     // two seconds
            MediaSegment(start: 2, end: 8, speed: 1)      // six
        ]))
        track.setNeedsLayout()
        track.layoutIfNeeded()
        return track
    }

    /// ⚠️ **WHILE A PIECE IS CARRIED, THE RULER COUNTS THE CHIPS.** Asked for in
    /// those words: *"mettre à jour les crans/indications de temps juste au-dessus
    /// pour que ça corresponde bien"*. The chips are all one width whatever they
    /// run for, so the only honest marks are their seams, each labelled with where
    /// its piece begins in the result — and drawn over that seam.
    @Test func theRulerCountsTheShotListWhileAPieceIsCarried() throws {
        let track = cutUnevenly()
        #expect(track.debugRulerIsFaded, "guard: the ruler fades behind the controls at rest")

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        track.layoutIfNeeded()

        #expect(track.debugRulerIsFaded == false,
                "the fade hides the first and last seams of the list")

        #expect(track.debugRulerMarks == ["0:00", "0:02", "0:08"],
                "the ruler does not name the list's seams: \(track.debugRulerMarks)")
        let chips = track.debugShotFrames
        try #require(chips.count == 2)
        // A chip stands half the daylight inside its seam, on both sides —
        // measured from the chips themselves, so the size of the daylight is not
        // written down twice.
        let half = (chips[1].minX - chips[0].maxX) / 2
        let seams = [chips[0].minX - half, chips[0].maxX + half, chips[1].maxX + half]
        let drawn = track.debugRulerMarkCentres
        try #require(drawn.count == 3, "got \(drawn)")
        for (mark, seam) in zip(drawn, seams) {
            #expect(abs(mark - seam) < 0.5, "a timecode at \(mark) over a seam at \(seam)")
        }
        #expect(track.debugRulerDotCount == 0,
                "half-way dots over chips of unequal length mean nothing")
        track.debugDrop()
    }

    /// ⚠️ **AND IT IS READ AGAIN AT EVERY CROSSING.** *"Attention lorsqu'on
    /// réorganise, il faut bien mettre à jour cette barre de temps."* Carry the
    /// two-second piece past the six-second one and the seam between them now
    /// comes six seconds in, not two.
    @Test func theRulerFollowsTheNewOrderAsAPieceIsCarried() throws {
        let track = cutUnevenly()
        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        track.layoutIfNeeded()
        try #require(track.debugShotFrames.count == 2, "guard: the list is up")

        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.layoutIfNeeded()

        #expect(track.debugCarrying == 1, "guard: the piece did not cross")
        #expect(track.debugRulerMarks == ["0:00", "0:06", "0:08"],
                "the ruler still names the old order: \(track.debugRulerMarks)")
        track.debugDrop()
    }

    // MARK: - A list longer than the track

    /// Twelve one-second pieces: shared out evenly over the track, a chip would
    /// be thirty points wide.
    private func cutIntoTwelve() -> MediaTimelineTrackView {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        track.configure(duration: 12, timeline: MediaTimeline(segments: (0..<12).map {
            MediaSegment(start: Double($0), end: Double($0 + 1))
        }))
        track.setNeedsLayout()
        track.layoutIfNeeded()
        return track
    }

    /// Lifts a piece by its own film, and says where the finger is on the TRACK.
    private func lift(_ piece: Int, on track: MediaTimelineTrackView) throws -> CGFloat {
        let x = track.debugPieceFrames[piece].lowerBound + 10
        let finger = x - track.debugVisibleContent.lowerBound
        track.debugLift(atContentX: x)
        track.layoutIfNeeded()
        try #require(track.debugCarrying == piece, "piece \(piece) was not lifted")
        return finger
    }

    /// The seams of the list as the chips stand, in the track's coordinates.
    private func seams(of chips: [CGRect]) -> [CGFloat] {
        guard chips.count > 1 else { return [] }
        let half = (chips[1].minX - chips[0].maxX) / 2
        return [chips[0].minX - half] + chips.map { $0.maxX + half }
    }

    /// ⚠️ **A CHIP HAS A FLOOR, AND A LIST THAT CANNOT FIT SCROLLS.** Asked for in
    /// those words: *"avoir une largeur minimale pour les segments compressés, et
    /// il faut que ça soit une scrollview horizontale"*. And the piece that was
    /// lifted opens under the finger that lifted it — a list that opened at its
    /// start would put it a screen away.
    @Test func aLongCutKeepsItsChipsReadableAndTheListScrolls() throws {
        let track = cutIntoTwelve()
        track.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forPlayedSeconds: 8, trackWidth: track.bounds.width
        ))
        let finger = try lift(9, on: track)

        let chips = track.debugShotFrames
        try #require(chips.count == 12, "got \(chips.count) chips")
        let daylight = chips[1].minX - chips[0].maxX
        for chip in chips {
            #expect(abs(chip.width - (MediaTimelineTrackView.debugShotMinimum - daylight)) < 0.5,
                    "a chip is \(chip.width)pt, under its floor")
        }
        #expect(chips[0].width >= 44, "a chip narrower than a finger: \(chips[0].width)")
        #expect(track.debugShotListWidth > track.bounds.width + 100,
                "the list is \(track.debugShotListWidth)pt on a \(track.bounds.width)pt track")
        #expect(track.debugShotListScrolls, "a list longer than the track cannot be scrolled")
        #expect(abs(chips[9].midX - finger) < 0.5,
                "the lifted chip opened at \(chips[9].midX), the finger is at \(finger)")
        track.debugDrop()
    }

    /// The witness: two pieces still fit, and a list that fits does not scroll.
    @Test func aShortCutsListDoesNotScroll() throws {
        let track = cutUnevenly()
        _ = try lift(1, on: track)

        #expect(track.debugShotListScrolls == false, "a list that fits scrolls")
        #expect(track.debugShotListOffset == 0, "a list that fits opened scrolled")
        track.debugDrop()
    }

    /// ⚠️ **A CHIP HELD AT THE EDGE SLIDES THE LIST, AND THE PIECE GOES WITH IT.**
    /// Asked for: *"avoir en grab un segment compressé et le bouger vers les
    /// extrémités des bords de l'écran fait slider la scrollview si besoin"*. The
    /// finger stays still; the list moves under it, and the piece in hand takes
    /// every slot it passes over — all the way to the end of the result.
    @Test func holdingAChipAtAnEdgeSlidesTheListAndCarriesThePieceAlong() throws {
        let track = cutIntoTwelve()
        _ = try lift(0, on: track)
        #expect(track.debugShotListOffset == 0, "guard: the first piece opens the list at its start")
        #expect(track.debugListIsScrollingByItself == false, "guard: nothing is at an edge yet")

        track.debugCarry(toTrackX: track.bounds.width - 4)
        #expect(track.debugListIsScrollingByItself, "a chip at the edge left the list standing")
        let reached = try #require(track.debugCarrying)

        track.debugScrollTheList(forSeconds: 0.1)
        track.layoutIfNeeded()
        #expect(track.debugShotListOffset > 0, "the list did not move")
        #expect((track.debugCarrying ?? 0) > reached,
                "the list moved and the piece stayed in slot \(reached)")

        for _ in 0..<40 { track.debugScrollTheList(forSeconds: 0.1) }
        track.layoutIfNeeded()

        #expect(track.debugCarrying == 11, "the piece stopped at \(String(describing: track.debugCarrying))")
        #expect(abs(track.debugShotListOffset - (track.debugShotListWidth - track.bounds.width)) < 0.5,
                "the list stopped short of its end: \(track.debugShotListOffset)")
        #expect(track.debugListIsScrollingByItself == false, "the list goes on scrolling past its end")
        let order = MediaTimelining.resolved(track.debugTimeline, withinSource: 12)
        #expect(order.last?.start == 0, "the first piece is not last: \(order.map(\.start))")

        // ⚠️ **AND THE RULER WENT WITH IT** — a seam labelled where the list used
        // to be is a timecode over the wrong chip.
        let expected = seams(of: track.debugShotFrames)
        let drawn = track.debugRulerMarkCentres
        try #require(drawn.count == expected.count, "\(drawn.count) marks for \(expected.count) seams")
        for (mark, seam) in zip(drawn, expected) {
            #expect(abs(mark - seam) < 0.5, "a timecode at \(mark) over a seam at \(seam)")
        }
        track.debugDrop()
    }

    /// The witness, both ways: away from the edges the list stands still, and at
    /// the START edge it runs back.
    @Test func aChipAwayFromTheEdgesLeavesTheListStill() throws {
        let track = cutIntoTwelve()
        _ = try lift(0, on: track)
        track.debugScrollTheList(toOffset: 200)

        track.debugCarry(toTrackX: track.bounds.width / 2)
        let still = track.debugShotListOffset
        track.debugScrollTheList(forSeconds: 0.1)
        #expect(track.debugListIsScrollingByItself == false, "the middle of the track scrolls the list")
        #expect(track.debugShotListOffset == still, "the list moved under a finger in the middle")

        track.debugCarry(toTrackX: 4)
        #expect(track.debugListIsScrollingByItself, "the start edge left the list standing")
        track.debugScrollTheList(forSeconds: 0.1)
        #expect(track.debugShotListOffset < still, "the start edge ran the list the wrong way")
        track.debugDrop()
    }

    /// ⚠️ **A LIST SCROLLED BY ANOTHER FINGER MOVES THE PIECE TOO.** The carrying
    /// finger has not moved, but what it is over has.
    @Test func scrollingTheListUnderAStillFingerCarriesThePiece() throws {
        let track = cutIntoTwelve()
        _ = try lift(0, on: track)
        track.debugCarry(toTrackX: 100)
        let before = try #require(track.debugCarrying)

        track.debugScrollTheList(toOffset: 200)

        let slot = MediaTimelining.dropIndex(
            forPoints: 100 + 200,
            in: MediaTimelining.shots(
                track.debugTimeline, withinSource: 12,
                across: track.bounds.width - MediaTimelineTrackView.debugShotInset * 2,
                startingAt: MediaTimelineTrackView.debugShotInset,
                atLeast: MediaTimelineTrackView.debugShotMinimum
            ),
            moving: before
        )
        #expect(slot > before, "guard: the scroll passes over other slots")
        #expect(track.debugCarrying == slot,
                "the piece stayed in slot \(before) while the finger came to be over \(slot)")
        track.debugDrop()
    }

    /// And letting go stops the list, whatever it was doing.
    @Test func lettingGoStopsTheListScrolling() throws {
        let track = cutIntoTwelve()
        _ = try lift(0, on: track)
        track.debugCarry(toTrackX: track.bounds.width - 4)
        #expect(track.debugListIsScrollingByItself, "guard: the list is running")

        track.debugDrop()

        #expect(track.debugListIsScrollingByItself == false, "the list scrolls on after the drop")
        let stopped = track.debugShotListOffset
        track.debugScrollTheList(forSeconds: 0.1)
        #expect(track.debugShotListOffset == stopped, "a beat after the drop still moved the list")
    }

    /// And when the finger goes, the ruler goes back to counting the track — the
    /// same seconds as before, since a new order does not change how long the
    /// result runs.
    @Test func puttingAPieceDownGivesTheRulerBackItsSeconds() async throws {
        let track = cutUnevenly()
        let atRest = track.debugRulerMarks
        let dotsAtRest = track.debugRulerDotCount
        #expect(atRest.count > 3, "guard: the ruler counts seconds at rest, \(atRest)")

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        track.layoutIfNeeded()
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.debugDrop()
        track.layoutIfNeeded()

        #expect(track.debugRulerMarks == atRest,
                "the ruler did not go back to the track: \(track.debugRulerMarks)")
        #expect(track.debugRulerIsFaded, "the ruler's fade did not come back")
        #expect(track.debugRulerDotCount == dotsAtRest, "the half-way dots did not come back")
        try await settle(until: { track.debugShotFrames.isEmpty })
        #expect(track.debugTrackIsShowing, "the track stayed put away")
    }

    /// ⚠️ **PUTTING A PIECE DOWN DOES NOT MOVE THE NEEDLE.** A carry renumbers
    /// the pieces, and the screen knows which one is playing by its number: left
    /// alone, "piece 0 at one second" named the OTHER piece after the drop and the
    /// follow scrolled the track to it — measured as the needle leaping from 0:02
    /// to 0:00. A new order runs exactly as long as the old one, so the track
    /// stays where it is and the preview is sent to what now stands under the
    /// needle.
    @Test func puttingAPieceDownSendsThePreviewToWhatIsNowUnderTheNeedle() throws {
        let track = cutUnevenly()
        track.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forPlayedSeconds: 1, trackWidth: track.bounds.width
        ))
        track.layoutIfNeeded()
        var scrubs: [MediaTimelining.Moment] = []
        track.onScrub = { scrubs.append($0) }
        let offset = track.debugContentOffset
        let before = try #require(track.momentUnderNeedle)
        #expect(before.piece == 0 && abs(before.sourceSeconds - 1) < 0.01,
                "guard: one second into the two-second piece, \(before)")

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        track.layoutIfNeeded()
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        track.debugDrop()
        track.layoutIfNeeded()

        #expect(abs(track.debugContentOffset - offset) < 0.01, "the track moved on the drop")
        let now = try #require(track.momentUnderNeedle)
        #expect(now.piece == 0 && abs(now.sourceSeconds - 3) < 0.01,
                "guard: one second into the six-second piece, which now plays first: \(now)")
        let told = try #require(scrubs.last, "the preview was never told anything")
        #expect(told.piece == now.piece && abs(told.sourceSeconds - now.sourceSeconds) < 0.01,
                "the preview was left on \(told) while the needle stands on \(now)")
    }

    /// ⚠️ **THE CHIP GOES WHERE ITS PIECE GOES.** The list is one chip per piece
    /// in play order; a chip that stayed at the index it was raised at would show
    /// the wrong piece's film from the first crossing onwards, and the author
    /// would be carrying something that is no longer what they picked up.
    @Test func theChipInHandTravelsWithItsPiece() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try splitInTwo(on: screen)

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)
        screen.window.layoutIfNeeded()
        let raised = track.debugShotIdentities
        try #require(raised.count == 2, "guard: the list is up")
        track.debugCarry(toTrackX: track.debugShotFrames[1].midX)
        screen.window.layoutIfNeeded()

        #expect(track.debugCarrying == 1, "guard: the piece did not cross")
        // ⚠️ IDENTITY, NOT AN INDEX — see `debugShotIdentities`. Asked which
        // index is lifted, this test passed with both chips standing still.
        #expect(track.debugShotIdentities == [raised[1], raised[0]],
                "the chips did not change places with their pieces")
        #expect(track.debugShotInHand == 1,
                "the lifted chip stayed behind: \(String(describing: track.debugShotInHand))")
    }

    /// ⚠️ **A PRESS ON A CLIP WITH NOTHING TO RE-ORDER MUST LEAVE THE FILM
    /// ALONE.** A long press that recognises stops the scroller's pan from ever
    /// beginning for that finger, so holding still for a third of a second on an
    /// uncut clip froze the track until the finger came up — a press that can
    /// carry nothing has to refuse the touch instead.
    @Test func apressWithNothingToCarryDoesNotTakeTheTouch() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        screen.window.layoutIfNeeded()

        #expect(track.debugWouldLift(atContentX: 40) == false,
                "an uncut clip has nothing to carry")

        let cut = try splitInTwo(on: screen)
        let pieces = cut.debugPieceFrames
        #expect(cut.debugWouldLift(atContentX: pieces[0].lowerBound + 10),
                "a cut clip's first piece can be carried")
        #expect(cut.debugWouldLift(atContentX: pieces[1].upperBound + 200) == false,
                "there is no piece past the end of the film")
    }

    /// Splits a ten-second clip in two at its middle and hands back the track.
    private func splitInTwo(on screen: Screen) throws -> MediaTimelineTrackView {
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        #expect(MediaTimelining.resolved(track.debugTimeline, withinSource: 10).count == 2,
                "guard: two pieces to carry")
        return track
    }

    /// ⚠️ **THE FILM MUST NOT SCROLL WHILE A PIECE IS BEING CARRIED.** A press
    /// that left the scroller alive would carry the piece and slide the film at
    /// the same time, at different rates, and the piece would land somewhere
    /// nobody aimed at.
    @Test func theTrackDoesNotScrollWhileAPieceIsCarried() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        putTheNeedle(at: 5, on: track, in: screen)
        screen.editor.debugActionBar.debugTap(
            MediaEditorViewController.TrackAction.split.rawValue
        )
        screen.window.layoutIfNeeded()
        #expect(track.debugScrollIsEnabled, "guard: it scrolls at rest")

        track.debugLift(atContentX: track.debugPieceFrames[0].lowerBound + 10)

        #expect(track.debugScrollIsEnabled == false)
        track.debugDrop()
        #expect(track.debugScrollIsEnabled, "the track never got its scroll back")
    }

    /// A clip that has not been cut has nothing to re-order, and a press on it
    /// must not take the film hostage.
    @Test func aSinglePieceIsNotCarried() throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        screen.window.layoutIfNeeded()

        track.debugLift(atContentX: 40)

        #expect(track.debugCarrying == nil)
        #expect(track.debugScrollIsEnabled)
    }

    // MARK: - The film is there when the mode opens

    /// ⚠️ **REPORTED FROM THE DEVICE AS "THE TIMELINE DOES NOT APPEAR WHEN IT
    /// LOADS".** Two asynchronous steps stand between the tap and the first
    /// decoded frame — `PHImageManager` vending the file, then a batch of
    /// exact-time decodes — and until both land every tile is transparent. This
    /// asserts SYNCHRONOUSLY, in the same turn the mode opens, before either one
    /// could possibly have answered.
    @Test func theFilmShowsSomethingInTheSameTurnTheModeOpens() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        // The canvas fetches the page's picture on configure; that is the poster
        // the track borrows, and it has to be in hand first.
        try await settle(until: { screen.editor.debugHasSourcePicture })

        choose(Mode.trim, on: screen)

        let track = try tools(in: screen).track
        #expect(screen.preview.askedFrames == false,
                "guard: no decoded frame can have arrived yet")
        #expect(track.debugFrameCount > 0, "guard: there are tiles to fill")
        #expect(track.debugEveryTileHasAPicture, "the strip opened as a row of holes")
    }

    /// ⚠️ **AND WHERE THERE IS NO PICTURE OF ANY KIND, A BONE RATHER THAN A
    /// HOLE.** The track draws no ground — the canvas runs full-bleed underneath
    /// it — so an empty strip is not an empty strip, it is nothing at all, with a
    /// white selection drawn around it. This is the fallback the poster usually
    /// makes unnecessary.
    @Test func withNoPictureAtAllTheFilmStandsOnASkeleton() {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)

        track.configure(duration: 10, timeline: .whole)
        track.setNeedsLayout()
        track.layoutIfNeeded()

        #expect(track.debugSkeletonIsShowing)
        // ⚠️ THE FILM'S RECTANGLE, NOT THE TRACK'S. At rest the content carries
        // half a track of lead-in (charter F2), so the clip begins under the
        // needle and the leading half of the viewport holds no film at all — a
        // bone spanning the whole width would promise pictures where there will
        // never be any.
        #expect(abs(track.debugSkeletonFrame.minX - track.bounds.midX) < 2,
                "the bone is not where the film is: \(track.debugSkeletonFrame)")
    }

    @Test func aPosterIsEnoughToTakeTheSkeletonAway() {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        track.configure(duration: 10, timeline: .whole)
        track.setNeedsLayout()
        track.layoutIfNeeded()
        #expect(track.debugSkeletonIsShowing, "guard: it was standing on one")

        track.showPoster(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        })
        track.layoutIfNeeded()

        #expect(track.debugSkeletonIsShowing == false)
    }

    /// And the poster is a fact about THIS clip: carrying the previous page's
    /// over would draw the wrong film under the right handles.
    @Test func swipingToAnotherClipDoesNotKeepTheFirstOnesPoster() async throws {
        let screen = open(Self.items(2, videosAt: [0, 1]))
        try await settle(until: { screen.editor.debugHasSourcePicture })
        choose(Mode.trim, on: screen)
        let track = try tools(in: screen).track
        let first = try #require(track.debugPoster, "guard: the first clip lent one")

        screen.editor.debugScrollToPage(1)
        screen.window.layoutIfNeeded()

        #expect(track.debugPoster !== first, "the second clip is wearing the first one's frame")
        // And it does not simply go without: the page's own picture arrives a
        // moment later, and that is the moment the strip is lent it.
        try await settle(until: { track.debugPoster != nil })
        #expect(track.debugPoster != nil, "the second clip never got a poster of its own")
    }
}
