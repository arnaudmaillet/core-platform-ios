import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE TRIM MODE: WHO GETS IT, WHAT IT SHOWS, AND WHEN A DRAG BECOMES A
/// DECISION.**
///
/// The arithmetic is asked separately in `MediaTrimTests` — a pan's translation
/// cannot be set, so everything that could be wrong about clamping and handles
/// lives in a pure type. What is left here is the screen's part: routing, the
/// notice for a medium this mode cannot serve, and the moment a value is stored.
@MainActor
struct MediaEditorTrimTests {
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

    /// Nothing here decodes: the strip's subject is what the screen ASKS for and
    /// where it puts the answer, not whether AVFoundation can read a file.
    private final class StubPreview: MediaVideoPreviewing {
        func play(_ file: URL, in surface: VideoRenderView) async {}
        func stop(_ surface: VideoRenderView) {}
        func setPaused(_ paused: Bool, in surface: VideoRenderView) {}
        func isBound(_ surface: VideoRenderView) -> Bool { false }

        private(set) var asked: [(file: URL, count: Int)] = []

        func filmstrip(of file: URL, count: Int, height: CGFloat) async -> [UIImage] {
            asked.append((file, count))
            return (0..<count).map { _ in
                UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                    UIColor.green.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                }
            }
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

    private func strip(in screen: Screen) throws -> MediaTrimStripView {
        try #require(screen.editor.debugBand.content as? MediaTrimStripView)
    }

    // MARK: - Who gets the mode

    @Test func choosingTrimOnAVideoPutsTheStripInTheBand() throws {
        let screen = open(Self.items(2, videosAt: [0]))

        choose(Mode.trim, on: screen)

        #expect(screen.editor.debugBand.content is MediaTrimStripView,
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

    @Test func theStripAsksForFramesOfTheClipOnThisPage() async throws {
        let screen = open(Self.items(2, videosAt: [0]))

        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })

