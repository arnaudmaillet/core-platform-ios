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

        func play(_ file: URL, in surface: VideoRenderView) async {
            played.append(file)
            boundSurfaces.insert(ObjectIdentifier(surface))
        }

        func stop(_ surface: VideoRenderView) {
            stopCount += 1
            boundSurfaces.remove(ObjectIdentifier(surface))
        }

        func setPaused(_ paused: Bool, in surface: VideoRenderView) {}

        /// Frames the strip can lay out, without decoding anything: the editor's
        /// subject is what it ASKS for and where it puts the answer.
        private(set) var filmstripRequests: [(file: URL, count: Int)] = []
        var answersFilmstrip = true

        func filmstrip(of file: URL, count: Int, height: CGFloat) async -> [UIImage] {
            filmstripRequests.append((file, count))
            guard answersFilmstrip else { return [] }
            return (0..<count).map { _ in
                UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                    UIColor.green.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                }
            }
        }

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

    /// ⚠️ **A NOTICE MUST NOT SILENTLY STOP THE MEDIA — AND THIS TEST ASSERTED
    /// THE OPPOSITE FIRST.** It read `enteringCropStopsTheClip`, on the
    /// reasonable-sounding ground that crop lifts the picture onto its own
    /// surface. It does not, for a video: `enterCrop` refuses one and draws a
    /// line of text in the band instead, leaving the page exactly as it was. So
    /// the `stopPreview()` written into `enterCrop` for this was unreachable —
    /// dead code guarding a case that cannot happen — and the clip must carry
    /// on, or a message about an unavailable tool would look like the tool had
    /// done something.
    ///
    /// When video crop lands (`IOS_VIDEO_CAPTURE_UPLOAD` §5 P4) the refusal goes
    /// and this becomes a real decision again. It is not one today.
    @Test func choosingCropOnAVideoDrawsANoticeAndLeavesTheClipRunning() async throws {
        let screen = open(Self.items(3, videosAt: [1]))
        screen.editor.debugScrollToPage(1)
        try await settle(until: { screen.preview.played.count == 1 })
        #expect(screen.preview.boundCount == 1, "guard: it was playing")

        screen.editor.debugCategoryBar.select(4) // Crop
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugBand.content is BandNoticeView,
                "guard: crop refused the video and said so")
        #expect(screen.editor.debugIsCropping == false, "nothing was lifted")
        #expect(screen.preview.boundCount == 1, "so the clip carries on")
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
