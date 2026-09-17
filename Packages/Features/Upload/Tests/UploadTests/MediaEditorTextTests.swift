import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// Text on the editor: what opening it holds still, what typing stores, and
/// where the overlays are drawn and moved.
///
/// ⚠️ **THE KEYBOARD IS NEVER NEEDED.** The simulator this suite runs on
/// usually hides the software keyboard, so the words are put in the text view
/// directly and "Done" is the routine its button calls.
///
/// ⚠️ **NO UNIT TEST CAN DELIVER A REAL TOUCH**, so the tap arbitration is
/// pinned where a test can see it — which view a touch lands on, and what the
/// item's recogniser tells the canvas's — and the rest is a tap on a device.
@MainActor
struct MediaEditorTextTests {
    private enum Mode {
        static let effects = 0
        static let text = 1
        static let filters = 3
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
        func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) {}
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

    /// The page for `id`, once its picture has landed.
    private func page(_ id: String, on screen: Screen) async throws -> MediaEditorPageCell {
        try await settle(until: { screen.editor.pageCell(for: id)?.debugHasPicture == true })
        let page = try #require(screen.editor.pageCell(for: id))
        try #require(page.debugHasPicture, "the picture landed")
        return page
    }

    /// Types `text` through the composer, the way Add text does.
    private func addText(_ text: String, on screen: Screen, style: (MediaTextStyleBar) -> Void = { _ in }) throws {
        let mode = screen.editor.overlayMode
        mode.debugTextTools.debugTapAdd()
        let composer = try #require(mode.debugComposer)
        #expect(composer.superview === screen.editor.view, "over the editor, not presented")
        style(composer.styleBar)
        composer.debugType(text)
        composer.debugTapDone()
        screen.window.layoutIfNeeded()
    }

    // MARK: - The lock

    @Test func textModeLocksAndUnlocks() {
        let screen = open(Self.items(2))
        #expect(screen.editor.debugCanvasScrolls)

        choose(Mode.text, on: screen)
        #expect(screen.editor.debugBand.content is MediaOverlayToolsView)
        #expect(!screen.editor.debugCanvasScrolls, "no paging under a drag")
        #expect(screen.editor.debugSheetIsPinned, "no dismissal under a drag")
        #expect(screen.editor.debugSuspendedPans > 0, "no back-swipe under a drag")

        choose(Mode.effects, on: screen)
        #expect(screen.editor.debugCanvasScrolls)
        #expect(!screen.editor.debugSheetIsPinned)
        #expect(screen.editor.debugSuspendedPans == 0)
    }

    @Test func leavingTheScreenGivesTheLockBack() {
        let screen = open(Self.items(1))
        choose(Mode.text, on: screen)

        screen.editor.overlayMode.screenWillDisappear()

        #expect(screen.editor.debugCanvasScrolls)
        #expect(!screen.editor.debugSheetIsPinned)
    }

    // MARK: - Typing

    @Test func addingTextStoresAnOverlay() async throws {
        let screen = open(Self.items(1))
        let page = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)

        try addText("Hello", on: screen)