        #expect(screen.preview.asked.first?.file == StubLibrary.file(for: "video-0"))
        #expect((screen.preview.asked.first?.count ?? 0) > 1,
                "a strip of one frame is not a strip")
    }

    @Test func theFramesLandInTheStrip() async throws {
        let screen = open(Self.items(2, videosAt: [0]))

        choose(Mode.trim, on: screen)
        try await settle(until: { (try? strip(in: screen).debugFrameCount) ?? 0 > 0 })

        #expect(try strip(in: screen).debugFrameCount > 1)
    }

    /// ⚠️ **A COUNT OF ZERO IS A STRIP THAT NEVER FILLS.** Every band tenant is
    /// asked this before its first layout, and an unlaid strip is 0pt wide.
    @Test func anUnlaidStripStillAsksForAFrame() {
        #expect(MediaEditorViewController.filmstripCount(across: 0) == 1)
        #expect(MediaEditorViewController.filmstripCount(across: 390) > 1)
    }

    // MARK: - Settling onto another page

    /// ⚠️ **THE HIGH-SEVERITY DEFECT A REVIEW FOUND, AND THE TEST THAT WOULD
    /// HAVE CAUGHT IT.** `refreshTrimStrip` was reachable only from the category
    /// bar, so paging with Trim open left the strip holding the PREVIOUS clip's
    /// frames, duration and handles while `onChange` read `currentItemID` live.
    /// A drag then stored one clip's seconds under another clip's id — measured
    /// at the time: a 60pt drag on a 52-second clip, after settling onto a
    /// four-second one, stored `start: 8.0` against the short clip, which then
    /// published its last second.
    ///
    /// `trimmingOneClipLeavesTheOtherPagesAlone` only LOOKED like it covered
    /// this: it never paged, so it could not see the bug. `debugScrollToPage`
    /// existed and was used by the playback suite.
    @Test func settlingOnAnotherClipRetargetsTheStrip() async throws {
        let screen = open(Self.items(2, videosAt: [0, 1]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        #expect(screen.preview.asked.count == 1, "guard: one clip has been asked for")

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.asked.count > 1 })

        #expect(screen.preview.asked.last?.file == StubLibrary.file(for: "video-1"),
                "the strip still holds the previous clip: \(screen.preview.asked)")
    }

    /// ⚠️ **THE SECONDS, NOT THE ID — AND ASKING FOR THE ID PROVES NOTHING.**
    /// This first asserted that the cut landed on the settled clip and not the
    /// one behind, which is true EVEN WITH THE DEFECT: `onChange` reads
    /// `currentItemID` live, so the id was always right. What was wrong was the
    /// arithmetic — the drag was scaled against the STALE clip's duration.
    /// Proven by removing the settle refresh and watching this pass.
    ///
    /// The two clips are deliberately different lengths, so the same 60pt drag
    /// is worth a different number of seconds on each: 60/390 × 4 ≈ 0.62 on the
    /// settled one, 60/390 × 40 ≈ 6.15 on the one behind.
    @Test func aDragAfterASettleIsScaledAgainstTheSettledClip() async throws {
        let long = MediaLibraryItem(id: "video-long", kind: .video(duration: 40))
        let short = MediaLibraryItem(id: "video-short", kind: .video(duration: 4))
        let screen = open([long, short])
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.asked.count > 1 })

        let bar = try strip(in: screen)
        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()

        screen.editor.debugTapNext()
        let carried = try #require(screen.handed.edits?["video-short"])
        #expect(abs(carried.trim.start - 60.0 / 390.0 * 4) < 0.2,
                "scaled against the wrong clip: \(carried.trim)")
        #expect(screen.handed.edits?["video-long"] == nil, "and the one behind is untouched")
    }

    /// The mirror: settling from a video onto a photograph must swap the strip
    /// for the notice, or the photograph collects a `trim` it never earned —
    /// which also moves its `MediaEdits.signature`, and therefore its thumbnail
    /// cache key.
    @Test func settlingOntoAPhotographSwapsTheStripForTheNotice() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        #expect(screen.editor.debugBand.content is MediaTrimStripView, "guard: the strip is up")

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.editor.debugBand.content is BandNoticeView })

        #expect(screen.editor.debugBand.content is BandNoticeView,
                "got \(String(describing: screen.editor.debugBand.content))")
    }

    // MARK: - A clip too short to cut

    /// ⚠️ **HANDLES THAT CANNOT MOVE ARE WORSE THAN NO HANDLES.**
    /// `MediaTrimming` will not leave less than `shortestSeconds` behind, so on
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
    @Test func aClipWithRoomToCutGetsTheStrip() async throws {
        let screen = open(Self.items(1, videosAt: [0]))

        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })

        #expect(screen.editor.debugBand.content is MediaTrimStripView)
    }

    // MARK: - VoiceOver

    /// ⚠️ **`.adjustable` IS A PROMISE.** The trait tells VoiceOver the control
    /// can be changed by swiping up or down, which calls
    /// `accessibilityIncrement`/`Decrement`. Declaring it without implementing
    /// them announces an affordance that does nothing — worse than a plain
    /// label, because the viewer is told it is there.
    @Test func voiceOverCanActuallyMoveTheTrim() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try strip(in: screen)
        let before = bar.debugTrim

        bar.accessibilityDecrement()

        #expect(bar.debugTrim != before, "the trait is declared and does nothing")
        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["video-0"] != nil,
                "and a spoken adjustment is a decision — there is no release to wait for")
    }

    @Test func voiceOverAnnouncesWhatIsKept() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try strip(in: screen)
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
        let bar = try strip(in: screen)

        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 80)
        let midDrag = bar.debugTrim

        // Exactly what the async landing does, at the worst possible moment.
        bar.configure(duration: 10, trim: .whole)

        #expect(bar.debugTrim == midDrag, "the landing moved the handle: \(bar.debugTrim)")
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
        let bar = try strip(in: screen)

        bar.debugTakeHold(at: 0)
        #expect(bar.debugHasGrip, "guard: the start handle was taken")
        bar.debugDrag(byPoints: 60)

        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["video-0"] == nil, "nothing is stored mid-drag")
    }

    @Test func releasingAHandleStoresTheTrimAndCarriesIt() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try strip(in: screen)

        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()

        screen.editor.debugTapNext()
        let carried = try #require(screen.handed.edits?["video-0"])
        #expect(carried.trim.isWhole == false, "got \(carried.trim)")
        #expect(carried.trim.start > 0, "the start moved in: \(carried.trim)")
    }

    /// A photograph on another page is untouched by a trim made here — `edits`
    /// is keyed by item and the strip only ever writes the settled one.
    @Test func trimmingOneClipLeavesTheOtherPagesAlone() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try strip(in: screen)

        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()

        screen.editor.debugTapNext()
        #expect(screen.handed.edits?["photo-1"] == nil)
    }

    /// The selection has to be visible as a selection: something dimmed on at
    /// least one side of it, or the handles are decoration.
    @Test func aTrimmedClipShowsWhatIsBeingDiscarded() async throws {
        let screen = open(Self.items(1, videosAt: [0]))
        choose(Mode.trim, on: screen)
        try await settle(until: { screen.preview.asked.isEmpty == false })
        let bar = try strip(in: screen)
        #expect(bar.debugIsDimmedBefore == false, "guard: nothing is discarded yet")

        bar.debugTakeHold(at: 0)
        bar.debugDrag(byPoints: 60)
        bar.debugRelease()
        screen.window.layoutIfNeeded()

        #expect(bar.debugIsDimmedBefore, "the discarded head is not dimmed")
        #expect(bar.debugSelectionFrame.width < bar.bounds.width,
                "the selection still spans the whole strip: \(bar.debugSelectionFrame)")
    }
}
