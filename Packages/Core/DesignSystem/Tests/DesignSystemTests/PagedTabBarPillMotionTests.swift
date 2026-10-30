import Metal
import Testing
import UIKit
@testable import DesignSystem

/// The pill the viewer sees (`SelectorLiquidLens`, #1748): the flat fill on
/// the model at rest; the Liquid Glass lens on a press of the selected
/// segment and in a tap's flight, with the native control's measured lift,
/// rest and flight; anything that is not a travel snaps.
@MainActor
struct PagedTabBarPillMotionTests {
    private func bar() -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .floating)
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: PagedTabBar.Style.floating.height)
        bar.layoutIfNeeded()
        bar.debugEndPillLayout()
        return bar
    }

    /// The pill as drawn, in the viewport (the model's space there).
    private func drawn(_ bar: PagedTabBar) -> CGRect {
        bar.debugPillBodyFrame.offsetBy(dx: -bar.debugStripOffset, dy: 0)
    }

    @Test func atRestThePillIsTheFlatFillOnTheModel() {
        let bar = bar()
        let model = bar.debugPillInViewport
        #expect(!bar.debugPillIsLifted)
        #expect(bar.debugPillFill == 1)
        #expect(!bar.debugPillShowsGlass)
        // Idle: no display link ticking.
        #expect(!bar.debugPillIsMoving)
        #expect(abs(drawn(bar).midX - model.midX) < 0.5 && abs(drawn(bar).width - model.width) < 0.5)
    }

    @Test func swipedPagesKeepThePillOnTheModelAndFlexIt() {
        let bar = bar()
        bar.debugLetPillMove(true)
        bar.setProgress(0.1)
        bar.debugAdvancePill(frames: 2)
        bar.setProgress(0.3)
        let model = bar.debugPillInViewport
        #expect(abs(drawn(bar).midX - model.midX) < 2, "on the model at once: \(drawn(bar).midX) vs \(model.midX)")
        bar.debugAdvancePill(frames: 4)
        #expect(abs(drawn(bar).width - model.width) > 0.5, "the acceleration flexes it: \(drawn(bar).width) vs \(model.width)")
        #expect(bar.debugPillIsMoving)
        #expect(!bar.debugPillIsLifted, "a swipe does not lift the lens")

        let frames = bar.debugRunPillToRest()
        #expect(frames < 300, "the flex dies away: \(frames)")
        let plain = drawn(bar)
        #expect(abs(plain.width - model.width) < 0.5 && abs(plain.midX - model.midX) < 0.5, "plain again: \(plain) vs \(model)")
        #expect(!bar.debugPillIsMoving)
    }

    @Test func aMoveThatIsNotATravelSnaps() {
        let bar = bar()
        bar.debugLetPillMove(true)
        bar.setProgress(1)
        bar.debugRunPillToRest()

        bar.frame.size.width = 390
        bar.layoutIfNeeded()
        #expect(!bar.debugPillIsMoving, "a size change is not a travel")
        #expect(abs(drawn(bar).midX - bar.debugPillInViewport.midX) < 0.5)

        bar.setTitles(["Activity", "Gallery", "Short", "Extra"])
        bar.layoutIfNeeded()
        #expect(!bar.debugPillIsMoving, "new titles are not a travel")
        #expect(abs(drawn(bar).midX - bar.debugPillInViewport.midX) < 0.5)
    }

    /// A host placing its pages in code (a restore, a deep link) jumps the
    /// model a whole segment: the pill lands, it is not flung.
    @Test func aJumpOfTheModelLandsThePill() {
        let bar = bar()
        bar.debugLetPillMove(true)
        bar.setProgress(2)
        #expect(!bar.debugPillIsMoving)
        #expect(abs(drawn(bar).midX - bar.debugPillInViewport.midX) < 0.5)
    }

    @Test func reduceMotionNeverLifts() {
        let bar = bar()
        bar.debugLetPillMove(false)
        #expect(bar.debugBeginPillDrag(atViewportX: bar.debugPillInViewport.midX))
        #expect(!bar.debugPillIsLifted)
        bar.debugEndPillDrag()
        bar.debugSimulateTap(at: 2)
        #expect(!bar.debugPillIsLifted)
        #expect(abs(drawn(bar).midX - bar.debugPillInViewport.midX) < 0.5, "it lands at once")
    }

    @Test func aPressOnThePillLiftsTheLensAndTheReleaseRestsIt() {
        let bar = bar()
        bar.debugLetPillMove(true)
        bar.debugLetGlassDraw(true)
        let model = bar.debugPillInViewport
        #expect(bar.debugBeginPillDrag(atViewportX: model.midX))
        #expect(bar.debugPillIsLifted)

        bar.debugAdvancePill(frames: 36)   // 0.3 s: the critical spring's 0.25 s
        #expect(bar.debugPillLift > 0.97, "lifted: \(bar.debugPillLift)")
        #expect(bar.debugPillFill < 0.05, "the fill has faded to clear glass: \(bar.debugPillFill)")
        #expect(bar.debugPillShowsGlass)
        let lifted = drawn(bar)
        // The evenly outset pill, centred on it: 6pt past the capsule's top
        // and bottom, the same outset on the sides. (On screen it then rides
        // the host's live press transform, through the presentation tree.)
        let capsule = bar.debugCapsuleShape.height
        #expect(abs(lifted.height - (capsule + 12)) < 1.5, "6pt past the capsule: \(lifted.height) vs \(capsule)")
        let grown = lifted.height - model.height
        #expect(abs(lifted.width - (model.width + grown)) < 1.5, "the same outset on the sides: \(lifted.width) vs \(model.width)")
        #expect(abs(lifted.midX - model.midX) < 0.5, "centred on the pill")

        bar.debugEndPillDrag()
        bar.debugAdvancePill(frames: 6)    // 0.05 s: inside the 0.1 s hang
        #expect(bar.debugPillLift > 0.9, "it hangs a moment after the release")
        bar.debugRunPillToRest()
        #expect(!bar.debugPillIsLifted && bar.debugPillLift == 0)
        #expect(bar.debugPillFill == 1)
        #expect(!bar.debugPillShowsGlass, "at rest the flat pill shows again")
        #expect(abs(drawn(bar).width - model.width) < 0.5)
    }

    /// Dragged past the last tab, the lens follows the finger a little
    /// (rubber band, native ~9pt for 75pt) and springs back on the release.
    @Test func pastTheLastTabTheLensGivesALittleAndSpringsBack() {
        let bar = bar()
        bar.debugLetPillMove(true)
        bar.select(2)
        bar.debugRunPillToRest()
        let model = bar.debugPillInViewport
        #expect(bar.debugBeginPillDrag(atViewportX: model.midX))
        bar.debugAdvancePill(frames: 60)
        let held = drawn(bar).midX
        bar.debugDragPill(toViewportX: model.midX + 80)
        bar.debugAdvancePill(frames: 60)
        let pulled = drawn(bar).midX - held
        #expect(pulled > 4 && pulled < 13, "a little give past the end: \(pulled)")
        #expect(abs(bar.debugPillInViewport.midX - model.midX) < 0.5, "the model stays on the last tab")
        bar.debugEndPillDrag()
        bar.debugRunPillToRest()
        #expect(abs(drawn(bar).midX - model.midX) < 0.5, "back on the tab")
    }

    @Test func aTapLiftsTheLensWhichFliesAndRestsInFlight() {
        let bar = bar()
        bar.debugLetPillMove(true)
        let start = drawn(bar).midX
        bar.debugSimulateTap(at: 2)
        let target = bar.debugPillInViewport.midX
        #expect(target > start + 100, "guard: the model is on the tapped segment")
        #expect(bar.debugPillIsLifted)
        bar.debugAdvancePill(frames: 1)
        #expect(abs(drawn(bar).midX - start) < 1, "it lifts first and leaves a frame later")

        bar.debugAdvancePill(frames: 24)   // 0.2 s
        #expect(drawn(bar).midX > start + 40, "in flight: \(drawn(bar).midX)")
        bar.debugAdvancePill(frames: 12)   // 0.3 s
        #expect(!bar.debugPillIsLifted, "rested in flight, 0.19 s after the lift")

        bar.debugRunPillToRest()
        #expect(abs(drawn(bar).midX - target) < 0.5)
        #expect(bar.debugPillFill == 1)
        #expect(bar.selectedIndex == 2)
    }

    @Test func aSelectionInCodeSlidesWithoutLifting() {
        let bar = bar()
        bar.debugLetPillMove(true)
        let start = drawn(bar).midX
        bar.select(1)
        #expect(!bar.debugPillIsLifted)
        #expect(bar.debugPillIsMoving)
        bar.debugAdvancePill(frames: 3)
        #expect(drawn(bar).midX > start && drawn(bar).midX < bar.debugPillInViewport.midX, "it slides")
        bar.debugRunPillToRest()
        #expect(abs(drawn(bar).midX - bar.debugPillInViewport.midX) < 0.5)
    }
}

