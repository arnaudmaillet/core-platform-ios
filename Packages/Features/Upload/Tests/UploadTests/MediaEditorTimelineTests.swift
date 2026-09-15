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
        func play(_ file: URL, in surface: VideoRenderView) async {}
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

        func seek(
            toFraction fraction: Double, in surface: VideoRenderView, toleranceSeconds: Double
        ) {
            seeks.append(fraction)
            seekTolerances.append(toleranceSeconds)
        }

        /// Where the stub player claims to be. Nil is the ordinary answer —
        /// nothing is bound in a test, and that is exactly what the follower
        /// finds on the first frames after a real page settles. Tests that care
        /// about the handover set it.
        var head: (fraction: Double, seconds: Double)?

        func playhead(in surface: VideoRenderView) -> (fraction: Double, seconds: Double)? { head }

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

    private func track(in screen: Screen) throws -> MediaTimelineTrackView {
        try #require(screen.editor.debugBand.content as? MediaTimelineTrackView)
    }

    // MARK: - Who gets the mode

    @Test func choosingTrimOnAVideoPutsTheTrackInTheBand() throws {
        let screen = open(Self.items(2, videosAt: [0]))

        choose(Mode.trim, on: screen)

        #expect(screen.editor.debugBand.content is MediaTimelineTrackView,
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
        try await settle(until: { screen.preview.asked.isEmpty == false })

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
        let tiles = MediaTimelining.tileCount(
            acrossContentWidth: MediaTimelining.contentWidth(ofSourceSeconds: 240)
        )
        #expect(tiles > 200, "guard: the clip is \(tiles) tiles long")
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
            forSourceSeconds: 9, trackWidth: bar.bounds.width
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.asked.count > 1 })

        let bar = try track(in: screen)
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        #expect(screen.editor.debugBand.content is MediaTimelineTrackView, "guard: the strip is up")

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
        try await settle(until: { screen.preview.asked.isEmpty == false })

        #expect(screen.editor.debugBand.content is MediaTimelineTrackView)
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)

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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)

        bar.debugTakeHold(at: 0)
        #expect(bar.debugHasGrip, "guard: the start handle was taken")
        bar.debugDrag(byPoints: 60)

        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["video-0"] == nil, "nothing is stored mid-drag")
    }

    @Test func releasingAHandleStoresTheTimelineAndCarriesIt() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)

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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)

        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()

        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["photo-1"] == nil)
    }

    /// The selection has to be visible as a selection: something dimmed on at
    /// least one side of it, or the handles are decoration.
    @Test func aCutClipShowsWhatIsBeingDiscarded() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        #expect(bar.debugIsDimmedBefore == false, "guard: nothing is discarded yet")

        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()
        screen.window.layoutIfNeeded()

        #expect(bar.debugIsDimmedBefore, "the discarded head is not dimmed")
        // ⚠️ AGAINST THE CONTENT, NOT THE VIEW. The strip is as wide as the clip
        // is long and scrolls inside a narrower track — a ten-second clip is
        // 600pt of film in a 390pt window, so comparing with `bounds.width` would
        // be true before any cut at all.
        #expect(bar.debugSelectionFrame.width < bar.debugContentWidth,
                "the selection still spans the whole strip: \(bar.debugSelectionFrame)")
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
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
        let kept = bar.debugKeptRangeX
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.preview.paused = false
        screen.preview.head = (fraction: 0.5, seconds: 10)
        screen.editor.debugFollowTick()
        #expect(bar.debugShowsPause, "guard: a running clip offers to pause")

        // The clip reaches its end. Nobody tapped anything.
        screen.preview.paused = true
        screen.editor.debugFollowTick()

        #expect(bar.debugShowsPause == false,
                "the button still offers to pause a clip that has stopped")
    }

    /// ⚠️ **THE RULE IS IN `MediaTimelining`; THIS IS THAT IT IS WIRED.** A
    /// preview that plays past the end handle shows the author footage they have
    /// just thrown away, as part of the post.
    @Test func playbackTurnsBackAtTheEndOfTheCut() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // Cut the head off: keep from ~3s to the end of a ten-second clip.
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 180)
        bar.debugRelease()

        // ⚠️ THE HANDOVER COMES FIRST, AND SKIPPING IT IS NOT A SHORTCUT. After
        // a release the track keeps the time until the player reports arriving at
        // the scrubbed position; a tick before that is refused, which is the rule
        // that stops a stale player dragging the film back. So: the player
        // arrives, and only then does it play on to the end.
        screen.preview.paused = false
        screen.preview.head = (fraction: 0.3, seconds: 10)
        screen.editor.debugFollowTick()
        #expect(screen.editor.debugHandover == .settled, "guard: the track has the player back")
        let seeksBefore = screen.preview.seeks.count

        screen.preview.head = (fraction: 1.0, seconds: 10)
        screen.editor.debugFollowTick()

        #expect(screen.preview.seeks.count > seeksBefore, "it played on past the cut")
        let back = try #require(screen.preview.seeks.last)
        #expect(abs(back * 10 - 3) < 0.3,
                "it turned back to \(back * 10)s rather than to the start of the cut")
    }

    /// The witness: inside the cut, nothing is asked of the player at all — a
    /// loop that fired every beat would seek the clip to a standstill.
    @Test func playbackInsideTheCutIsLeftAlone() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        screen.window.layoutIfNeeded()
        let seeksBefore = screen.preview.seeks.count

        screen.preview.paused = false
        screen.preview.head = (fraction: 0.5, seconds: 10)
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // ⚠️ **THE HEAD IS CUT FIRST, AND WITHOUT THAT THIS PROVES NOTHING.**
        // With the whole clip kept, the leading cap sits at source-second ZERO —
        // and zero is zero at every scale, so a cap placed with the WRONG
        // `pointsPerSecond` lands in exactly the right spot. Measured: breaking
        // it turned no test red until the cut moved off the start.
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 180)          // three seconds in
        bar.debugRelease()
        bar.debugPinch(by: 3)
        let centres = try #require(bar.debugHandleCentres)

        // Asked against the scale the track says it is drawing at, from a
        // source-second this test chose — not from the track's own answer.
        let expected = MediaTimelining.x(
            atSourceSeconds: 3, pointsPerSecond: bar.debugPointsPerSecond
        )
        #expect(abs(centres.start - (expected - 6)) < 1,
                "the leading cap is at \(centres.start), the cut at \(expected)")
        #expect(bar.debugWouldTakeAHandle(at: centres.start), "the leading cap is unreachable")
        #expect(bar.debugWouldTakeAHandle(at: centres.end), "the trailing cap is unreachable")
        #expect(centres.end > 1500,
                "guard: the zoom really moved the trailing cap: \(centres.end)")
    }

    /// ⚠️ **THE FILM EASES INTO A JUMP AND STEPS THROUGH PLAYBACK.** Reported
    /// from the device as the timeline moving abruptly when the grips change the
    /// selection: letting go of a handle leaves the player somewhere else, and
    /// the next beat of the follower put the film there in one frame.
    @Test func aBigMoveOfTheFilmIsEasedRatherThanSnapped() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        let before = bar.debugContentOffset

        bar.follow(sourceSeconds: 7)

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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        bar.follow(sourceSeconds: 0.1)

        #expect(bar.debugIsEasing == false, "a one-point step was animated")
        #expect(abs(bar.debugSecondsUnderNeedle - 0.1) < 0.02,
                "the step did not land: \(bar.debugSecondsUnderNeedle)")
    }

    // MARK: - Pinch to zoom (charter F15)

    /// ⚠️ **INSTAGRAM'S OWN ON-SCREEN HINT READS "Tap on track to trim. Pinch to
    /// zoom."** All four reference apps have it, and without it a long clip can
    /// only be cut to whatever a coarse strip can express.
    @Test func pinchingDrawsASecondOfFilmWider() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forSourceSeconds: 6, trackWidth: bar.bounds.width
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.preview.paused = false
        screen.window.layoutIfNeeded()

        bar.debugTapPlayPause()          // the author stops it
        screen.preview.paused = true
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // The author pushes the film to four seconds and lets go.
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forSourceSeconds: 4, trackWidth: bar.bounds.width
        ))
        screen.editor.debugEndScrub()
        let afterRelease = bar.debugSecondsUnderNeedle
        #expect(abs(afterRelease - 4) < 0.1, "guard: the film is where it was left: \(afterRelease)")

        // The player has not moved yet — it is still where the scrub began.
        screen.preview.head = (fraction: 0.02, seconds: 10)
        screen.editor.debugFollowTick()

        #expect(abs(bar.debugSecondsUnderNeedle - 4) < 0.1,
                "the film was dragged back to \(bar.debugSecondsUnderNeedle)s")
    }

    /// The witness: once the player arrives, the track follows again — a fix that
    /// simply stopped following would pass the test above and break playback.
    @Test func aTickFromAnArrivedPlayerMovesTheFilmAgain() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forSourceSeconds: 4, trackWidth: bar.bounds.width
        ))
        screen.editor.debugEndScrub()

        // It arrived, and then played on a little.
        screen.preview.head = (fraction: 0.42, seconds: 10)
        screen.editor.debugFollowTick()
        #expect(screen.editor.debugHandover == .settled, "still waiting: \(screen.editor.debugHandover)")

        screen.preview.head = (fraction: 0.5, seconds: 10)
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        #expect(screen.preview.seeks.isEmpty, "guard: nothing has been asked of the player yet")

        // Four seconds in, at the track's own scale.
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forSourceSeconds: 4, trackWidth: bar.bounds.width
        ))

        let asked = try #require(screen.preview.seeks.last)
        #expect(abs(asked - 0.4) < 0.01, "a ten-second clip four seconds in is 0.4: got \(asked)")
    }

    /// ⚠️ **PLAYBACK STOPS WHILE A FINGER IS ON THE TRACK.** A clip that keeps
    /// running fights every seek the scroll asks for: the player advances between
    /// samples, the track seeks it back, and the picture lands somewhere neither
    /// the author nor the player chose.
    @Test func playbackPausesWhileAFingerIsOnTheTrackAndResumesAfter() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)

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
        try await settle(until: { screen.preview.asked.isEmpty == false })
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        #expect(bar.debugKeptText == "0:00 / 0:10", "got \(bar.debugKeptText ?? "nil")")

        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forSourceSeconds: 4, trackWidth: bar.bounds.width
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()

        // Two samples a hair apart, then one a long way on.
        for seconds in [1.0, 1.01] {
            bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
                forSourceSeconds: seconds, trackWidth: bar.bounds.width
            ))
        }
        let crept = try #require(screen.preview.seekTolerances.last)
        bar.debugScroll(toContentOffset: MediaTimelining.contentOffset(
            forSourceSeconds: 8, trackWidth: bar.bounds.width
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
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
        screen.window.layoutIfNeeded()
        #expect(bar.debugKeptText == "0:00 / 0:10",
                "guard: the whole clip: \(bar.debugKeptText ?? "nil")")
        // ⚠️ **AND IT HAS TO BE WHERE IT CAN BE READ.** The readout began as ink
        // on the selection, which put it 210pt past the right edge of a 390pt
        // track on a ten-second clip — correct, and never once visible.
        #expect(bar.debugKeptIsOnScreen, "the number scrolled off the track")

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
    @Test func aTouchInTheMiddleOfTheFilmScrollsRatherThanGrabbingAHandle() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try track(in: screen)
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
