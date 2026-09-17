import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// The screen side of Effects and of Filters on a video: what is stored, what
/// the page is redrawn with, and what the playing clip is told.
///
/// ⚠️ **THE DIALS AND THE EFFECTS DRAW NOTHING YET** — `FrameLookRenderer` draws
/// only the preset until the look pipeline's slice fills the rest. So what is
/// pinned here is what THIS slice owns: the stored edit, the redraw the page
/// gets (seen through the preset, which is real), and the live look the
/// preview is handed. Where a pixel CAN only move once the dials draw, the
/// test says so and checks it only when the renderer does.
@MainActor
struct MediaEditorEffectsTests {
    private enum Category {
        static let effects = 0
        static let filters = 3
    }

    struct Screen {
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

        /// A saturated red: the mono look turns it grey, which is what the
        /// preset-stage assertions read.
        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            let format = UIGraphicsImageRendererFormat.preferred()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
                UIColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
        }

        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            FileManager.default.temporaryDirectory.appendingPathComponent("\(item).mov")
        }
    }

    /// Records what it was asked to do, which is the whole subject.
    final class StubPreview: MediaVideoPreviewing {
        private(set) var plans: [VideoExportPlan] = []
        private(set) var liveLooks: [FrameLook] = []
        private var bound: Set<ObjectIdentifier> = []

        func load(
            _ plan: VideoExportPlan, in surface: VideoRenderView,
            landing: @escaping @MainActor () -> VideoLoadLanding?
        ) async {
            guard landing() != nil else { return }
            plans.append(plan)
            bound.insert(ObjectIdentifier(surface))
        }
        func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {}
        func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {}
        func stop(_ surface: VideoRenderView) { bound.remove(ObjectIdentifier(surface)) }
        func setPaused(_ paused: Bool, in surface: VideoRenderView) {}
        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] { [:] }
        func playheadSeconds(in surface: VideoRenderView) -> Double? { nil }
        func advancingRate(in surface: VideoRenderView) -> Double { 0 }
        func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) { liveLooks.append(look) }
        func setMuted(_ muted: Bool, in surface: VideoRenderView) {}
        func setMixLevels(music: Double, original: Double, in surface: VideoRenderView) {}
        func seek(toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double) {}
        func isPaused(in surface: VideoRenderView) -> Bool? { false }
        func isBound(_ surface: VideoRenderView) -> Bool { bound.contains(ObjectIdentifier(surface)) }
    }

    static func open(video: Bool) -> Screen {
        let preview = StubPreview()
        let item = MediaLibraryItem(id: video ? "video-0" : "photo-0", kind: video ? .video(duration: 9) : .photo)
        let editor = MediaEditorViewController(
            items: [item], library: StubLibrary(), preview: preview
        ) { _, _ in UIViewController() }
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

    static func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Opens Effects the way a first entry does: a tap on the icon that is
    /// already chosen.
    static func openEffects(on screen: Screen) throws -> MediaEffectsToolsView {
        screen.editor.debugCategoryBar.debugTap(Category.effects)
        screen.window.layoutIfNeeded()
        return try #require(screen.editor.debugBand.content as? MediaEffectsToolsView)
    }

    static func openFilters(on screen: Screen) throws -> MediaFilterRowView {
        screen.editor.debugCategoryBar.select(Category.filters)
        screen.window.layoutIfNeeded()
        return try #require(screen.editor.debugBand.content as? MediaFilterRowView)
    }

    /// Moves a slider the way a tap on its track does: one move, no drag.
    static func slide(_ tools: MediaEffectsToolsView, to value: Float) {
        let slider = tools.debugSlider.debugSlider
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }

    /// What the page is showing, read from its picture view.
    static func pagePicture(_ screen: Screen, id: String) -> UIImage? {
        guard let cell = screen.editor.pageCell(for: id) else { return nil }
        return firstImage(in: cell.contentView)
    }

    private static func firstImage(in view: UIView) -> UIImage? {
        if let picture = view as? UIImageView, let image = picture.image { return image }
        for child in view.subviews {
            if let found = firstImage(in: child) { return found }
        }
        return nil
    }

    // MARK: - Opening

    /// ⚠️ **EFFECTS IS CHOSEN AT LAUNCH OVER AN EMPTY BAND**, so the first tap
    /// on its icon is a reselect — and a mode with no tenant would stay shut.
    @Test func reselectOpensEffectsOnFirstEntry() throws {
        let screen = Self.open(video: false)
        #expect(screen.editor.debugBand.content == nil, "guard: the band starts empty")

        _ = try Self.openEffects(on: screen)

        let tenant = screen.editor.effectsMode.tenant
        #expect(tenant != nil && screen.editor.debugBand.content === tenant)
    }

    // MARK: - What is stored

    @Test func aSliderStoresAndZeroRemovesTheEntry() throws {
        let screen = Self.open(video: false)
        let tools = try Self.openEffects(on: screen)

        tools.debugTapDial(.brightness)
        #expect(tools.debugShowsSlider)
        Self.slide(tools, to: 0.4)
        let stored = screen.editor.edits(for: "photo-0").adjustments.brightness
        #expect(abs(stored - 0.4) < 0.0001, "stored \(stored)")
        #expect(tools.debugDialIsMarked(.brightness))
        #expect(screen.editor.debugCropResetItem.isEnabled, "the undo arrow has something to undo")

        tools.debugSlider.debugDoubleTapValue()
        #expect(!screen.editor.debugHasEdits(for: "photo-0"), "a dial back at rest is no entry at all")
        #expect(!screen.editor.debugCropResetItem.isEnabled)
    }

    @Test func undoResetsOnlyEffects() async throws {
        let screen = Self.open(video: false)
        let row = try Self.openFilters(on: screen)
        row.debugTap(.mono)
        let tools = try Self.openEffects(on: screen)
        tools.debugTapDial(.contrast)
        Self.slide(tools, to: -0.5)
        tools.debugTapEffect(.pixellate)

        let before = screen.editor.edits(for: "photo-0")
        #expect(before.effect?.kind == .pixellate && before.adjustments.contrast != 0, "guard")
        #expect(screen.editor.debugCropResetItem.isEnabled)
        screen.editor.debugTapReset()

        let after = screen.editor.edits(for: "photo-0")
        #expect(after.adjustments.isNeutral)
        #expect(after.effect == nil)
        #expect(after.filter == .mono, "the preset is Filters', and it stays")
        #expect(!tools.debugShowsSlider, "the slider of an effect that is gone is put away")
        #expect(tools.debugRingedEffects == [nil])
    }

    // MARK: - What the page and the clip are told

    /// ⚠️ **SEEN THROUGH THE PRESET.** The page carries mono; turning a dial
    /// must redraw it — a NEW picture, still grey — and once the dials draw,
    /// brighter.
    @Test func aPhotoPageRedrawsWithTheAdjustment() async throws {
        let screen = Self.open(video: false)
        let row = try Self.openFilters(on: screen)
        row.debugTap(.mono)
        try await Self.settle(until: { Self.pagePicture(screen, id: "photo-0").map(PixelProbe.isGrey) == true })
        let tools = try Self.openEffects(on: screen)
        tools.debugTapDial(.brightness)
        // ⚠️ **LET EVERY RENDER ALREADY ASKED FOR LAND FIRST.** Opening the
        // band re-lays the canvas, and a page re-dressed by that would read as
        // the redraw this test is about.
        try await Task.sleep(for: .milliseconds(500))
        let mono = try #require(Self.pagePicture(screen, id: "photo-0"))
        #expect(PixelProbe.isGrey(mono), "guard: the page wears mono")

        Self.slide(tools, to: 0.8)
        try await Self.settle(until: { Self.pagePicture(screen, id: "photo-0") !== mono })

        let redrawn = try #require(Self.pagePicture(screen, id: "photo-0"))
        #expect(redrawn !== mono, "the page was redrawn for the dial")
        #expect(PixelProbe.isGrey(redrawn), "and the redraw kept the preset")
        if PixelProbe.rendererDrawsBrightness {
            #expect(PixelProbe.luma(redrawn) > PixelProbe.luma(mono) + 0.05)
        }
    }

    @Test func aVideoGetsALiveLookAndNoNewItem() async throws {
        let screen = Self.open(video: true)
        try await Self.settle(until: { screen.preview.plans.count == 1 })
        try #require(screen.preview.plans.count == 1, "guard: the clip is playing")

        let tools = try Self.openEffects(on: screen)
        tools.debugTapDial(.warmth)
        Self.slide(tools, to: -0.3)
        tools.debugTapEffect(.vhs)

        let looks = screen.preview.liveLooks
        #expect(looks.count == 2, "got \(looks)")
        #expect(abs((looks.first?.adjustments.warmth ?? 0) + 0.3) < 0.0001)
        #expect(looks.last?.effect == LookEffect(kind: .vhs, intensity: 1))
        #expect(looks.last?.adjustments.warmth == looks.first?.adjustments.warmth, "the dial rides along")
        try await Task.sleep(for: .milliseconds(100))
        #expect(screen.preview.plans.count == 1, "no new item for a look")
    }

    /// ⚠️ **THE SPINNER IS SILENCED BY THIS FLAG** (`beginRender`), so the flag
    /// must be up exactly while a finger is on a slider — and come down when
    /// the band takes the tools away mid-drag, or the spinner would stay
    /// silenced for good.
    ///
    /// The spinner itself is not timed here: holding a render past its 0.15s
    /// delay could only be arranged by starving the thread pool, which was not
    /// reliable on a loaded machine.
    @Test func trackingIsHeldOnlyWhileAFingerIsDown() throws {
        let screen = Self.open(video: false)
        let tools = try Self.openEffects(on: screen)
        tools.debugTapDial(.shadows)
        let slider = tools.debugSlider.debugSlider
        let mode = screen.editor.effectsMode
        #expect(!mode.isTracking, "guard")

        slider.sendActions(for: .touchDown)
        #expect(mode.isTracking)
        slider.value = 0.5
        slider.sendActions(for: .valueChanged)
        #expect(mode.isTracking, "a move keeps the finger down")
        slider.sendActions(for: .touchUpOutside)
        #expect(!mode.isTracking)
        let lifted = screen.editor.edits(for: "photo-0").adjustments.shadows
        #expect(abs(lifted - 0.5) < 0.0001, "the lift hands over the last value")

        slider.sendActions(for: .touchDown)
        #expect(mode.isTracking)
        _ = try Self.openFilters(on: screen)
        #expect(!mode.isTracking, "a band that changes under the finger lets it go")
    }
}

