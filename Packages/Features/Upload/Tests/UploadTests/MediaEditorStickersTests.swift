import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// Stickers on the editor: the band's tools, the sheet a sticker is picked
/// from, and where the pick lands. The layer, the gestures and the bin are
/// text's, and `MediaEditorTextTests` asks those.
@MainActor
struct MediaEditorStickersTests {
    private enum Mode {
        static let effects = "Effects"
        static let text = "Text"
        static let stickers = "Stickers"
        static let filters = "Filters"
    }

    private struct Screen {
        let editor: MediaEditorViewController
        let navigation: UINavigationController
        let window: UIWindow
        let preview: StubPreview
    }

    private final class StubLibrary: MediaLibraryReading {
        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }
        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            FileManager.default.temporaryDirectory.appendingPathComponent("\(item).mov")
        }
        /// A red picture, 4:3 — so a filled page spills sideways.
        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
        }
    }

    private final class StubPreview: MediaVideoPreviewing {
        private(set) var pauses: [Bool] = []
        func load(
            _ plan: VideoExportPlan, in surface: VideoRenderView,
            landing: @escaping @MainActor () -> VideoLoadLanding?
        ) async { _ = landing() }
        func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {}
        func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {}
        func stop(_ surface: VideoRenderView) {}
        func setPaused(_ paused: Bool, in surface: VideoRenderView) { pauses.append(paused) }
        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] { [:] }
        func playheadSeconds(in surface: VideoRenderView) -> Double? { nil }
        func advancingRate(in surface: VideoRenderView) -> Double { 0 }
        func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) -> Bool { true }
        func setMuted(_ muted: Bool, in surface: VideoRenderView) {}
        func setMixLevels(music: Double, original: Double, in surface: VideoRenderView) {}
        func seek(toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double) {}
        func isPaused(in surface: VideoRenderView) -> Bool? { false }
        func isBound(_ surface: VideoRenderView) -> Bool { true }
    }

    private static func items(_ count: Int, videoAt video: Int? = nil) -> [MediaLibraryItem] {
        (0..<count).map { index in
            MediaLibraryItem(id: "item-\(index)", kind: index == video ? .video(duration: 9) : .photo)
        }
    }

    private func open(_ items: [MediaLibraryItem]) -> Screen {
        let preview = StubPreview()
        let destination = UIViewController()
        let editor = MediaEditorViewController(items: items, library: StubLibrary(), preview: preview) { _, _ in
            destination
        }
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

    private func choose(_ mode: String, on screen: Screen) {
        screen.editor.debugChoose(mode)
        screen.window.layoutIfNeeded()
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The page for `id`, once its picture has landed.
    private func page(_ id: String, on screen: Screen) async throws -> MediaEditorPageCell {
        try await settle(until: { screen.editor.pageCell(for: id)?.debugHasPicture == true })
        let page = try #require(screen.editor.pageCell(for: id))
        try #require(page.debugHasPicture, "the picture landed")
        return page
    }

    @Test func theStickersCategoryOpensItsOwnTools() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)

        choose(Mode.stickers, on: screen)

        let mode = screen.editor.overlayMode
        #expect(screen.editor.debugBand.content === mode.debugStickerTools,
                "got \(String(describing: screen.editor.debugBand.content))")
        #expect(mode.isOpen, "the overlays cannot be moved")
    }

    @Test func addOpensTheSheetAndAPickLandsAtTheCentreHeld() async throws {
        let screen = open(Self.items(1))
        let page = try await page("item-0", on: screen)
        choose(Mode.stickers, on: screen)
        let mode = screen.editor.overlayMode

        mode.debugStickerTools.debugTapAdd()
        let picker = try #require(mode.debugPicker, "no sheet was opened")
        picker.debugPick("Idea")

        let stored = screen.editor.edits(for: "item-0").overlays
        #expect(stored.map(\.content) == [.sticker(id: "Idea")], "stored \(stored)")
        #expect(page.overlayHost.selectedID == stored.first?.id, "the new sticker is not held")
        #expect(mode.debugStickerTools.debugFaces.count == 2, "the tools do not list it")
    }

    @Test func anEmojiIsPickedFromItsShelf() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        choose(Mode.stickers, on: screen)
        let mode = screen.editor.overlayMode
        mode.debugStickerTools.debugTapAdd()
        let picker = try #require(mode.debugPicker)

        picker.debugShow(.emoji)
        picker.debugPick("😀")

        #expect(screen.editor.edits(for: "item-0").overlays.map(\.content) == [.emoji("😀")])
    }

    /// Each band lists its own overlays: a text is not a sticker's to move.
    @Test func theStickerToolsListNoText() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        screen.editor.change("item-0") {
            $0.overlays = [FrameOverlay(content: .text(TextOverlay(text: "Hi")))]
        }
        choose(Mode.stickers, on: screen)

        #expect(screen.editor.overlayMode.debugStickerTools.debugFaces.count == 1)
    }
}