        let overlays = screen.editor.edits(for: "item-0").overlays
        try #require(overlays.count == 1)
        #expect(overlays[0].content == .text(TextOverlay(text: "Hello")))
        #expect(screen.editor.overlayMode.debugComposer == nil, "the composer is gone")
        #expect(page.overlayHost.items.map(\.id) == [overlays[0].id], "and it is drawn on the page")
        #expect(screen.editor.overlayMode.debugTextTools.cardIDs == [overlays[0].id], "with a card")
        // Held inside what can be seen.
        let visible = page.overlayHost.visibleFractions
        #expect(visible.contains(overlays[0].placement.centre), "\(overlays[0].placement) in \(visible)")
    }

    @Test func emptyTextRemovesIt() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try addText("Hello", on: screen)
        let id = try #require(screen.editor.edits(for: "item-0").overlays.first?.id)

        screen.editor.overlayMode.debugTextTools.onAction?(.edit(id: id))
        let composer = try #require(screen.editor.overlayMode.debugComposer)
        #expect(composer.textView.text == "Hello", "opens on the words it has")
        composer.debugType("   \n")
        composer.debugTapDone()

        #expect(screen.editor.edits(for: "item-0").overlays.isEmpty)
        #expect(!screen.editor.debugHasEdits(for: "item-0"), "absent means untouched again")
    }

    /// The witness: a new text left empty stores nothing at all.
    @Test func anEmptyNewTextStoresNothing() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)

        try addText("  ", on: screen)

        #expect(!screen.editor.debugHasEdits(for: "item-0"))
    }

    @Test func styleControlsStoreTheStyle() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        let red = MediaTextPalette.swatches[2].colour

        try addText("Hi", on: screen) { bar in
            bar.choose(.serif)
            bar.choose(red)
            bar.cycleBackground()
            bar.cycleAlignment()
            #expect(bar.debugFontButton(.serif)?.accessibilityLabel == "Font, Serif")
            #expect(bar.debugBackgroundButton.accessibilityLabel == "Background, Highlight")
            #expect(bar.debugAlignmentButton.accessibilityLabel == "Alignment, Right")
        }

        let stored = try #require(screen.editor.edits(for: "item-0").overlays.first)
        #expect(stored.content == .text(TextOverlay(
            text: "Hi", font: .serif, colour: red, background: .highlight, alignment: .trailing
        )))
    }

    // MARK: - On the canvas

    /// ⚠️ **THE PAGE'S PICTURE STAYS AS IT WAS; THE LAYER DRAWS THE WORDS.**
    /// Overlays are views over the page, never pixels in its picture — a picture
    /// that carried them too would show them twice once the rasteriser lands.
    @Test func canvasPageIsNotBakedButTheViewIsDrawn() async throws {
        let screen = open(Self.items(1))
        let page = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)

        try addText("Hello", on: screen) { bar in
            bar.cycleBackground()
            bar.cycleBackground()   // box
        }
        screen.editor.redraw("item-0")
        try await Task.sleep(for: .milliseconds(300))   // let the redraw land
        let item = try #require(page.overlayHost.items.first)

        let picture = try #require(page.debugPicture?.cgImage)
        let centre = Self.pixel(of: picture, x: picture.width / 2, y: picture.height / 2)
        #expect(centre.r > 200 && centre.g < 50 && centre.b < 50, "the picture is still red: \(centre)")

        let layer = page.overlayHost
        let inked = Self.render(layer, at: CGPoint(x: item.frame.minX + 3, y: item.center.y))
        #expect(inked.a > 100 && inked.r < 60, "the layer draws the box: \(inked)")
    }

    @Test func inertOutsideTheMode() async throws {
        let screen = open(Self.items(1))
        let page = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try addText("Hello", on: screen)
        let item = try #require(page.overlayHost.items.first)
        let spot = item.convert(CGPoint(x: item.bounds.midX, y: item.bounds.midY), to: screen.window)
        #expect(screen.window.hitTest(spot, with: nil) === item, "editable in Text")

        choose(Mode.filters, on: screen)

        #expect(!page.overlayHost.isUserInteractionEnabled)
        #expect(screen.window.hitTest(spot, with: nil) !== item, "inert in Filters")
        #expect(page.overlayHost.items.count == 1, "and still drawn")
    }

    @Test func overlaysFollowTheSettledPage() async throws {
        let screen = open(Self.items(2))
        let first = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try addText("One", on: screen)

        screen.editor.debugScrollToPage(1)
        let second = try await page("item-1", on: screen)

        if first !== second {
            #expect(!first.overlayHost.isEditable, "the page left behind goes inert")
        }
        #expect(second.overlayHost.isEditable, "the settled page takes touches")
        #expect(second.overlayHost.items.isEmpty, "and shows its own overlays, not the other page's")
        #expect(screen.editor.overlayMode.debugTextTools.cardIDs.isEmpty)

        try addText("Two", on: screen)
        #expect(screen.editor.edits(for: "item-1").overlays.map(\.content) == [.text(TextOverlay(text: "Two"))])
        #expect(screen.editor.edits(for: "item-0").overlays.count == 1)
    }

    @Test func voiceOverActionsMoveScaleDelete() async throws {
        let screen = open(Self.items(1))
        let page = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try addText("Hello", on: screen)
        let before = try #require(screen.editor.edits(for: "item-0").overlays.first?.placement)

        try perform("Move right", on: page)
        try perform("Bigger", on: page)
        try perform("Rotate right", on: page)
        let after = try #require(screen.editor.edits(for: "item-0").overlays.first?.placement)
        #expect(abs(after.centre.x - (before.centre.x + 0.05)) < 1e-9, "\(before.centre) → \(after.centre)")
        #expect(after.centre.y == before.centre.y)
        #expect(abs(after.scale - 1.25) < 1e-9)
        #expect(abs(after.rotation - .pi / 12) < 1e-9)

        try perform("Delete", on: page)
        #expect(screen.editor.edits(for: "item-0").overlays.isEmpty)
    }

    private func perform(_ name: String, on page: MediaEditorPageCell) throws {
        let item = try #require(page.overlayHost.items.first)
        let action = try #require(item.accessibilityCustomActions?.first { $0.name == name })
        #expect(action.actionHandler?(action) == true)
    }

    /// ⚠️ **A TAP ON AN OVERLAY IS THE OVERLAY'S, A TAP BESIDE IT IS THE
    /// CLIP'S.** The touch lands on the item, and every tap on the canvas waits
    /// for the item's to fail — so the play/pause tap cannot also fire.
    @Test func tappingAnOverlayDoesNotTogglePlayback() async throws {
        let screen = open(Self.items(1, videoAt: 0))
        let page = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try addText("Hello", on: screen)
        let item = try #require(page.overlayHost.items.first)
        let spot = item.convert(CGPoint(x: item.bounds.midX, y: item.bounds.midY), to: screen.window)

        #expect(screen.window.hitTest(spot, with: nil) === item, "the touch is the overlay's")
        let canvasTaps = sequence(first: page as UIView, next: \.superview)
            .compactMap { $0 as? UICollectionView }.first?
            .gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        try #require(!canvasTaps.isEmpty, "the canvas carries its play/pause tap")
        for tap in canvasTaps {
            #expect(item.gestureRecognizer(item.debugTap, shouldBeRequiredToFailBy: tap),
                    "the canvas's tap waits for the overlay's")
        }
        // The together-recognisers do not hold anything else back.
        for recogniser in item.debugTogetherRecognisers {
            for tap in canvasTaps {
                #expect(!item.gestureRecognizer(recogniser, shouldBeRequiredToFailBy: tap))
            }
        }

        // Beside the overlay, the touch goes through the layer to the canvas.
        let beside = CGPoint(x: spot.x, y: spot.y + 150)
        let hit = screen.window.hitTest(beside, with: nil)
        #expect(hit !== page.overlayHost && !(hit is MediaOverlayItemView), "got \(String(describing: hit))")
    }

    // MARK: - Pixels

    private static func pixel(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: -CGFloat(x), y: -CGFloat(image.height - y - 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    private static func render(_ view: UIView, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        return pixel(of: image.cgImage!, x: Int(point.x), y: Int(point.y))
    }
}