/// The shader compiles at run time (no `.metal` file in the package) — a
/// failure there is silent in the app, the bar just keeps its flat pill, so
/// it is pinned here — and draws the lens where it is told.
@MainActor
struct LiquidLensRendererTests {
    @Test func theShaderCompilesAndDrawsTheLensOnly() async throws {
        let renderer = LiquidLensRenderer.shared
        guard renderer.device != nil else { return }
        await renderer.ready()
        #expect(renderer.isReady, "the shader compiled")

        let target = try #require(renderer.makeTarget(width: 120, height: 60))
        var u = LiquidLensRenderer.Uniforms()
        u.viewWidth = 120; u.viewHeight = 60; u.scale = 1
        u.centreX = 60; u.centreY = 30; u.halfWidth = 40; u.halfHeight = 15
        u.tintR = 1; u.tintG = 1; u.tintB = 1; u.tintA = 1
        u.outline = 1
        u.quadMaxX = 120; u.quadMaxY = 60
        #expect(renderer.render(into: target, uniforms: u, overlay: nil))

        var pixels = [UInt8](repeating: 0, count: 120 * 60 * 4)
        target.getBytes(&pixels, bytesPerRow: 120 * 4, from: MTLRegionMake2D(0, 0, 120, 60), mipmapLevel: 0)
        func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let i = (y * 120 + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        #expect(pixel(60, 30).a == 255 && pixel(60, 30).r > 240, "the fill inside: \(pixel(60, 30))")
        #expect(pixel(2, 2).a == 0, "nothing outside: \(pixel(2, 2))")
        let rim = pixel(60, 15)
        #expect(rim.a > 0 && rim.r < pixel(60, 30).r, "a darker hairline at the rim: \(rim)")
    }
}

/// The lens on the row's line (#1905, the owner's device, 2026-10-30): pulled
/// upward, the host's presentation leans and the lens followed it ~13 pt up,
/// its title with it. The native control keeps both level with the row.
@MainActor
struct SelectorLensOnTheRowTests {
    /// The lens keeps the presentation's horizontal and size, and the row's
    /// vertical centre, whatever the lean.
    @Test func theLensTakesTheRowsLineAndTheLeansHorizontal() {
        let model = CGRect(x: 100, y: 44, width: 120, height: 40)
        // A lean: scaled about a point above the bar, so shifted up and across.
        let shown = CGRect(x: 104, y: 36, width: 126, height: 42)
        let placed = SelectorLiquidLens.onTheRow(shown: shown, model: model)
        #expect(placed.midY == model.midY, "the lens left the row's line")
        #expect(placed.minX == shown.minX && placed.width == shown.width && placed.height == shown.height)
    }

    /// Its title: at the lens's centre, the shader samples what the model
    /// puts there, whatever the presentation's scale.
    @Test(arguments: [CGFloat(1), 1.04, 0.97])
    func theTitleUnderTheLensIsTheRowsTitle(_ scale: CGFloat) {
        let lensCentreY: CGFloat = 104
        let modelOffsetY: CGFloat = -40
        let origin = SelectorLiquidLens.overlayOriginY(
            lensCentreY: lensCentreY, scale: scale, modelOffsetY: modelOffsetY
        )
        // What the shader samples at the lens's centre (`glass·scale + origin`)
        // against what the model maps there (`glass + offset`).
        #expect(abs((lensCentreY * scale + origin) - (lensCentreY + modelOffsetY)) < 0.001)
    }
}
