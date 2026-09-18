import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **ONE PAGE PLAYS, AND IT IS THE ONE THAT HAS COME TO REST.**
///
/// The canvas holds every chosen medium and recycles their cells. "Play the
/// videos" would mean a player per page, a pool this screen does not own, and
/// surfaces outliving the cells they were bound to — the exact shape of the one
/// player leak this repo has on record. So what is pinned here is not "video
/// plays" but the bookkeeping around it: who starts, who stops, and when.
///
/// ⚠️ **THE FILES NEED NOT BE REAL, AND THAT IS THE POINT OF THE SEAM.** The
/// player is stubbed, so nothing here opens a file; asking for genuine H.264
/// would buy a slower suite and no extra truth. `VideoPublishEndToEndTests` is
/// where real bytes are the subject.
@MainActor
struct MediaEditorPlaybackTests {
    private struct Screen {
        let editor: MediaEditorViewController
        let navigation: UINavigationController
        let window: UIWindow
        let preview: StubPreview
    }

    @MainActor
    private final class Handed {
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

        /// A deterministic path per id. Nothing opens it — the player is a stub —
        /// so what matters is only that the editor asked for the RIGHT one.
        static func file(for id: MediaLibraryItem.ID) -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("\(id).mov")
        }

        /// Set to make the library answer nothing, the way an iCloud clip that
        /// will not download does.
        var answersNoFile = false

        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            answersNoFile ? nil : Self.file(for: item)
        }
    }

    /// Records what it was asked to do, which is the whole subject.
    private final class StubPreview: MediaVideoPreviewing {
        private(set) var played: [URL] = []
        private(set) var stopCount = 0
        private var boundSurfaces: Set<ObjectIdentifier> = []

        /// Every arrangement the screen asked to be played.
        private(set) var plans: [VideoExportPlan] = []

        /// ⚠️ **`at()` FIRST, AND ONLY A LOAD IT ACCEPTS COUNTS AS BOUND** — the
        /// real controller binds nothing for a load its caller abandons, and the
        /// bound count is this suite's leak assertion.
        /// Where each accepted load landed, and what it looped.
        private(set) var landings: [VideoLoadLanding] = []
        func load(
            _ plan: VideoExportPlan, in surface: VideoRenderView,
            landing: @escaping @MainActor () -> VideoLoadLanding?
        ) async {
            guard let landed = landing() else { return }
            landings.append(landed)
            plans.append(plan)
            played.append(plan.sourceURL)
            boundSurfaces.insert(ObjectIdentifier(surface))
        }

        /// Every loop range the screen asked for, in order.
        private(set) var loops: [ClosedRange<Double>?] = []
        func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {
            loops.append(range)
        }

        func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {}

        func stop(_ surface: VideoRenderView) {
            stopCount += 1
            boundSurfaces.remove(ObjectIdentifier(surface))
        }

        /// Every pause and resume asked of the player, in order — the cover's
        /// whole story is told here.
        private(set) var pauses: [Bool] = []

        func setPaused(_ paused: Bool, in surface: VideoRenderView) {
            pauses.append(paused)
            self.paused = paused
        }

        /// Frames the strip can lay out, without decoding anything: the editor's
        /// subject is what it ASKS for and where it puts the answer.
        private(set) var filmstripRequests: [(file: URL, count: Int)] = []
        var answersFilmstrip = true

        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] {
            filmstripRequests.append((file, seconds.count))
            guard answersFilmstrip else { return [:] }
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                    UIColor.green.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                }
            return Dictionary(uniqueKeysWithValues: seconds.map { ($0, swatch) })
        }

        /// Playback's subject is binding and pausing, not the playhead — the
        /// track's suite is where scrubbing is asked about.
        func playheadSeconds(in surface: VideoRenderView) -> Double? { nil }
        func advancingRate(in surface: VideoRenderView) -> Double { 0 }
        /// Every live look, mute and pair of levels the screen asked for, in
        /// order — recorded, because a stub that swallowed them could not say
        /// whether the screen ever asked.
        private(set) var liveLooks: [FrameLook] = []
        func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) -> Bool {
            liveLooks.append(look)
            return takesLiveLook
        }
        /// What this backing answers — false is the legacy layer path's answer.
        var takesLiveLook = true
        private(set) var mutes: [Bool] = []
        func setMuted(_ muted: Bool, in surface: VideoRenderView) { mutes.append(muted) }
        private(set) var mixLevels: [(music: Double, original: Double)] = []
        func setMixLevels(music: Double, original: Double, in surface: VideoRenderView) {
            mixLevels.append((music, original))
        }

        func seek(
            toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double
        ) {}

        /// What the stub player says about being stopped. Tests that care set
        /// it; nil is "nothing is bound", which is neither playing nor paused.
        var paused: Bool? = false

        func isPaused(in surface: VideoRenderView) -> Bool? { paused }

        func isBound(_ surface: VideoRenderView) -> Bool {
            boundSurfaces.contains(ObjectIdentifier(surface))
        }

        /// ⚠️ **THE COUNT OF BOUND SURFACES IS THE LEAK ASSERTION.** A screen
        /// that started every page would still pass "the settled page plays";
        /// only this can say that the others did not.
        var boundCount: Int { boundSurfaces.count }
    }

    private static func items(_ count: Int, videosAt videoIndexes: Set<Int> = []) -> [MediaLibraryItem] {
        (0..<count).map { index in
            let isVideo = videoIndexes.contains(index)
            return MediaLibraryItem(
                id: isVideo ? "video-\(index)" : "photo-\(index)",
                kind: isVideo ? .video(duration: 9) : .photo
            )
        }
    }

    private func open(_ items: [MediaLibraryItem]) -> Screen {
        let handed = Handed()
        let preview = StubPreview()
        let editor = MediaEditorViewController(
            items: items, library: StubLibrary(), preview: preview
        ) { _, _ in handed.destination }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        editor.beginAppearanceTransition(true, animated: false)
        editor.endAppearanceTransition()
        window.layoutIfNeeded()
        return Screen(editor: editor, navigation: navigation, window: window, preview: preview)
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Who plays

    @Test func aVideoPageStartsPlayingWhenItSettles() async throws {
        let screen = open(Self.items(3, videosAt: [1]))

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count == 1 })

        #expect(screen.preview.played == [StubLibrary.file(for: "video-1")])
        #expect(screen.preview.boundCount == 1, "exactly one surface holds a player")
    }

    /// The witness. Without it, a preview that played nothing at all — a broken
    /// seam, a library answering nil — would satisfy every "stops" assertion
    /// below and look like careful bookkeeping.
    @Test func aPhotographPageAsksForNothing() async throws {
        let screen = open(Self.items(3, videosAt: [1]))

        screen.editor.debugScrollToPage(2)
        try await settle(until: { screen.preview.played.count == 1 })

        #expect(screen.preview.played.isEmpty, "got \(screen.preview.played)")
        #expect(screen.preview.boundCount == 0)
    }

    /// ⚠️ **THE LEAK ASSERTION.** Two videos, settled one after the other: if
    /// the first page's binding survived, `boundCount` would be two and the
    /// screen would be holding a player for a page nobody is looking at.
    @Test func swipingOnStopsTheClipBehind() async throws {
        let screen = open(Self.items(4, videosAt: [1, 2]))

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count == 1 })
        screen.editor.debugScrollToPage(2)
        try await settle(until: { screen.preview.played.count == 2 })

        #expect(screen.preview.played.last == StubLibrary.file(for: "video-2"))
        #expect(screen.preview.boundCount == 1, "one page at a time, not two")
        #expect(screen.preview.stopCount >= 1, "and the one behind was stopped")
    }

    /// ⚠️ **SETTLING IS NOT THE SAME AS ARRIVING.** The fill/fit toggle and the
    /// editing band both settle the canvas where it already is; restarting the
    /// clip on each of those would jump the playhead back to zero under the
    /// author's hand.
    @Test func settlingWhereItAlreadyWasDoesNotRestartTheClip() async throws {
        let screen = open(Self.items(3, videosAt: [1]))

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count == 1 })
        screen.editor.debugScrollToPage(1)
        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count > 1 })

        #expect(screen.preview.played.count == 1, "played \(screen.preview.played.count) times")
    }

    // MARK: - Who stops

    /// ⚠️ **CROPPING A CLIP STOPS IT, AND LEAVING PLAYS IT CROPPED.** The
    /// surface covers the canvas and the render size is about to change, so the
    /// item goes; the settle that ends the mode brings a new one, carrying the
    /// crop the author just made.
    @Test func croppingAClipStopsItAndLeavingPlaysItCropped() async throws {
        let screen = open(Self.items(3, videosAt: [1]))
        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count == 1 })
        #expect(screen.preview.boundCount == 1, "guard: it was playing")

        screen.editor.debugCategoryBar.select(4) // Crop
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugIsCropping, "crop refused the video")
        #expect(screen.preview.boundCount == 0, "the clip played on under the crop")

        let cut = MediaCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        screen.editor.debugCropSurface.onChange?(cut)
        try #require(screen.editor.debugCrop(for: "video-1") == cut,
                     "guard: the crop was not stored: \(screen.editor.debugCrop(for: "video-1"))")
        screen.editor.debugCategoryBar.select(3) // Filters — leaves the crop
        screen.window.layoutIfNeeded()
        try await settle(until: { screen.preview.played.count == 2 })

        #expect(screen.preview.plans.last?.finish.crop == cut,
                "the clip came back without its crop: \(String(describing: screen.preview.plans.last?.finish.crop))")
    }

    /// ⚠️ **A SHEET OVER THE EDITOR STOPS THE CLIP, AND UIKIT NEVER SAYS IT
    /// WENT UP.** A page sheet leaves the presenting view in the hierarchy, so
    /// the editor gets no appearance callback either way; measured with a
    /// thread sample while the song picker was up, its frame clock was still
    /// ticking and the composed reader still decoding a picture nobody could
    /// see.
    @Test func aSheetOverTheEditorStopsTheClip() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        try await settle(until: { screen.preview.played.count == 1 })
        #expect(screen.preview.paused == false, "guard: the clip is running")

        screen.editor.presentSheet(UIViewController())

        try await settle(until: { screen.preview.paused == true })
        #expect(screen.preview.paused == true, "the clip ran on behind the sheet")
        #expect(screen.editor.isCovered)
    }

    /// ⚠️ **AND NEWS OF THE SHEET GOING IS NOT TAKEN ON TRUST.** A picker says
    /// it is going from its own `viewDidDisappear`, which runs while the
    /// dismissal is still in flight — and a second sheet may be opening behind
    /// it. Nothing starts while anything is still standing over the editor.
    @Test func aClipDoesNotStartWhileSomethingIsStillCoveringIt() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        try await settle(until: { screen.preview.played.count == 1 })
        screen.editor.presentSheet(UIViewController())
        try await settle(until: { screen.preview.paused == true })

        screen.editor.sheetDidClose()
        try await Task.sleep(for: .milliseconds(120))

        #expect(screen.editor.isCovered, "guard: the sheet is still up")
        #expect(screen.preview.paused == true,
                "the clip started under a sheet: \(screen.preview.pauses)")
    }

    /// Once nothing is covering it, the clip runs again — at whatever the
    /// AUTHOR last asked for.
    @Test func theClipRunsAgainOnceNothingCoversIt() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        try await settle(until: { screen.preview.played.count == 1 })
        screen.editor.pauseUnderACover()
        #expect(screen.preview.paused == true, "guard: the cover stopped it")

        screen.editor.sheetDidClose()

        try await settle(until: { screen.preview.paused == false })
        #expect(screen.preview.paused == false,
                "the clip never started again: \(screen.preview.pauses)")
    }

    /// ⚠️ **AND A CLIP THAT ARRIVES WHILE THE COVER IS UP ARRIVES STOPPED.**
    /// The landing decides whether a fresh item runs, and it knew only about
    /// the finger and the author — so a page settling behind a sheet started
    /// decoding for nobody.
    @Test func aClipLandingBehindASheetLandsStopped() async throws {
        let screen = open(Self.items(2, videosAt: [0, 1]))
        try await settle(until: { screen.preview.played.count == 1 })
        screen.editor.presentSheet(UIViewController())
        try await settle(until: { screen.preview.paused == true })

        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count == 2 })

        #expect(screen.preview.played.count == 2, "guard: the second clip was loaded")
        #expect(screen.preview.paused == true,
                "the clip that landed behind the sheet started: \(screen.preview.pauses)")
    }

    /// ⚠️ **AND A COVER IS NOT A DECISION THE AUTHOR MADE.** A clip the author
    /// stopped themselves is still stopped when the sheet goes — the cover must
    /// never write `pausedByAuthor`, or the sheet closing would start a clip
    /// they had deliberately paused.
    @Test func aCoverDoesNotUndoTheAuthorsOwnPause() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        try await settle(until: { screen.preview.played.count == 1 })
        screen.editor.debugTapMedia()
        #expect(screen.preview.paused == true, "guard: the author stopped it")

        screen.editor.pauseUnderACover()
        screen.editor.sheetDidClose()
        try await Task.sleep(for: .milliseconds(120))

        #expect(screen.preview.paused == true,
                "the cover lifting started a clip the author had stopped: \(screen.preview.pauses)")
    }

    @Test func leavingTheScreenStopsTheClip() async throws {
        let screen = open(Self.items(3, videosAt: [1]))
        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count == 1 })
        #expect(screen.preview.boundCount == 1, "guard: it was playing")

        screen.editor.beginAppearanceTransition(false, animated: false)
        screen.editor.endAppearanceTransition()

        #expect(screen.preview.boundCount == 0, "a screen that is gone holds no player")
    }

    /// A clip that cannot be read leaves the page exactly as it was before
    /// playback existed: its poster, and no binding pretending otherwise.
    @Test func aClipThatCannotBeReadLeavesThePosterStanding() async throws {
        let handed = Handed()
        let preview = StubPreview()
        let library = StubLibrary()
        library.answersNoFile = true
        let editor = MediaEditorViewController(
            items: Self.items(3, videosAt: [1]), library: library, preview: preview
        ) { _, _ in handed.destination }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.isHidden = false
        window.layoutIfNeeded()

        editor.debugScrollToPage(1)
        try await settle(until: { preview.played.count == 1 })

        #expect(preview.played.isEmpty)
        #expect(preview.boundCount == 0)
    }
}
