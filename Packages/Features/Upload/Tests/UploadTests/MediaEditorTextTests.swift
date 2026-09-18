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
        static let stickers = 2
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

    // MARK: - The keyboard comes with the category

    /// ⚠️ **"THE KEYBOARD IS UP" IS ASKED OF THE RESPONDER CHAIN, NOT OF A
    /// SCREENSHOT.** The software keyboard is hidden on the simulator this
    /// suite runs on (see the type's note), so the only honest reading of
    /// "the author can type" is that the composer is on screen and its text
    /// view holds first responder — which is exactly what UIKit puts a
    /// keyboard up for.
    @Test func choosingTextPutsTheKeyboardUpAtOnce() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)

        choose(Mode.text, on: screen)

        let composer = try #require(screen.editor.overlayMode.debugComposer, "a composer is up")
        #expect(composer.superview === screen.editor.view, "over the editor, not presented")
        #expect(composer.textView.isFirstResponder, "and it is the first responder")
        #expect(composer.textView.text.isEmpty, "on a new text, because the page has none")
        #expect(screen.editor.debugBand.content is MediaOverlayToolsView, "the cards are behind it")
    }

    /// The witness for the decision written into `MediaEditorOverlayMode.open`:
    /// a page that already carries text opens on the LAST one written, not on a
    /// blank composer over it — and every other text is still one tap away in
    /// the band.
    @Test func choosingTextAgainOpensTheLastTextWritten() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try addText("Hello", on: screen)
        try addText("Goodbye", on: screen)
        choose(Mode.effects, on: screen)

        choose(Mode.text, on: screen)

        let composer = try #require(screen.editor.overlayMode.debugComposer)
        #expect(composer.textView.isFirstResponder)
        #expect(composer.textView.text == "Goodbye", "the last one written, not a blank one")
        #expect(screen.editor.overlayMode.debugTextTools.cardIDs.count == 2, "and both cards are there")
        #expect(screen.editor.edits(for: "item-0").overlays.count == 2, "nothing was added by looking")
    }

    /// The other witness: Stickers shares this mode and opens no composer. Its
    /// "Add sticker" is a sheet full of pictures, and nobody asked for it to
    /// open itself.
    @Test func choosingStickersOpensNoComposer() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)

        choose(Mode.stickers, on: screen)

        #expect(screen.editor.overlayMode.debugComposer == nil)
        #expect(screen.editor.debugBand.content === screen.editor.overlayMode.debugStickerTools)
    }

    // MARK: - The one button

    /// ⚠️ **"Next" BECOMES "Done", AND NOTHING SITS UNDER IT.** The composer
    /// used to carry its own white capsule a few points below the bar's
    /// trailing item: two controls at the same corner, one dismissing the
    /// keyboard and one leaving the screen for the finalisation page.
    @Test func whileTypingTheTrailingSideSaysDoneAndTheComposerCarriesNone() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        #expect(screen.editor.navigationItem.rightBarButtonItems?.map(\.title) == ["Next"], "guard")

        choose(Mode.text, on: screen)

        #expect(screen.editor.navigationItem.rightBarButtonItems?.map(\.title) == ["Done"],
                "got \(screen.editor.navigationItem.rightBarButtonItems?.map(\.title) ?? [])")
        let composer = try #require(screen.editor.overlayMode.debugComposer)
        #expect(Self.buttonTitles(in: composer) == [],
                "the composer put a button of its own back under the bar's")
    }

    /// And tapping it finishes the sentence rather than leaving the screen.
    @Test func theHeadersDoneFinishesTheTypingAndGivesNextBack() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        let composer = try #require(screen.editor.overlayMode.debugComposer)
        composer.debugType("Hello")

        screen.editor.debugTapTheTrailingItem()
        screen.window.layoutIfNeeded()

        #expect(screen.editor.overlayMode.debugComposer == nil, "the session is over")
        #expect(screen.editor.edits(for: "item-0").overlays.count == 1, "and the words were kept")
        #expect(screen.editor.navigationItem.rightBarButtonItems?.map(\.title) == ["Next"],
                "the way forward came back")
        #expect(screen.navigation.topViewController === screen.editor,
                "Done left the screen — it is not Next wearing another word")
    }

    /// Every button title inside a view, however deep.
    private static func buttonTitles(in view: UIView) -> [String] {
        var found: [String] = []
        if let button = view as? UIButton,
           let title = button.configuration?.title ?? button.title(for: .normal) {
            found.append(title)
        }
        for child in view.subviews { found += buttonTitles(in: child) }
        return found
    }

    /// ⚠️ **THE SEAM THE BAR ITEMS READ, AND IT IS COUNTED, NOT SAMPLED.**
    /// `MediaEditorViewController.textEditingChanges` records every value it is
    /// HANDED with no deduping of its own, so a mode that said "ended" for each
    /// of `compose`'s and `close`'s calls to `finishComposing` shows up here as
    /// a third entry. See `MediaEditorHosting.textEditingDidChange`.
    @Test func theTypingSeamFiresOnceAtEachEndOfASession() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)

        choose(Mode.text, on: screen)
        #expect(screen.editor.textEditingChanges == [true], "once, on the way in")
        #expect(screen.editor.isTypingText)

        let composer = try #require(screen.editor.overlayMode.debugComposer)
        composer.debugType("Hello")
        composer.debugTapDone()

        #expect(screen.editor.textEditingChanges == [true, false], "and once on the way out")
        #expect(!screen.editor.isTypingText)

        // Leaving the mode with nothing being typed has nothing to say.
        choose(Mode.effects, on: screen)
        #expect(screen.editor.textEditingChanges == [true, false])
    }

    /// And a session abandoned by leaving the mode closes exactly once too —
    /// the path where `close` finishes the composer instead of its own button.
    @Test func leavingTheModeClosesTheTypingSessionOnce() async throws {
        let screen = open(Self.items(1))
        _ = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try #require(screen.editor.overlayMode.debugComposer != nil)

        choose(Mode.filters, on: screen)

        #expect(screen.editor.textEditingChanges == [true, false], "\(screen.editor.textEditingChanges)")
        #expect(screen.editor.overlayMode.debugComposer == nil)
    }

    /// ⚠️ **THE PAGE AND THE PAGE'S RECORD MUST NOT DISAGREE.** Every edit this
    /// mode makes goes through `store`, which writes and then draws again from
    /// what was written. A step back writes behind it, so it has to say so —
    /// `editsWereRestored` — or the words stay on the canvas and a card stays
    /// in the band for an overlay nothing stores any more.
    @Test func aStepBackTakesTheTextOffTheCanvasAndOutOfTheBand() async throws {
        let screen = open(Self.items(1))
        let page = try await page("item-0", on: screen)
        choose(Mode.text, on: screen)
        try addText("Hello", on: screen)
        try #require(screen.editor.edits(for: "item-0").overlays.count == 1)
        try #require(page.overlayHost.items.count == 1, "guard: it is drawn")
        try #require(screen.editor.debugUndoItem.isEnabled, "guard: there is a step to take")

        screen.editor.debugTapUndo()
        screen.window.layoutIfNeeded()

        #expect(screen.editor.edits(for: "item-0").overlays.isEmpty, "the record lost it")
        #expect(page.overlayHost.items.isEmpty, "and so did the canvas")
        #expect(screen.editor.overlayMode.debugTextTools.cardIDs.isEmpty, "and so did the band")
    }

    // MARK: - The style bar

    private func styleBar() -> MediaTextStyleBar {
        let bar = MediaTextStyleBar(
            frame: CGRect(x: 0, y: 0, width: 390, height: MediaTextStyleBar.height)
        )
        bar.layoutIfNeeded()
        return bar
    }

    /// ⚠️ **WHAT IS DRAWN, NOT WHAT WAS ASSIGNED.** The capsule's radius is
    /// asked of UIKit through `effectiveRadius(corner:)`, which resolves the
    /// `cornerConfiguration` the view actually carries — and the layer radius is
    /// asserted to be ZERO, because `GlassCapsule`'s note says a layer-masked
    /// radius is not part of what UIKit interpolates and flashes as a hard
    /// square for a frame.
    @Test func theStyleBarIsOneGlassCapsuleAcrossTheBar() throws {
        let bar = styleBar()

        let materials = bar.debugMaterials
        try #require(materials.count == 1, "one material, never two: \(materials.count)")
        #expect(materials[0].effect is UIGlassEffect,
                "the house material: \(String(describing: materials[0].effect))")
        #expect(bar.backgroundColor == nil || bar.backgroundColor == .clear,
                "and no plate under it: \(String(describing: bar.backgroundColor))")

        let capsule = bar.debugCapsuleFrame
        #expect(capsule.minX > 0 && capsule.maxX < bar.bounds.width,
                "inset from the window's ends, not edge to edge: \(capsule)")
        #expect(capsule.width > bar.bounds.width - 40,
                "and spanning everything but those insets: \(capsule) of \(bar.bounds.width)")
        #expect(abs(capsule.minX - (bar.bounds.width - capsule.maxX)) < 0.001, "evenly at both ends")
        #expect(capsule.minY > 0 && capsule.maxY < bar.bounds.height, "clear of the keyboard's edge")
        #expect(abs(capsule.minY - (bar.bounds.height - capsule.maxY)) < 0.001, "evenly above and below")

        #expect(abs(bar.debugCapsuleRadius(.topLeft) - capsule.height / 2) < 0.001,
                "a capsule: \(bar.debugCapsuleRadius(.topLeft)) for a \(capsule.height)pt height")
        #expect(abs(bar.debugCapsuleRadius(.bottomRight) - capsule.height / 2) < 0.001)
        #expect(bar.debugCapsuleLayerRadius == 0, "the shape is the corner configuration's, never the layer's")
    }

    /// The controls are inside the glass, and clear of the curve at its ends —
    /// a chip flush against the capsule's bounding box has its corner eaten.
    @Test func theStyleBarsControlsSitInsideTheCapsuleAndClearItsCurve() throws {
        let bar = styleBar()
        let glass = try #require(bar.debugMaterials.first)
        #expect(bar.debugScroller.superview === glass.contentView, "the row scrolls inside the glass")
        #expect(bar.debugScroller.bounds.height == bar.debugCapsuleFrame.height, "and fills it")

        let first = try #require(bar.debugFirstControlFrame)
        let radius = bar.debugCapsuleRadius(.topLeft)
        // How far in the capsule's own edge already is, level with the top of
        // the control: r − √(r² − (h/2)²).
        //
        // ⚠️ **HELD AT THE WIDEST PART OF THE CURVE, OR THE ROOT GOES
        // IMAGINARY.** A control taller than the capsule's diameter reaches
        // past the curve's own middle, where the deepest bite is the whole
        // radius; without the clamp that case answers NaN, which compares false
        // against everything and would fail this test for the wrong reason.
        let reach = min(first.height / 2, radius)
        let bite = radius - (radius * radius - reach * reach).squareRoot()
        #expect(first.minX >= bite,
                "the first control starts at \(first.minX) and the glass eats \(bite)")
    }

    /// ⚠️ **THE ROW STILL WINS FIRST REFUSAL, A LEVEL DEEPER IN THE TREE.**
    /// `ChipScrollView`'s whole reason for existing is that a drag beginning in
    /// it must be offered to it before any ancestor's pan — the sheet's
    /// dismissal, the stack's back swipe. Putting it inside a glass host moved
    /// it; the rule is about ancestry, and ancestry did not change.
    @Test func theStyleBarsRowStillWinsFirstRefusalInsideTheGlass() throws {
        let bar = styleBar()
        let scroller = try #require(bar.debugScroller as? ChipScrollView)
        let ancestor = UIView()
        let outsider = UIPanGestureRecognizer()
        ancestor.addGestureRecognizer(outsider)

        #expect(scroller.gestureRecognizer(scroller.panGestureRecognizer, shouldBeRequiredToFailBy: outsider),
                "an ancestor's pan waits for the row's")
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
