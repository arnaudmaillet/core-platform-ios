import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE TRIM MODE: WHO GETS IT, WHAT IT SHOWS, WHAT SCROLLING IT DOES, AND
/// WHEN A DRAG BECOMES A DECISION.**
///
/// The arithmetic is asked separately in `MediaTimeliningTests` — a pan's
/// translation cannot be set and a scroll view's offset cannot be driven without
/// a window, so everything that could be wrong about clamping, scale and rulers
/// lives in a pure type. What is left here is the screen's part: routing, the
/// notice for a medium this mode cannot serve, what a scroll does to the player,
/// and the moment a value is stored.
@MainActor
struct MediaEditorTimelineTests {
    private enum Mode {
        static let filters = 3
        static let crop = 4
        static let trim = 5
    }

    private struct Screen {
        let editor: MediaEditorViewController
        let window: UIWindow
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

        static func file(for id: MediaLibraryItem.ID) -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("\(id).mov")
        }

        func videoFile(for item: MediaLibraryItem.ID) async -> URL? { Self.file(for: item) }
    }

    /// Nothing here decodes: the track's subject is what the screen ASKS for,
    /// where it puts the answer, and what it tells the player — not whether
    /// AVFoundation can read a file.
    private final class StubPreview: MediaVideoPreviewing {
        /// Every arrangement the screen asked to be played, and where each was
        /// asked to begin.
        private(set) var plans: [VideoExportPlan] = []
        private(set) var starts: [Double] = []
        /// ⚠️ **`at()` IS ASKED, AS THE REAL CONTROLLER ASKS IT**, and a load it
        /// abandons records nothing.
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

        /// Every FILE second the screen showed the file as shot at — a held
        /// handle aiming.
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
        /// What the stub player says about being stopped. Tests that care set
        /// it; nil is "nothing is bound", which is neither playing nor paused.
        var paused: Bool? = false

        func isPaused(in surface: VideoRenderView) -> Bool? { paused }

        func isBound(_ surface: VideoRenderView) -> Bool { false }

        private(set) var asked: [(file: URL, count: Int)] = []
        /// Every moment of film the track has asked for — charter T2.
        private(set) var askedSeconds: [Double] = []
        private(set) var seeks: [Double] = []
        private(set) var pauses: [Bool] = []

        func setPaused(_ paused: Bool, in surface: VideoRenderView) {
            pauses.append(paused)
        }

        /// The tolerance each seek was asked with — charter T7.
        private(set) var seekTolerances: [Double] = []

        /// Every seek, in seconds of the ITEM the stub is pretending to play.
        func seek(
            toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double
        ) {
            seeks.append(seconds)
            seekTolerances.append(toleranceSeconds)
        }

        /// Where the stub player claims to be. Nil is the ordinary answer —
        /// nothing is bound in a test, and that is exactly what the follower
        /// finds on the first frames after a real page settles. Tests that care
        /// about the handover set it.
        var headSeconds: Double?

        func playheadSeconds(in surface: VideoRenderView) -> Double? { headSeconds }

        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] {
            asked.append((file, seconds.count))
            askedSeconds.append(contentsOf: seconds)
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                    UIColor.green.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                }
            return Dictionary(uniqueKeysWithValues: seconds.map { ($0, swatch) })
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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.isHidden = false
        window.layoutIfNeeded()
        // ⚠️ **APPEARING IS WHAT STARTS A CLIP, AND WITHOUT IT NOTHING SCRUBS.**
        // Playback begins on the settled page once the screen appears, so a test
        // that only laid the window out had no player to seek — and every
        // assertion about scrubbing passed through a `guard` into silence rather
        // than failing. `MediaEditorPlaybackTests` does the same two calls for
        // the same reason.
        editor.beginAppearanceTransition(true, animated: false)
        editor.endAppearanceTransition()
        window.layoutIfNeeded()
        return Screen(editor: editor, window: window, preview: preview, handed: handed)
    }

    private func choose(_ mode: Int, on screen: Screen) {
        screen.editor.debugCategoryBar.select(mode)
        screen.window.layoutIfNeeded()
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<3000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for the track to ask for film AND for the preview's first load to
    /// land.
    ///
    /// ⚠️ **THE FOLLOWER AND THE SCRUB BOTH REFUSE A PLAYER WHOSE ITEM THE SCREEN
    /// HAS NOT HEARD LAND**, so a test that drives either before the load lands
    /// passes through a `guard` into silence. `settle` returns quietly when it
    /// runs out of time; the `#require`s are what make that a failure.
    private func ready(_ screen: Screen) async throws {
        try await settle(until: {
            !screen.preview.asked.isEmpty && !screen.preview.plans.isEmpty
                && !screen.editor.debugPreviewIsPending
        })
        try #require(!screen.preview.asked.isEmpty, "the track never asked for film")
        try #require(!screen.preview.plans.isEmpty, "the preview was never loaded")
        try #require(!screen.editor.debugPreviewIsPending, "the preview's load never landed")
    }

    /// Waits for a load newer than the `count` already seen to land.
    private func landed(_ screen: Screen, beyond count: Int) async throws {
        try await settle(until: {
            screen.preview.plans.count > count && !screen.editor.debugPreviewIsPending
        })
        try #require(screen.preview.plans.count > count, "no new arrangement reached the preview")
        try #require(!screen.editor.debugPreviewIsPending, "the new arrangement never landed")
    }

    /// ⚠️ **THE BAND'S TENANT IS THE HOST, AND THE TRACK IS INSIDE IT.** The
    /// rate chips stand above the film when the speedometer is lit, so the
    /// timeline arrives in the band as one view holding two.
    private func tools(in screen: Screen) throws -> MediaTimelineToolsView {
        try #require(screen.editor.debugBand.content as? MediaTimelineToolsView)
    }

    private func track(in screen: Screen) throws -> MediaTimelineTrackView {
        try tools(in: screen).track
    }

    /// Takes hold of a piece, which is what a finger does before it can drag an
    /// edge.
    ///
    /// ⚠️ **NOTHING IS SELECTED AT REST ANY MORE, AND EVERY DRAG TEST NOW SAYS
    /// SO.** The track used to draw its frame around the whole timeline whether
    /// or not the author had touched it, so a test could grab a handle out of
    /// nowhere. Selecting first is not test scaffolding: it is the gesture.
    private func hold(_ track: MediaTimelineTrackView, piece: Int = 0) {
        track.select(piece)
        track.setNeedsLayout()
        track.layoutIfNeeded()
    }

    // MARK: - Who gets the mode

    @Test func choosingTrimOnAVideoPutsTheTrackInTheBand() throws {
        let screen = open(Self.items(2, videosAt: [0]))

        choose(Mode.trim, on: screen)

        #expect(screen.editor.debugBand.content is MediaTimelineToolsView,
                "got \(String(describing: screen.editor.debugBand.content))")
    }

    /// ⚠️ **THE MIRROR OF THE OTHER TWO NOTICES, AND THE WITNESS FOR THE LINE
    /// ABOVE.** Crop and Filters refuse a video; Trim refuses a photograph. A
    /// mode that cannot serve the medium in front of the author says so rather
    /// than offering a control that reaches nothing — which is the defect this
    /// whole run of work has been removing.
    @Test func choosingTrimOnAPhotographSaysWhyThereIsNothingToDo() throws {
        let screen = open(Self.items(2, videosAt: [1]))

        choose(Mode.trim, on: screen)

        // ⚠️ **THE TEXT, NOT JUST THE TYPE.** `BandNoticeView` is also what Crop
        // and Filters install when they refuse a video; asserting only "a notice
        // is up" would pass if Trim silently fell through to another mode's
        // message. The word has to be about trimming.
        let notice = try #require(screen.editor.debugBand.content as? BandNoticeView)
        #expect(notice.debugText?.lowercased().contains("trim") == true,
                "got \(notice.debugText ?? "nil")")
    }

    // MARK: - What it shows

    @Test func theTrackAsksForFramesOfTheClipOnThisPage() async throws {
        let screen = open(Self.items(2, videosAt: [0]))

        choose(Mode.trim, on: screen)
        try await ready(screen)

        #expect(screen.preview.asked.first?.file == StubLibrary.file(for: "video-0"))
        #expect((screen.preview.asked.first?.count ?? 0) > 1,
                "a strip of one frame is not a strip")
    }

    @Test func theFramesLandInTheTrack() async throws {
        let screen = open(Self.items(2, videosAt: [0]))

        choose(Mode.trim, on: screen)
        try await settle(until: { (try? track(in: screen).debugFrameCount) ?? 0 > 0 })

        #expect(try track(in: screen).debugFrameCount > 1)
    }

    /// ⚠️ **CHARTER T2, ASKED OF THE SCREEN.** The arithmetic suite proves the
    /// window is bounded; this proves the track USES it — that a four-minute clip
    /// does not quietly decode itself end to end on the way in. The predecessor
    /// fitted a fixed count of thumbnails across the whole clip, so the cost was
    /// the same wherever the author was looking, and a longer clip merely got
    /// wider, blurrier cells.
    @Test func aLongClipOnlyDecodesTheFilmYouCanSee() async throws {
        let fourMinutes = MediaLibraryItem(id: "video-0", kind: .video(duration: 240))
        let screen = open([fourMinutes])

        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.askedSeconds.isEmpty == false })
        screen.window.layoutIfNeeded()
        try await settle(until: { (try? track(in: screen).debugFrameCount) ?? 0 > 4 })

        let asked = Set(screen.preview.askedSeconds)
        #expect(asked.count <= 48, "decoded \(asked.count) frames for one band")
        // And it really is a long clip, so the bound above is not trivially met.
        let squares = MediaTimelining.squares(
            in: .whole, withinSource: 240,
            visible: 0...MediaTimelining.contentWidth(of: .whole, withinSource: 240)
        ).count
        #expect(squares > 200, "guard: the clip is \(squares) squares long")
        #expect(asked.allSatisfy { $0 < 60 },
                "it asked for film far past the opening screenful: \(asked.sorted().suffix(3))")
    }

    /// ⚠️ **CHARTER F14: NO EMPTY BOXES.** Until a tile's own frame arrives it
    /// shows the nearest one already decoded, so a strip scrolled into reads as a
    /// blurred film rather than a row of holes.
    @Test func everyTileOnScreenIsShowingSomething() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.askedSeconds.isEmpty == false })
        screen.window.layoutIfNeeded()
        let bar = try track(in: screen)
        try await settle(until: { bar.debugEveryTileHasAPicture })

        // Scroll somewhere nothing has been decoded for, and look immediately.
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 9, trackWidth: bar.bounds.width
        ))

        #expect(bar.debugFrameCount > 0, "guard: there are tiles to look at")
        #expect(bar.debugEveryTileHasAPicture,
                "\(bar.debugTileIndices.count) tiles and some are empty")
    }

    // MARK: - Settling onto another page

    /// ⚠️ **THE HIGH-SEVERITY DEFECT A REVIEW FOUND, AND THE TEST THAT WOULD
    /// HAVE CAUGHT IT.** `refreshTimelineTrack` was reachable only from the category
    /// bar, so paging with Trim open left the strip holding the PREVIOUS clip's
    /// frames, duration and handles while `onChange` read `currentItemID` live.
    /// A drag then stored one clip's seconds under another clip's id — measured
    /// at the time: a 60pt drag on a 52-second clip, after settling onto a
    /// four-second one, stored `start: 8.0` against the short clip, which then
    /// published its last second.
    ///
    /// `cuttingOneClipLeavesTheOtherPagesAlone` only LOOKED like it covered
    /// this: it never paged, so it could not see the bug. `debugScrollToPage`
    /// existed and was used by the playback suite.
    @Test func settlingOnAnotherClipRetargetsTheTrack() async throws {
        let screen = open(Self.items(2, videosAt: [0, 1]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        #expect(screen.preview.asked.count == 1, "guard: one clip has been asked for")

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.asked.count > 1 })

        // ⚠️ **`contains`, NOT `last` — AND `last` WAS RIGHT UNTIL THE STRIP WENT
        // LAZY.** One fetch per clip made the newest request the newest answer.
        // Tiles are asked for per visible window and answered asynchronously, so
        // a request issued for the outgoing clip can still land after one for the
        // incoming one; `last` then names whichever finished second. It
        // discriminates just as well: with the settle refresh gone, the new clip
        // is never asked for at all.
        #expect(screen.preview.asked.contains { $0.file == StubLibrary.file(for: "video-1") },
                "the strip still holds the previous clip: \(screen.preview.asked)")
    }

    /// ⚠️ **AND THE OUTGOING CLIP'S PROVIDER GOES AT ONCE, WHICH IS THE HALF
    /// THAT WENT WRONG.** The provider is a closure over ONE file, and its
    /// replacement is installed two awaits later. Anything that lays the track
    /// out in that gap — a toolbar pass, a poster landing, a run-loop turn — asks
    /// the OLD closure for the NEW clip's tiles; it answers empty (it guards on
    /// the id it captured), the tiles are marked as asked for and then retired
    /// with nothing, and unless something lays the track out again afterwards the
    /// new provider is never asked for anything at all. That is what the test
    /// above saw: the incoming clip was never requested.
    ///
    /// ⚠️ **AND THE OBVIOUS ASSERTION HERE CANNOT FAIL.** "The old file was not
    /// asked for the new clip's frames" passes with the defect in place, because
    /// the stale closure refuses by id before it ever reaches the library — it
    /// costs a request that never happens. What discriminates is the provider
    /// itself: between two clips there must not be one.
    @Test func theTrackDoesNotHoldTheOutgoingClipsProvider() async throws {
        let screen = open(Self.items(2, videosAt: [0, 1]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let strip = try track(in: screen)
        #expect(strip.debugHasFramesProvider, "guard: the first clip gave it one")

        screen.editor.debugScrollToPage(1)

        #expect(strip.debugHasFramesProvider == false,
                "it is still holding the previous clip's file")
        try await settle(until: { strip.debugHasFramesProvider })
        #expect(strip.debugHasFramesProvider, "and the new clip never gave it one")
    }

    /// ⚠️ **THE SECONDS, NOT THE ID — AND ASKING FOR THE ID PROVES NOTHING.**
    /// This first asserted that the cut landed on the settled clip and not the
    /// one behind, which is true EVEN WITH THE DEFECT: `onChange` reads
    /// `currentItemID` live, so the id was always right. What was wrong was the
    /// arithmetic — the drag was resolved against the STALE clip's duration.
    ///
    /// ⚠️ **AND THE OLD DISCRIMINATOR STOPPED DISCRIMINATING WHEN THE TRACK
    /// ARRIVED.** The strip mapped points to seconds through the clip's length,
    /// so the same 60pt drag was worth 0.62s on a four-second clip and 6.15s on a
    /// forty-second one, and asserting the start caught a stale duration. The
    /// track's scale is ABSOLUTE — 60pt is one second on every clip — so that
    /// assertion now passes either way. What still cannot lie is the END: a
    /// timeline resolved against the settled clip ends at 4, one resolved against
    /// the clip behind ends at 40. The drag is made large enough that the start
    /// is clamped by the short clip's length too, which is a second witness.
    @Test func aDragAfterASettleIsResolvedAgainstTheSettledClip() async throws {
        let long = MediaLibraryItem(id: "video-long", kind: .video(duration: 40))
        let short = MediaLibraryItem(id: "video-short", kind: .video(duration: 4))
        let screen = open([long, short])
        choose(Mode.trim, on: screen)
        try await ready(screen)
        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.asked.count > 1 })

        let bar = try track(in: screen)
        hold(bar)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 600)   // ten seconds at the track's scale
        bar.debugRelease()

        screen.editor.debugTapNext()
        let carried = try #require(screen.handed.edits?["video-short"])
        let piece = try #require(carried.timeline.segments.first)
        #expect(abs(piece.end - 4) < 0.001,
                "resolved against the clip behind, which runs 40: \(piece)")
        #expect(abs(piece.start - 3) < 0.001,
                "ten seconds into a four-second clip should stop one second from its end: \(piece)")
        #expect(screen.handed.edits?["video-long"] == nil, "and the one behind is untouched")
    }

    /// The mirror: settling from a video onto a photograph must swap the strip
    /// for the notice, or the photograph collects a `trim` it never earned —
    /// which also moves its `MediaEdits.signature`, and therefore its thumbnail
    /// cache key.
    @Test func settlingOntoAPhotographSwapsTheTrackForTheNotice() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        #expect(screen.editor.debugBand.content is MediaTimelineToolsView, "guard: the strip is up")

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.editor.debugBand.content is BandNoticeView })

        #expect(screen.editor.debugBand.content is BandNoticeView,
                "got \(String(describing: screen.editor.debugBand.content))")
    }

    // MARK: - A clip too short to cut

    /// ⚠️ **HANDLES THAT CANNOT MOVE ARE WORSE THAN NO HANDLES.**
    /// `MediaTimelining` will not leave less than `shortestSourceSeconds` behind, so on
    /// a clip already at that floor every drag resolves straight back. The strip
    /// looked operable and was inert — the same shape of lie as a control that
    /// reaches nothing, failing one step earlier.
    @Test func aClipTooShortToCutSaysSoInsteadOfOfferingDeadHandles() async throws {
        let stub = MediaLibraryItem(id: "video-0", kind: .video(duration: 0.5))
        let screen = open([stub])

        choose(Mode.trim, on: screen)
        try await settle(until: { screen.editor.debugBand.content is BandNoticeView })

        let notice = try #require(screen.editor.debugBand.content as? BandNoticeView)
        #expect(notice.debugText?.lowercased().contains("short") == true,
                "got \(notice.debugText ?? "nil")")
    }

    /// The witness: a clip with room to cut gets the strip, so the notice above
    /// is about the length and not about the mode being broken.
    @Test func aClipWithRoomToCutGetsTheTrack() async throws {
        let screen = open(Self.items(1, videosAt: [0]))

        choose(Mode.trim, on: screen)
        try await ready(screen)

        #expect(screen.editor.debugBand.content is MediaTimelineToolsView)
    }

    // MARK: - VoiceOver

    /// ⚠️ **`.adjustable` IS A PROMISE.** The trait tells VoiceOver the control
    /// can be changed by swiping up or down, which calls
    /// `accessibilityIncrement`/`Decrement`. Declaring it without implementing
    /// them announces an affordance that does nothing — worse than a plain
    /// label, because the viewer is told it is there.
    @Test func voiceOverCanActuallyMoveTheCut() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        let before = bar.debugTimeline

        bar.accessibilityDecrement()

        #expect(bar.debugTimeline != before, "the trait is declared and does nothing")
        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["video-0"] != nil,
                "and a spoken adjustment is a decision — there is no release to wait for")
    }

    @Test func voiceOverAnnouncesWhatIsKept() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        #expect(bar.accessibilityValue?.isEmpty == false, "got \(bar.accessibilityValue ?? "nil")")
    }

    // MARK: - A late arrival must not move the handle

    /// ⚠️ **THE FRAMES ARRIVE WHENEVER THEY ARRIVE.** A file read plus a dozen
    /// exact-time decodes takes long enough for the author to start dragging,
    /// and the landing used to carry a `trim` alongside the pictures and assign
    /// it — silently resetting the handle to whatever was stored. The pictures
    /// are decoration; the value being edited is not theirs to set.
    @Test func framesLandingMidDragDoNotMoveTheHandle() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)

        hold(bar)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 80)
        let midDrag = bar.debugTimeline

        // Exactly what the async landing does, at the worst possible moment.
        bar.configure(duration: 10, timeline: .whole)

        #expect(bar.debugTimeline == midDrag, "the landing moved the handle: \(bar.debugTimeline)")
    }

    // MARK: - When a drag becomes a decision

    /// ⚠️ **ON RELEASE, NOT DURING THE DRAG** — `MediaCropSurfaceView`'s rule,
    /// for its reason: a value sampled mid-gesture is not a decision, and storing
    /// one would write an entry into `edits` for every frame of a drag the author
    /// has not finished.
    @Test func aDragStoresNothingUntilTheFingerLifts() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)

        hold(bar)
        bar.debugTakeHold(at: 0)
        #expect(bar.debugHasGrip, "guard: the start handle was taken")
        bar.debugDrag(byPoints: 60)

        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["video-0"] == nil, "nothing is stored mid-drag")
    }

    @Test func releasingAHandleStoresTheTimelineAndCarriesIt() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)

        hold(bar)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()

        screen.editor.debugTapNext()
        let carried = try #require(screen.handed.edits?["video-0"])
        #expect(carried.timeline.isWhole == false, "got \(carried.timeline)")
        #expect(try #require(carried.timeline.segments.first).start > 0,
                "the start moved in: \(carried.timeline)")
    }

    /// A photograph on another page is untouched by a trim made here — `edits`
    /// is keyed by item and the strip only ever writes the settled one.
    @Test func cuttingOneClipLeavesTheOtherPagesAlone() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)

        hold(bar)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()

        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["photo-1"] == nil)
    }

    /// ⚠️ **THE CAP TRAVELS WITH THE FINGER, AND THE TRACK SCROLLS TO PAY FOR
    /// IT.** A piece begins where the pieces before it end, so dragging its start
    /// shortens it from the INSIDE: the cap would stand still and the other end
    /// would move, which is exactly what was reported — *"quand on grab la
    /// fenetre de selection depuis le bord gauche, ca deplace le bord droit de la
    /// selection au lieu du bord gauche"*. The track shifts under the finger by
    /// what the piece gave up, and for the FIRST piece that needs room the
    /// scroller does not have at rest: the leading inset grows for the length of
    /// the gesture.
    @Test func trimmingAHeadCarriesTheCapWithTheFinger() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        let whole = bar.debugContentWidth
        hold(bar)
        let held = try #require(bar.debugSelectedRangeX)
        // Where the cap is ON SCREEN: content x minus where the film is scrolled.
        let onScreen = held.lowerBound - bar.debugContentOffset

        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)           // one second off the head

        // ⚠️ **MEASURED WHILE THE FINGER IS STILL DOWN.** The slack is the
        // gesture's: on release the track settles back onto the composition and
        // the preview takes the needle to the frame the edge came to rest on, so
        // an assertion after the lift would be asking about the settle instead.
        #expect(abs(bar.debugContentWidth - (whole - 60)) < 2,
                "the result did not get a second shorter: \(bar.debugContentWidth) of \(whole)")
        let after = try #require(bar.debugSelectedRangeX)
        #expect(abs(after.lowerBound) < 0.01,
                "the first piece no longer begins at the origin of the result: \(after)")
        #expect(abs((after.lowerBound - bar.debugContentOffset) - (onScreen + 60)) < 1,
                "the cap did not follow the finger: \(onScreen) then \(after.lowerBound - bar.debugContentOffset)")

        bar.debugRelease()
    }

    // MARK: - The selection frames the film

    /// ⚠️ **A TENANT THAT UNDER-DECLARES ITS HEIGHT LOSES WHATEVER HANGS BELOW.**
    /// The selection stands one rail proud of the film at the top and one at the
    /// bottom; the track's height did not count them, so the bottom rail was laid
    /// out past the container and clipped. Seen on the device as a selection with
    /// three sides.
    @Test func theTrackIsTallEnoughForTheFrameItDraws() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        #expect(bar.debugBottomRail.maxY <= bar.bounds.height + 0.01,
                "the bottom rail is at \(bar.debugBottomRail.maxY) in a track \(bar.bounds.height) tall")
        #expect(bar.debugTopRail.minY >= -0.01, "the top rail is above the track")
        #expect(bar.debugStartGrip.maxY <= bar.bounds.height + 0.01,
                "the caps are clipped at the foot")
    }

    /// ⚠️ **THE RAILS USED TO RUN PAST THE ROUNDED CAPS.** Drawn the obvious way
    /// — rails spanning the whole selection, caps laid on top — a straight rail
    /// carries on past the cap's curve and shows as a hair of white sticking out
    /// at all four corners. Reported from the device as the borders overshooting
    /// at the ends. The caps own the corners, the rails own the span between
    /// them, and the outside is one rounded rectangle.
    @Test func theSelectionClosesIntoOneFrameWithNothingSticking() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        hold(bar)
        screen.window.layoutIfNeeded()

        let top = bar.debugTopRail
        let bottom = bar.debugBottomRail
        let start = bar.debugStartGrip
        let end = bar.debugEndGrip
        #expect(start.width > 0 && end.width > 0, "guard: there are caps to frame with")

        // ⚠️ **THE RULE IS THE OUTER EDGE, NOT THE INNER ONE.** The rails tuck
        // UNDER the caps — two white rectangles butted exactly against each other
        // leave a hairline wherever rounding lands them half a pixel apart, and
        // the caps are drawn after and are opaque. What must never happen is a
        // rail reaching past a cap's outer edge, where the cap has curved away
        // and the straight rail shows as a hair of white beyond the corner.
        #expect(top.minX >= start.minX - 0.01, "the top rail sticks out past the leading corner")
        #expect(top.maxX <= end.maxX + 0.01, "the top rail sticks out past the trailing corner")
        #expect(bottom.minX >= start.minX - 0.01, "the bottom rail sticks out past the leading corner")
        #expect(bottom.maxX <= end.maxX + 0.01, "the bottom rail sticks out past the trailing corner")
        #expect(top.minX < start.maxX, "the rail is butted against the cap rather than tucked under it")

        // ⚠️ **AND THE CAPS STAND OUTSIDE THE CUT.** Laid over the film they eat
        // twelve points of picture at each end — and those are the twelve the
        // author is aiming with, the frames right at the edge of the decision
        // being made. The kept film must be visible end to end.
        let kept = try #require(bar.debugSelectedRangeX)
        #expect(start.maxX <= kept.lowerBound + 0.01,
                "the leading cap covers the first \(start.maxX - kept.lowerBound)pt of the cut")
        #expect(end.minX >= kept.upperBound - 0.01,
                "the trailing cap covers the last \(kept.upperBound - end.minX)pt of the cut")

        // And the caps stand proud of the film by exactly one rail at each end,
        // so the frame's outside is flush all the way round.
        let film = bar.debugFilmFrame
        #expect(abs(start.minY - (film.minY - top.height)) < 0.01,
                "the cap does not reach the top rail: \(start) against \(film)")
        #expect(abs(start.maxY - (film.maxY + bottom.height)) < 0.01,
                "the cap does not reach the bottom rail: \(start) against \(film)")
        // ⚠️ And the outside is rounded no further than a cap this narrow draws
        // cleanly — Core Animation does not clamp.
        #expect(bar.debugCapShapes.first?.radius == MediaTimelineTrackView.debugCapCorner,
                "the caps are rounded to \(String(describing: bar.debugCapShapes.first?.radius))")
        #expect(abs(top.minY - start.minY) < 0.01, "the rail and the cap start at different heights")
    }

    /// ⚠️ **THE GLYPH IS BOUND TO THE PLAYER, NOT SET AT THE MOMENTS WE HAPPEN TO
    /// KNOW ABOUT.** It was updated on a tap, on a scrub and on a settle, which
    /// leaves it stale for everything else that stops a clip — reaching the end,
    /// an interruption, a stall. A button showing "pause" over a stopped clip is
    /// a control that lies about the thing it controls.
    @Test func theGlyphFollowsAPlayerThatStoppedOnItsOwn() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.preview.paused = false
        screen.preview.headSeconds = 5
        screen.editor.debugFollowTick()
        #expect(bar.debugShowsPause, "guard: a running clip offers to pause")

        // The clip reaches its end. Nobody tapped anything.
        screen.preview.paused = true
        screen.editor.debugFollowTick()

        #expect(bar.debugShowsPause == false,
                "the button still offers to pause a clip that has stopped")
    }

    /// ⚠️ **A RELEASED CUT IS WHAT THE PREVIEW PLAYS, AS ONE ITEM.** The preview
    /// used to run the whole file and seek it back at the end of the cut — a
    /// turn the author saw every loop. Now the cut IS the item: there is nothing
    /// past its end for the player to run into, so the end asks nothing.
    @Test func aReleasedCutIsWhatThePreviewPlays() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        #expect(screen.preview.plans.last?.segments == [],
                "guard: an untouched clip plays the file as shot")
        let loads = screen.preview.plans.count

        // Cut the head off: keep from ~3s to the end of a ten-second clip.
        hold(bar)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 180)
        bar.debugRelease()
        try await landed(screen, beyond: loads)

        let plan = try #require(screen.preview.plans.last)
        #expect(plan.segments.count == 1, "the item plays \(plan.segments)")
        let kept = try #require(plan.segments.first)
        #expect(abs(kept.start - 3) < 0.2 && abs(kept.end - 10) < 0.01,
                "the item plays \(kept.start)–\(kept.end)s of the file")
        // ⚠️ **AND IT LANDS UNDER THE NEEDLE**, in the played seconds of the new
        // arrangement — not at zero, and not at the source second the handle
        // left the canvas on.
        let start = try #require(screen.preview.starts.last)
        #expect(abs(start - bar.playedSecondsUnderNeedle) < 0.01,
                "it landed at \(start)s with the needle at \(bar.playedSecondsUnderNeedle)s")

        screen.preview.paused = false
        screen.preview.headSeconds = start
        screen.editor.debugFollowTick()
        #expect(screen.editor.debugHandover == .settled, "guard: the track has the player back")
        let seeksBefore = screen.preview.seeks.count

        screen.preview.headSeconds = kept.end - kept.start
        screen.editor.debugFollowTick()

        #expect(screen.preview.seeks.count == seeksBefore,
                "the end of the cut was seeked: \(screen.preview.seeks.suffix(1))")
        #expect(abs(bar.playedSecondsUnderNeedle - (kept.end - kept.start)) < 0.05,
                "guard: the needle followed to the end: \(bar.playedSecondsUnderNeedle)s")
    }

    /// ⚠️ **A SEAM BETWEEN TWO PIECES IS NOT A SEEK.** The follower used to jump
    /// the file to the next piece's start as the playhead reached the end of the
    /// one before — after a re-order, a jump across the file at every seam,
    /// reported as "une mini pause/glitch" between the clips. The item carries
    /// the pieces end to end; the needle crosses the seam and nothing is asked.
    @Test func aPieceBoundaryIsNotASeek() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // Cut at five seconds, then pull the second piece's head to seven: the
        // result runs 0–5 then 7–10, and the two seconds between are gone.
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forPlayedSeconds: 5, trackWidth: bar.bounds.width
        ))
        screen.editor.debugSplitAtTheNeedle()
        let loads = screen.preview.plans.count
        hold(bar, piece: 1)
        let second = try #require(bar.debugSelectedRangeX)
        bar.debugTakeHold(at: second.lowerBound)
        bar.debugDrag(byPoints: 120)
        bar.debugRelease()
        try await landed(screen, beyond: loads)

        let plan = try #require(screen.preview.plans.last)
        #expect(plan.segments.count == 2, "the item plays \(plan.segments)")
        #expect(abs((plan.segments.last?.start ?? 0) - 7) < 0.2,
                "the second piece starts at \(plan.segments.last?.start ?? -1)s of the file")

        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forPlayedSeconds: 2, trackWidth: bar.bounds.width
        ))
        screen.editor.debugEndScrub()
        screen.preview.paused = false
        screen.preview.headSeconds = 2
        screen.editor.debugFollowTick()
        #expect(screen.editor.debugHandover == .settled, "guard: the track has the player back")
        let seeksBefore = screen.preview.seeks.count

        // Half a second into the second piece, which is 7.5s of the file.
        screen.preview.headSeconds = 5.5
        screen.editor.debugFollowTick()

        #expect(screen.preview.seeks.count == seeksBefore,
                "the seam was seeked: \(screen.preview.seeks.suffix(1))")
        #expect(abs(bar.playedSecondsUnderNeedle - 5.5) < 0.05,
                "the needle did not cross the seam: \(bar.playedSecondsUnderNeedle)s")
        #expect(abs(bar.debugSecondsUnderNeedle - 7.5) < 0.2,
                "the film under the needle is \(bar.debugSecondsUnderNeedle)s, not the second piece's")
    }

    /// The witness: inside the cut, nothing is asked of the player at all — a
    /// loop that fired every beat would seek the clip to a standstill.
    @Test func playbackInsideTheCutIsLeftAlone() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        screen.window.layoutIfNeeded()
        let seeksBefore = screen.preview.seeks.count

        screen.preview.paused = false
        screen.preview.headSeconds = 5
        screen.editor.debugFollowTick()
        screen.editor.debugFollowTick()

        #expect(screen.preview.seeks.count == seeksBefore,
                "the middle of the clip was seeked \(screen.preview.seeks.count - seeksBefore) times")
    }

    /// ⚠️ **AND THE REACH MUST SURVIVE A ZOOM.** The leading cap's position was
    /// computed at the DEFAULT scale while the trailing one used the track's own,
    /// so the two agreed exactly until the first pinch — after which the start
    /// handle's hit area sat somewhere the start handle was not.
    @Test func theHandlesStayGrabbableAfterAZoom() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // ⚠️ **THE HEAD IS CUT FIRST, AND WITHOUT THAT THIS PROVES NOTHING.**
        // With the whole clip kept, the leading cap sits at source-second ZERO —
        // and zero is zero at every scale, so a cap placed with the WRONG
        // `pointsPerSecond` lands in exactly the right spot. Measured: breaking
        // it turned no test red until the cut moved off the start.
        hold(bar)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 180)          // three seconds in
        bar.debugRelease()
        bar.debugPinch(by: 3)
        let centres = try #require(bar.debugHandleCentres)

        // ⚠️ **THE FIRST PIECE BEGINS AT THE ORIGIN OF THE RESULT, WHATEVER WAS
        // TRIMMED OFF ITS HEAD** — the track is the composition, so the film
        // before the cut is not on it. What a zoom must not do is leave the two
        // caps at different scales, which is what the reach below asks.
        let expected: CGFloat = 0
        #expect(abs(centres.start - (expected - 6)) < 1,
                "the leading cap is at \(centres.start), the cut at \(expected)")
        #expect(bar.debugWouldTakeAHandle(at: centres.start), "the leading cap is unreachable")
        #expect(bar.debugWouldTakeAHandle(at: centres.end), "the trailing cap is unreachable")
        // Seven seconds left of a ten-second clip, drawn at three times the
        // scale: the trailing cap is far past where it was.
        #expect(centres.end > 1200,
                "guard: the zoom really moved the trailing cap: \(centres.end)")
    }

    /// ⚠️ **THE FILM EASES INTO A JUMP AND STEPS THROUGH PLAYBACK.** Reported
    /// from the device as the timeline moving abruptly when the grips change the
    /// selection: letting go of a handle leaves the player somewhere else, and
    /// the next beat of the follower put the film there in one frame.
    @Test func aBigMoveOfTheFilmIsEasedRatherThanSnapped() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        let before = bar.debugContentOffset

        bar.follow(MediaTimelining.Moment(piece: 0, sourceSeconds: 7))

        #expect(bar.debugIsEasing, "the film was moved in one frame")
        // ⚠️ **ASKED OF THE LAYER, NOT OF `contentOffset`.** `UIView.animate` sets
        // the model value immediately and animates the presentation — so reading
        // the offset back says where the film is GOING and never whether it is
        // easing there. Measured: it reports the full 420pt jump while the
        // animation is still running. `uiview-animate-from-value-trap` records
        // the same lesson about `alpha`.
        #expect(bar.debugScrollIsAnimating, "there is no animation on the layer at all")
        #expect(before != bar.debugContentOffset, "guard: it is going somewhere")
    }

    /// The witness: a beat of ordinary playback is NOT eased. Easing every move
    /// would lay a quarter-second animation over motion that is already smooth,
    /// and the film would swim.
    @Test func aBeatOfPlaybackMovesTheFilmAtOnce() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        bar.follow(MediaTimelining.Moment(piece: 0, sourceSeconds: 0.1))

        #expect(bar.debugIsEasing == false, "a one-point step was animated")
        #expect(abs(bar.debugSecondsUnderNeedle - 0.1) < 0.02,
                "the step did not land: \(bar.debugSecondsUnderNeedle)")
    }

    /// ⚠️ **A BATCH IN FLIGHT HAS ALREADY CAPTURED ITS TILE INDICES.** Clearing
    /// the caches does not stop it — when it lands it writes those indices back,
    /// into a strip now showing a DIFFERENT clip, or the same clip at a scale
    /// where an index means a different moment. The pictures then stay until the
    /// cache evicts them, which on a short clip is never.
    @Test func framesAskedForOneFilmNeverLandInAnother() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        try await settle(until: { bar.debugDecodedCount > 0 })
        let generation = bar.debugFramesGeneration

        bar.forgetFrames()

        #expect(bar.debugFramesGeneration != generation,
                "nothing tells a batch in flight that the film it was asked for is gone")
        #expect(bar.debugDecodedCount == 0, "guard: the caches were dropped")
    }

    /// And a pinch bumps it too — the caches are dropped there for the same
    /// reason, and dropping them without the token leaves the same race.
    @Test func aPinchAlsoRetiresTheFramesInFlight() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        let generation = bar.debugFramesGeneration

        bar.debugPinch(by: 2)

        #expect(bar.debugFramesGeneration != generation,
                "a zoom left the batch in flight believing its indices still mean something")
    }

    /// ⚠️ **CHARTER T3, WHICH NOTHING WAS READING.** `debugDecodedCount` existed
    /// and no test asked it, so the bound on pictures alive at once — the whole
    /// reason the strip is lazy — rested on a constant nobody checked.
    @Test func thePicturesAliveAtOnceStayBounded() async throws {
        let fourMinutes = MediaLibraryItem(id: "video-0", kind: .video(duration: 240))
        let screen = open([fourMinutes])
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // Walk the length of the film, which is what fills a cache that has no
        // ceiling: every window decoded and never given back.
        for second in stride(from: 0.0, through: 220.0, by: 8.0) {
            bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: second, trackWidth: bar.bounds.width
            ))
            try await Task.sleep(for: .milliseconds(4))
        }

        #expect(bar.debugDecodedCount <= 48,
                "\(bar.debugDecodedCount) pictures alive after walking a four-minute clip")
        #expect(bar.debugDecodedCount > 0, "guard: the strip decoded anything at all")
    }

    // MARK: - The strip follows the edit

    /// Hands back a different object for every second of film, and remembers
    /// which is which — so a test can ask what a square is SHOWING.
    @MainActor
    private final class Film {
        private var bySecond: [Double: UIImage] = [:]
        private var second: [ObjectIdentifier: Double] = [:]

        func picture(for at: Double) -> UIImage {
            if let had = bySecond[at] { return had }
            let made = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
            bySecond[at] = made
            second[ObjectIdentifier(made)] = at
            return made
        }

        /// Every square of the strip: which section it belongs to, where it is
        /// drawn, and the second of film in it.
        func showing(_ track: MediaTimelineTrackView) -> [(piece: Int, x: CGFloat, seconds: Double)] {
            track.debugFilm.compactMap { square in
                guard let picture = square.picture, let at = second[ObjectIdentifier(picture)]
                else { return nil }
                return (square.piece, square.from, at)
            }
        }

        /// Where the square showing this exact second of film is drawn.
        func drawn(_ at: Double, in track: MediaTimelineTrackView) -> CGFloat? {
            showing(track).first { abs($0.seconds - at) < 0.001 }?.x
        }

        /// The second of film a picture stands for, if it is one of this film's.
        func second(of picture: UIImage?) -> Double? {
            picture.flatMap { second[ObjectIdentifier($0)] }
        }
    }

    /// A two-piece track of its own, with a provider that hands back a
    /// different picture for every second of film.
    @MainActor
    private func cutTrack(_ film: Film, at cut: Double = 4) -> MediaTimelineTrackView {
        let track = MediaTimelineTrackView()
        track.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        track.framesProvider = { seconds, _, _ in
            await MainActor.run {
                var made: [Double: UIImage] = [:]
                for at in seconds { made[at] = film.picture(for: at) }
                return made
            }
        }
        track.configure(duration: 10, timeline: MediaTimeline(segments: [
            MediaSegment(start: 0, end: cut),
            MediaSegment(start: cut, end: 10)
        ]))
        track.setNeedsLayout()
        track.layoutIfNeeded()
        return track
    }

    /// ⚠️ **REPORTED AS THE CLIP NOT CONTINUING AT ALL.** The arithmetic was
    /// right — the piece grew, the next one was pushed along, the total went up —
    /// and the strip did not change one square, so on the device nothing about
    /// the drag revealed any film. What a handle does is open a window on a fixed
    /// sheet of film, so what this asks is that the film past the cut APPEARS:
    /// the first section must end on later film than it did.
    @Test func continuingASectionRevealsTheFilmPastTheCut() async throws {
        let film = Film()
        let track = cutTrack(film)
        try await settle(until: { film.showing(track).count > 4 })
        // ⚠️ **BY SECTION, NOT BY A POSITION TAKEN BEFORE THE DRAG.** The seam
        // moves — that is the point of the gesture — so a filter on x asks about
        // the wrong stretch of track the moment the handle has been pulled, and
        // reads as the film not having been revealed at all.
        let endOfTheFirst = { film.showing(track).filter { $0.piece == 0 }.map(\.seconds).max() }
        let before = try #require(endOfTheFirst())
        #expect(abs(before - 4) < 0.9, "guard: the first section ends on its cut, \(before)")

        track.debugTap(atContentX: 100)
        track.layoutIfNeeded()
        let centres = try #require(track.debugHandleCentres)
        track.debugTakeHold(at: centres.end)
        track.debugDrag(byPoints: 60)
        track.debugRelease()
        track.setNeedsLayout()
        track.layoutIfNeeded()

        try await settle(until: { (endOfTheFirst() ?? 0) > before + 0.5 })
        let after = try #require(endOfTheFirst())
        #expect(after > before + 0.5,
                "the first section still ends on \(after)s of film: nothing was revealed")
        #expect(after < 5.01, "it reached past its own out point: \(after)")
    }

    /// ⚠️ **A SQUARE THE WINDOW CUTS IN HALF IS CROPPED ON SCREEN, NOT SQUEEZED.**
    /// The drawn half of the rule: the picture keeps its own full width and hangs
    /// out of the part that is shown. Laid into the shortened rectangle instead,
    /// the frame would compress as the handle moved — the sheet would appear to
    /// stretch rather than to be revealed.
    @Test func aSquareCutByAHandleHoldsAFullWidthPicture() async throws {
        let film = Film()
        let track = cutTrack(film, at: 4.15)
        try await settle(until: { film.showing(track).count > 4 })

        let cut = track.debugFilmCrop.filter { $0.width < MediaTimelining.tileWidth - 1 }
        #expect(cut.isEmpty == false, "guard: no square is cut by a window here")
        for square in cut {
            #expect(abs(square.picture.width - MediaTimelining.tileWidth) < 0.01,
                    "the picture was squeezed into the visible part: \(square)")
        }
        #expect(cut.contains { $0.picture.minX < -0.01 },
                "no picture hangs out of its square, so nothing is being cropped")

        // ⚠️ **AND THE DAYLIGHT MOVES NO PICTURE.** With nothing held, every
        // piece gives up a point at its cut; the pictures stay where the sheet
        // puts them.
        #expect(track.debugSelectedPiece == nil, "guard: nothing is held")
        let seam = try #require(track.debugPieceFrames.first?.upperBound)
        #expect(track.debugFilmWindows.contains {
            abs($0.frame.minX - (seam + MediaTimelineTrackView.debugSeamGap / 2)) < 0.01
        }, "guard: no window starts on a carved edge")
        for square in track.debugPictureOnTheSheet {
            #expect(abs(square.sheet - square.drawn) < 0.01,
                    "a picture moved off the sheet: \(square)")
        }
    }

    /// ⚠️ **A CARRIED CHIP SHOWS ITS OWN PIECE'S FILM.** Cut at 4.49s, the second
    /// piece's first square of film (3.6–4.5s) is 0.6pt of it — all inside the
    /// daylight, so the strip never makes that square for the second piece. The
    /// same square IS decoded for the first piece, and a chip that looked it up
    /// on the uncarved sheet showed the first piece's last frame.
    @Test func aCarriedChipShowsItsOwnPiecesFilm() async throws {
        let film = Film()
        let track = cutTrack(film, at: 4.49)
        try await settle(until: { film.showing(track).count > 4 })
        try #require(film.showing(track).count > 4, "the film never arrived")
        let second = try #require(track.debugPieceFrames.last)

        track.debugLift(atContentX: second.lowerBound + 20)
        try #require(track.debugCarrying == 1, "guard: the second piece was not lifted")
        let pictures = track.debugShotPictures
        try #require(pictures.count == 2)

        let shown = try #require(film.second(of: pictures[1]), "the chip shows no frame of the film")
        #expect(shown >= 4.49, "the second piece's chip shows \(shown)s — the first piece's film")
        track.debugDrop()
    }

    /// ⚠️ **AND CROPPING ONE SECTION SLIDES THE NEXT ONE'S FILM WITH IT.**
    /// Reported from the device: *"quand je crop le clip 1, c'est la fin du clip
    /// 2 qui est animé… c'est le container de la section qui se déplace"*. The
    /// strip was one row of squares at fixed places, each re-labelled with
    /// whatever film now stood there, so the pictures never moved — only the
    /// frame, the seam and the end of the track did. A section's film belongs to
    /// the section: when it moves, its pictures move with it, by exactly as much.
    @Test func croppingASectionCarriesTheNextOnesFilmAlongWithIt() async throws {
        let film = Film()
        let track = cutTrack(film)
        try await settle(until: { film.showing(track).count > 4 })
        // The first square of the second section, and the film in it.
        let inTheSecond = try #require(
            film.showing(track).filter { $0.piece == 1 }.min { $0.x < $1.x }
        )
        #expect(inTheSecond.seconds > 4, "guard: that square holds the second section's film")

        track.debugTap(atContentX: 100)
        track.layoutIfNeeded()
        let centres = try #require(track.debugHandleCentres)
        track.debugTakeHold(at: centres.end)
        track.debugDrag(byPoints: -60)
        track.debugRelease()
        track.setNeedsLayout()
        track.layoutIfNeeded()

        let moved = try #require(film.drawn(inTheSecond.seconds, in: track),
                                 "the film that was in that square is no longer drawn at all")
        #expect(abs(moved - (inTheSecond.x - 60)) < 0.01,
                "that second of film was drawn at \(inTheSecond.x) and is now at \(moved) — it did not travel with its section")
    }

    // MARK: - Pinch to zoom (charter F15)

    /// ⚠️ **INSTAGRAM'S OWN ON-SCREEN HINT READS "Tap on track to trim. Pinch to
    /// zoom."** All four reference apps have it, and without it a long clip can
    /// only be cut to whatever a coarse strip can express.
    @Test func pinchingDrawsASecondOfFilmWider() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        let before = bar.debugContentWidth
        #expect(before > 0, "guard: the film has a width to begin with")

        bar.debugPinch(by: 2)

        #expect(bar.debugPointsPerSecond > 60, "the scale did not move")
        #expect(bar.debugContentWidth > before * 1.5,
                "the film did not grow with it: \(before) to \(bar.debugContentWidth)")
    }

    /// ⚠️ **THE FILM GROWS AROUND WHAT YOU ARE LOOKING AT.** Zooming around the
    /// clip's own beginning throws the author's place away every time they pinch,
    /// which is the single most obvious way to get this wrong.
    @Test func zoomingKeepsTheMomentUnderTheNeedle() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 6, trackWidth: bar.bounds.width
        ))
        #expect(abs(bar.debugSecondsUnderNeedle - 6) < 0.1, "guard: the needle is at six seconds")

        bar.debugPinch(by: 2.5)

        #expect(abs(bar.debugSecondsUnderNeedle - 6) < 0.15,
                "the zoom moved the playhead to \(bar.debugSecondsUnderNeedle)s")
    }

    /// And the ruler refines with the scale rather than staying put — a ruler
    /// labelled every two seconds at four times the width is a wall of numbers.
    @Test func theRulerFollowsTheZoom() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        let coarse = bar.debugRulerMarks.count

        bar.debugPinch(by: 4)

        #expect(bar.debugRulerMarks.count > coarse,
                "\(coarse) labels before and \(bar.debugRulerMarks.count) after")
    }

    // MARK: - Play and pause

    /// ⚠️ **A GLYPH THAT REACHES NOTHING IS THE DEFECT THIS RUN OF WORK EXISTS TO
    /// REMOVE.** The ruler row gained a play button; this is what says it is
    /// wired to a player rather than drawn on top of one.
    @Test func thePlayButtonStopsAndStartsTheClip() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.preview.paused = false
        screen.window.layoutIfNeeded()

        bar.debugTapPlayPause()

        #expect(screen.preview.pauses.last == true, "nothing was asked of the player")
        #expect(bar.debugShowsPause == false, "the glyph still offers to pause a stopped clip")
    }

    /// ⚠️ **AND SCRUBBING MUST NOT UNDO A DELIBERATE PAUSE.** A scrub stops the
    /// clip and lets it go again; without remembering who stopped it, releasing
    /// restarts a clip the author had paused on purpose.
    @Test func aScrubDoesNotRestartAClipTheAuthorStopped() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.preview.paused = false
        screen.window.layoutIfNeeded()

        bar.debugTapPlayPause()          // the author stops it
        screen.preview.paused = true
        hold(bar)
        bar.debugTakeHold(at: 0)         // and then moves a handle
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()

        #expect(screen.preview.pauses.last == true,
                "the release restarted a clip the author had stopped: \(screen.preview.pauses)")
        #expect(bar.debugShowsPause == false)
    }

    /// ⚠️ **A TAP ON THE PICTURE IS THE PLAY BUTTON NOBODY HAS TO FIND.** Every
    /// video surface in every app has it, and the ruler's glyph is the explicit
    /// one beside it.
    @Test func tappingTheMediaStopsAndStartsTheClip() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.preview.paused = false
        screen.window.layoutIfNeeded()
        #expect(screen.editor.debugMediaTapIsAttached, "the canvas carries no tap at all")

        screen.editor.debugTapMedia()

        #expect(screen.preview.pauses.last == true, "nothing was asked of the player")
        #expect(bar.debugShowsPause == false,
                "the ruler's glyph still offers to pause a stopped clip")
    }

    /// ⚠️ **AND IT KEEPS WORKING BEHIND CROP'S NOTICE, WHICH IS NOT AN
    /// OVERSIGHT.** Choosing Crop on a video puts a line of text in the band and
    /// locks nothing — `enterCrop` refuses videos — so the clip is still playing
    /// and still the author's to stop. A guard against "cropping" here would be
    /// unreachable code, and this screen has already removed one of those.
    @Test func tappingStillWorksWhileCropSaysItCannotServeAVideo() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        screen.preview.paused = false
        choose(Mode.crop, on: screen)
        #expect(screen.editor.debugBand.content is BandNoticeView, "guard: crop refused the video")

        screen.editor.debugTapMedia()

        #expect(screen.preview.pauses.last == true,
                "the clip could not be stopped while the notice was up")
    }

    // MARK: - Who owns the time

    /// ⚠️ **THE DEFECT AS REPORTED FROM THE DEVICE:** "if I move forward in the
    /// timeline, the video goes back to its starting point instead of carrying
    /// on from the cursor." Two causes, and this is the second — the first was a
    /// stale pause anchor inside `VideoPlaybackController`, fixed there with its
    /// own test. Here the track resumed following one tick after the finger
    /// lifted, read a player that had not finished its (quarter-second tolerant,
    /// asynchronous) seek, and copied the OLD position back over the new one.
    ///
    /// ⚠️ **AND THIS ASKS THE SCREEN, NOT THE ARITHMETIC.** `MediaTimelining`'s
    /// own suite proves the rule; this proves the rule is WIRED — that a tick of
    /// the follower actually consults it before moving the film.
    @Test func aTickFromAPlayerThatHasNotArrivedDoesNotDragTheFilmBack() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // The author pushes the film to four seconds and lets go.
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 4, trackWidth: bar.bounds.width
        ))
        screen.editor.debugEndScrub()
        let afterRelease = bar.debugSecondsUnderNeedle
        #expect(abs(afterRelease - 4) < 0.1, "guard: the film is where it was left: \(afterRelease)")

        // The player has not moved yet — it is still where the scrub began.
        screen.preview.headSeconds = 0.2
        screen.editor.debugFollowTick()

        #expect(abs(bar.debugSecondsUnderNeedle - 4) < 0.1,
                "the film was dragged back to \(bar.debugSecondsUnderNeedle)s")
    }

    /// The witness: once the player arrives, the track follows again — a fix that
    /// simply stopped following would pass the test above and break playback.
    @Test func aTickFromAnArrivedPlayerMovesTheFilmAgain() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 4, trackWidth: bar.bounds.width
        ))
        screen.editor.debugEndScrub()

        // It arrived, and then played on a little.
        screen.preview.headSeconds = 4.2
        screen.editor.debugFollowTick()
        #expect(screen.editor.debugHandover == .settled, "still waiting: \(screen.editor.debugHandover)")

        screen.preview.headSeconds = 5
        screen.editor.debugFollowTick()

        #expect(abs(bar.debugSecondsUnderNeedle - 5) < 0.1,
                "the film stopped following playback: \(bar.debugSecondsUnderNeedle)")
    }

    // MARK: - The film moves and the needle does not

    /// ⚠️ **THE TRACK OPENS ON THE CLIP'S FIRST FRAME, NOT HALF A SCREEN BEFORE
    /// IT.** The content is padded by half a track at each end so both ends can
    /// reach a centred needle, which means the resting offset is NEGATIVE. A
    /// track opening at zero would show the author the padding.
    @Test func theFilmOpensWithTheClipsStartUnderTheNeedle() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        #expect(bar.debugNeedleIsCentred)
        #expect(abs(bar.debugCentringInset - bar.bounds.width / 2) < 0.5,
                "got \(bar.debugCentringInset) for a \(bar.bounds.width)pt track")
        #expect(abs(bar.debugSecondsUnderNeedle) < 0.01,
                "the clip opens at \(bar.debugSecondsUnderNeedle)s")
    }

    /// ⚠️ **SCROLLING IS THE SEEK, AND WITHOUT THIS THE WHOLE ARRANGEMENT IS
    /// DECORATION.** A film that slides under a needle while the picture above it
    /// stays put is a control that reaches nothing — the defect this run of work
    /// exists to remove, wearing its most convincing sleeve, because the strip
    /// itself moves.
    @Test func scrollingTheFilmSeeksTheClip() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        #expect(screen.preview.seeks.isEmpty, "guard: nothing has been asked of the player yet")

        // Four seconds in, at the track's own scale.
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 4, trackWidth: bar.bounds.width
        ))

        let asked = try #require(screen.preview.seeks.last)
        #expect(abs(asked - 4) < 0.1, "four seconds in is four seconds of the item: got \(asked)")
    }

    /// ⚠️ **PLAYBACK STOPS WHILE A FINGER IS ON THE TRACK.** A clip that keeps
    /// running fights every seek the scroll asks for: the player advances between
    /// samples, the track seeks it back, and the picture lands somewhere neither
    /// the author nor the player chose.
    @Test func playbackPausesWhileAFingerIsOnTheTrackAndResumesAfter() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)

        hold(bar)
        bar.debugTakeHold(at: 0)
        let whileHeld = screen.preview.pauses
        bar.debugRelease()

        #expect(whileHeld.last == true, "the clip kept running under the finger: \(whileHeld)")
        #expect(screen.preview.pauses.last == false,
                "the clip never resumed: \(screen.preview.pauses)")
    }

    /// The time markings above the film, which are the half of the design that
    /// makes a scroll mean something.
    @Test func theTimeMarkingsAreTimecodes() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        let marks = bar.debugRulerMarks
        #expect(marks.first == "0:00", "got \(marks)")
        #expect(marks.count > 2, "one mark is not a ruler: \(marks)")
        // ⚠️ CHARTER F9: a dot at the midpoint between two labels. Measured on
        // CapCut and 快影 (label every 2s, dot at 1s) and Instagram (4s, dot at
        // 2s). Without it the eye has nothing to judge a half-step against.
        #expect(bar.debugRulerDotCount == marks.count,
                "\(bar.debugRulerDotCount) dots for \(marks.count) labels")
    }

    /// ⚠️ **CHARTER F10.** The readout said only how long the result would run —
    /// which is the half you can already see by looking at the selection. Where
    /// the needle IS is the half you cannot, and it is what CapCut and 快影 put at
    /// the left of their control row as `MM:SS / MM:SS`.
    @Test func theReadoutSaysWhereYouAreAndHowLongItWillRun() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        #expect(bar.debugKeptText == "0:00 / 0:10", "got \(bar.debugKeptText ?? "nil")")

        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 4, trackWidth: bar.bounds.width
        ))

        #expect(bar.debugKeptText == "0:04 / 0:10",
                "the position half never moved: \(bar.debugKeptText ?? "nil")")
    }

    /// ⚠️ **CHARTER T7, ASKED OF THE SCREEN.** A crawl must buy the exact frame
    /// and a fling must not: an exact seek sixty times a second leaves the picture
    /// lurching behind the finger.
    @Test func aFastScrubAsksThePlayerMoreLooselyThanASlowOne() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // Two samples a hair apart, then one a long way on.
        for seconds in [1.0, 1.01] {
            bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: seconds, trackWidth: bar.bounds.width
            ))
        }
        let crept = try #require(screen.preview.seekTolerances.last)
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forPlayedSeconds: 8, trackWidth: bar.bounds.width
        ))
        let flung = try #require(screen.preview.seekTolerances.last)

        #expect(crept <= 0.05, "a crawl paid for keyframes it cannot see: \(crept)")
        #expect(flung > crept * 5, "the tolerance barely moved: \(crept) to \(flung)")
    }

    /// ⚠️ **THE NUMBER THE AUTHOR IS ACTUALLY CHOOSING.** Two handles on a strip
    /// say where the cut is; only this says how long the result will run, which
    /// is the thing a person is deciding.
    @Test func theSelectionSaysHowLongTheResultWillRun() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        #expect(bar.debugKeptText == "0:00 / 0:10",
                "guard: the whole clip: \(bar.debugKeptText ?? "nil")")
        // ⚠️ **AND IT HAS TO BE WHERE IT CAN BE READ.** The readout began as ink
        // on the selection, which put it 210pt past the right edge of a 390pt
        // track on a ten-second clip — correct, and never once visible.
        #expect(bar.debugKeptIsOnScreen, "the number scrolled off the track")

        hold(bar)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 180)   // three seconds at the track's scale
        bar.debugRelease()
        screen.window.layoutIfNeeded()

        #expect(bar.debugKeptText == "0:00 / 0:07", "got \(bar.debugKeptText ?? "nil")")
    }

    /// ⚠️ **A TOUCH ON THE FILM SCROLLS; ONLY A TOUCH ON A HANDLE DRAGS.** The
    /// track's pan refuses at touch-down for anything else, which is what keeps
    /// an ordinary scroll free — `scroller.panGestureRecognizer` waits for it to
    /// fail, and a recogniser that never begins fails at once. Were it to accept
    /// everywhere, the film could not be scrolled at all.
    /// ⚠️ **THE REACH IS MEASURED FROM WHERE THE FINGER LANDED, NOT FROM WHERE
    /// THE RECOGNISER WOKE UP.** A pan is asked whether to begin only once it has
    /// left its own slop, and when several touch samples arrive in one turn of
    /// the run loop that is tens of points later. Measured in the simulator: a
    /// drag that landed exactly on a cap (content x = 5, cap at -6) was evaluated
    /// at x = 53 — outside the 44pt reach — so the handle refused a drag that
    /// started on it and the film scrolled away instead. A fast flick off a cap
    /// does this to a real finger too.
    ///
    /// What this CANNOT establish is that the delegate calls it: a recogniser's
    /// location cannot be set from a test, so that half is checked on a device.
    @Test func theReachIsMeasuredFromWhereTheFingerLanded() {
        #expect(MediaTimelineTrackView.touchDown(location: 53, travelled: 48) == 5)
        #expect(MediaTimelineTrackView.touchDown(location: 10, travelled: -30) == 40,
                "a leftward drag started to the right of where it has got to")
    }

    @Test func aTouchInTheMiddleOfTheFilmScrollsRatherThanGrabbingAHandle() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await ready(screen)
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // ⚠️ **WITH NOTHING HELD THERE ARE NO HANDLES AT ALL**, which is the
        // stronger half of this rule: every touch on an untouched track is a
        // scroll, so the tap that selects a piece never has to fight one.
        #expect(bar.debugHandleCentres == nil, "a track nobody has tapped has handles")
        #expect(bar.debugWouldTakeAHandle(at: 0) == false)

        hold(bar)
        screen.window.layoutIfNeeded()

        #expect(bar.debugHandlePanIsDelegatedHere,
                "a perfect predicate that nobody asks is still a dead handle")
        #expect(bar.debugHandlePanLivesInsideTheScroller,
                "an outsider pan and the scroller would each wait for the other")
        // ⚠️ **AND IT MUST BE ABLE TO RECEIVE A TOUCH WHERE THE CAPS ARE DRAWN.**
        // The caps sit OUTSIDE the cut — the leading one at x = -12 on an
        // untrimmed clip — and a view does not receive touches outside its own
        // bounds. Attached to the content, which starts at zero, the pan never
        // saw a finger on the leading cap: the reach existed inwards only, which
        // is what "the hit area is beside the grip" looks like.
        //
        // The LEADING cap is the case that matters: on an untrimmed clip it sits
        // at a NEGATIVE content x, which is the side `content.bounds` does not
        // have. (The trailing cap of a whole-clip selection is simply off screen
        // at rest — a different thing, and not a hit-testing question.)
        let caps = try #require(bar.debugHandleCentres)
        #expect(caps.start < 0, "guard: the leading cap really is before the film starts")
        #expect(bar.debugPanReceivesTouches(atContentX: caps.start),
                "the leading cap is drawn where the pan cannot be touched")
        #expect(bar.debugWouldTakeAHandle(at: 0), "guard: the start handle is grabbable")

        // ⚠️ **THE REACH SITS ON THE CAP, NOT ON THE CUT.** The caps stand
        // outside the kept film, so measuring the finger's forty-four points from
        // the cut centres them half a cap away from the thing being aimed at —
        // generous enough that the handles still work, and harder to hit on one
        // side than the other. This touch is inside the reach of the cap and
        // outside the reach of the cut, so only the right measurement takes it.
        let centres = try #require(bar.debugHandleCentres)
        #expect(centres.start < 0, "the leading cap is drawn before the cut begins")
        #expect(bar.debugWouldTakeAHandle(at: centres.start - 40),
                "a touch on the outer side of the cap missed it")
        #expect(bar.debugWouldTakeAHandle(at: 300) == false,
                "the middle of the film took a handle, so the track cannot be scrolled")
    }
}