/// Filters on a video: the row, the live look, and chips that wear the page's
/// look.
@MainActor
struct MediaEditorVideoFiltersTests {
    private typealias Harness = MediaEditorEffectsTests

    @Test func aVideoLookReachesTheLiveLook() async throws {
        let screen = Harness.open(video: true)
        try await Harness.settle(until: { screen.preview.plans.count == 1 })
        try #require(screen.preview.plans.count == 1, "guard: the clip is playing")

        let row = try Harness.openFilters(on: screen)
        row.debugTap(.noir)

        #expect(screen.editor.edits(for: "video-0").filter == .noir)
        #expect(screen.preview.liveLooks.last?.preset == .noir, "got \(screen.preview.liveLooks)")
        try await Task.sleep(for: .milliseconds(100))
        #expect(screen.preview.plans.count == 1, "no new item for a look")

        #expect(screen.editor.debugCropResetItem.isEnabled, "Original is one tap away")
        screen.editor.debugTapReset()
        #expect(screen.preview.liveLooks.last?.preset == .original)
        #expect(row.debugSelected == .original)
    }

    /// The chips are dressed from the clip's own poster, cut as the page is,
    /// and wear the page's dials and effect under their own preset.
    @Test func thumbnailsWearTheCurrentLook() async throws {
        let screen = Harness.open(video: true)
        try await Harness.settle(until: { screen.editor.heldPicture?.id == "video-0" })
        let tools = try Harness.openEffects(on: screen)
        tools.debugTapDial(.saturation)
        Harness.slide(tools, to: 0.6)
        tools.debugTapEffect(.comic)

        let row = try Harness.openFilters(on: screen)
        let original = try #require(row.debugPicture(for: .original))
        let mono = try #require(row.debugPicture(for: .mono))

        #expect(abs(row.dressedIn.adjustments.saturation - 0.6) < 0.0001, "got \(row.dressedIn)")
        #expect(row.dressedIn.effect?.kind == .comic)
        #expect(PixelProbe.isGrey(mono), "the mono chip wears mono")
        #expect(!PixelProbe.isGrey(original), "and Original keeps the poster's red")
    }
}

/// Pixel reads for the tests above.
@MainActor
enum PixelProbe {
    static func centre(_ image: UIImage) -> (r: Double, g: Double, b: Double) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            let size = image.size
            context.interpolationQuality = .none
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(x: 0.5 - size.width / 2, y: 0.5 - size.height / 2, width: size.width, height: size.height))
            UIGraphicsPopContext()
        }
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    static func isGrey(_ image: UIImage) -> Bool {
        let pixel = centre(image)
        return abs(pixel.r - pixel.g) < 0.04 && abs(pixel.g - pixel.b) < 0.04
    }

    static func luma(_ image: UIImage) -> Double {
        let pixel = centre(image)
        return 0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b
    }

    /// Whether `FrameLookRenderer` draws the brightness dial yet — the look
    /// pipeline's slice (S1) fills it.
    static var rendererDrawsBrightness: Bool {
        let grey = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        var look = FrameLook.neutral
        look.adjustments.brightness = 1
        return FrameLookRenderer.apply(look, to: grey, time: 0) !== grey
    }
}
