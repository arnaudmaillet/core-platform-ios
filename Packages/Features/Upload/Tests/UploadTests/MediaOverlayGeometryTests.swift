import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// Where an overlay stands on the page, and what a finger does to it.
///
/// ⚠️ **FIT AND FILL ARE BOTH ASKED, WITH NUMBERS THAT DIFFER.** A 400×200
/// picture on a 300×600 page is 300×150 fitted and 1200×600 filled, so the same
/// 30-point drag is worth a tenth of the picture in one lay and a fortieth in
/// the other — a layer that used the page's bounds instead of the picture's
/// rectangle passes neither.
@MainActor
struct MediaOverlayGeometryTests {
    private static let page = CGRect(x: 0, y: 0, width: 300, height: 600)
    private static let wide = CGSize(width: 400, height: 200)

    private func layer(fit: ContentFit, overlays: [FrameOverlay], chrome: UIEdgeInsets = .zero)
        -> (MediaOverlayLayerView, Recorder) {
        let layer = MediaOverlayLayerView(frame: Self.page)
        let recorder = Recorder()
        layer.rasterize = { _, _, _ in nil }
        layer.onEvent = { recorder.events.append($0) }
        layer.contentSize = Self.wide
        layer.fit = fit
        layer.chromeInsets = chrome
        layer.isEditable = true
        layer.show(overlays)
        layer.layoutIfNeeded()
        return (layer, recorder)
    }

    @MainActor
    private final class Recorder {
        var events: [MediaOverlayLayerView.Event] = []
        var lastPlacement: OverlayPlacement? {
            for event in events.reversed() {
                if case .placed(let overlay) = event { return overlay.placement }
            }
            return nil
        }
    }

    private static let hello = FrameOverlay(id: "hello", content: .text(TextOverlay(text: "Hello")))

    @Test func theMediaRectFitsAndFills() {
        #expect(MediaOverlayGeometry.mediaRect(contentSize: Self.wide, bounds: Self.page, fit: .fit)
                == CGRect(x: 0, y: 225, width: 300, height: 150))
        #expect(MediaOverlayGeometry.mediaRect(contentSize: Self.wide, bounds: Self.page, fit: .fill)
                == CGRect(x: -450, y: 0, width: 1200, height: 600))
    }

    @Test(arguments: [
        (ContentFit.fit, CGPoint(x: 0.6, y: 0.6)),
        (ContentFit.fill, CGPoint(x: 0.525, y: 0.525))
    ])
    func panMovesThePlacementInMediaSpace(fit: ContentFit, expected: CGPoint) throws {
        let (layer, recorder) = layer(fit: fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let before = item.center

        layer.item(item, panned: .began, by: CGPoint(x: 10, y: 5), at: .zero)
        layer.item(item, panned: .changed, by: CGPoint(x: 20, y: 10), at: .zero)
        layer.item(item, panned: .ended, by: .zero, at: .zero)

        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.centre.x - expected.x) < 1e-9, "x: \(placed.centre.x)")
        #expect(abs(placed.centre.y - expected.y) < 1e-9, "y: \(placed.centre.y)")
        // And the view went exactly where the finger did.
        #expect(abs(item.center.x - before.x - 30) < 0.001 && abs(item.center.y - before.y - 15) < 0.001,
                "moved from \(before) to \(item.center)")
    }

    /// A filled picture spills past the page: a drag is held inside what can
    /// be seen, so an overlay cannot be pushed where nobody can grab it again.
    @Test func aDragIsHeldInsideTheVisiblePicture() throws {
        let (layer, recorder) = layer(fit: .fill, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, panned: .began, by: CGPoint(x: 1000, y: 0), at: .zero)
        layer.item(item, panned: .ended, by: .zero, at: .zero)

        // The page shows x from 450 to 750 of 1200.
        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.centre.x - 0.625) < 1e-9, "x: \(placed.centre.x)")
    }

    /// With the chrome over the lower two thirds, the middle of the picture is
    /// hidden: a new overlay is held at the foot of what is left.
    @Test func aNewOverlayIsClampedIntoTheVisiblePart() {
        let (covered, _) = layer(fit: .fill, overlays: [], chrome: UIEdgeInsets(top: 0, left: 0, bottom: 400, right: 0))
        #expect(abs(covered.newCentre.y - 1.0 / 3) < 1e-9, "\(covered.newCentre)")
        #expect(abs(covered.newCentre.x - 0.5) < 1e-9)

        // The witness: nothing covered, the middle it is.
        let (clear, _) = layer(fit: .fill, overlays: [])
        #expect(clear.newCentre == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func pinchScales() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let base = item.bounds.width

        layer.item(item, pinched: .began, by: 1.5)
        layer.item(item, pinched: .ended, by: 1.5)

        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.scale - 2.25) < 1e-9, "scale: \(placed.scale)")
        #expect(abs(item.transform.a - 2.25) < 1e-9, "the view wears it: \(item.transform)")
        #expect(abs(item.frame.width - base * 2.25) < 0.01, "and is that much wider on screen")
    }

    @Test func aPinchIsHeldInsideItsRange() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, pinched: .ended, by: 100)

        #expect(recorder.lastPlacement?.scale == MediaOverlayGeometry.scaleRange.upperBound)
    }

    /// Clockwise as the viewer sees it: in UIKit's y-down space, a positive
    /// angle has a positive `b`.
    @Test func rotateRotates() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, rotated: .began, by: .pi / 8)
        layer.item(item, rotated: .ended, by: .pi / 8)

        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.rotation - .pi / 4) < 1e-9, "rotation: \(placed.rotation)")
        #expect(abs(atan2(item.transform.b, item.transform.a) - .pi / 4) < 1e-9)
        #expect(item.transform.b > 0, "clockwise on screen")
    }

    @Test func trashDeletes() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let bin = layer.trash.center

        layer.item(item, panned: .began, by: .zero, at: item.center)
        #expect(!layer.trash.isHidden, "the bin shows for a drag")
        layer.item(item, panned: .changed, by: .zero, at: bin)
        #expect(layer.trash.isArmed)
        layer.item(item, panned: .ended, by: .zero, at: bin)

        #expect(recorder.events.last == .delete(id: "hello"), "\(recorder.events)")
    }

    /// The witness: the same drag, let go away from the bin, only moves.
    @Test func aDropBesideTheTrashKeepsTheOverlay() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let beside = CGPoint(x: layer.trash.center.x, y: layer.trash.center.y - 120)

        layer.item(item, panned: .began, by: .zero, at: item.center)
        layer.item(item, panned: .ended, by: .zero, at: beside)

        #expect(!recorder.events.contains(.delete(id: "hello")))
        #expect(recorder.lastPlacement != nil)
    }

    // MARK: - Snapping, as arithmetic

    /// A 300×150 fitted picture on the 300×600 page — the rectangle the point
    /// windows below are worked out in.
    private static let fitted = MediaOverlayGeometry.mediaRect(
        contentSize: wide, bounds: page, fit: .fit
    )
    /// The whole picture visible, for a snap that nothing clamps.
    private static let everywhere = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Halfway between two right angles, so a centring test is not quietly also
    /// an angle test.
    private static let tilted = Double.pi / 4

    /// A centre `points` off the middle of the fitted picture, on both axes.
    ///
    /// ⚠️ **THE OFFSET IS IN POINTS AND THE FRACTIONS ARE WORKED OUT FROM IT**,
    /// which is the whole claim the rule makes: the same 7pt is 0.0233 of the
    /// 300pt width and 0.0467 of the 150pt height. A test written in fractions
    /// could not tell the two apart.
    private static func off(_ points: CGFloat) -> OverlayPlacement {
        OverlayPlacement(
            centre: CGPoint(x: 0.5 + points / fitted.width, y: 0.5 - points / fitted.height),
            rotation: tilted
        )
    }

    /// ⚠️ **THE NUMBERS ARE WRITTEN DOWN, NOT DERIVED FROM THE CONSTANT.** An
    /// earlier cut said "`centreReach` × 0.99" and "× 1.01", which moves its own
    /// goalposts: shrinking the window to 2pt kept it green, because the inputs
    /// shrank with it. 7pt in and 9pt out pin the 8pt window itself.
    @Test func aCentreSnapsAtSevenPointsOutAndNotAtNine() {
        let caught = MediaOverlayGeometry.snapped(Self.off(7), in: Self.fitted, visible: Self.everywhere)
        #expect(caught.placement.centre == CGPoint(x: 0.5, y: 0.5), "\(caught.placement.centre)")
        #expect(caught.marks == [.centredAcross, .centredDown])

        let nine = Self.off(9)
        let free = MediaOverlayGeometry.snapped(nine, in: Self.fitted, visible: Self.everywhere)
        #expect(free.placement.centre == nine.centre, "a point off the window is left where it was")
        #expect(free.marks.isEmpty)
    }

    /// One axis at a time: an overlay 4pt off the middle sideways but a third of
    /// the picture below it is centred one way only.
    @Test func eachCentreAxisSnapsOnItsOwn() {
        let onlyAcross = OverlayPlacement(
            centre: CGPoint(x: 0.5 + 4 / Self.fitted.width, y: 0.8), rotation: Self.tilted
        )

        let snapped = MediaOverlayGeometry.snapped(onlyAcross, in: Self.fitted, visible: Self.everywhere)

        #expect(snapped.placement.centre.x == 0.5)
        #expect(snapped.placement.centre.y == 0.8, "the other axis is untouched")
        #expect(snapped.marks == .centredAcross)
    }

    /// ⚠️ **THE CLAMP COMES AFTER THE SNAP, AND A CLAMPED AXIS LIGHTS NOTHING.**
    /// With the chrome over the lower two thirds of a filled picture, the
    /// middle of it cannot be reached: pulling the centre there would put the
    /// overlay where nobody can grab it again, so `visible` wins — and the
    /// guide must not claim a middle the overlay is not on.
    @Test func aCentreTheChromeCoversIsClampedAndLightsNothing() {
        let filled = MediaOverlayGeometry.mediaRect(contentSize: Self.wide, bounds: Self.page, fit: .fill)
        let visible = MediaOverlayGeometry.visibleFractions(
            mediaRect: filled, window: CGRect(x: 0, y: 0, width: 300, height: 200)
        )
        let middle = OverlayPlacement(centre: CGPoint(x: 0.5, y: 0.5), rotation: Self.tilted)

        let snapped = MediaOverlayGeometry.snapped(middle, in: filled, visible: visible)

        #expect(snapped.placement.centre.x == 0.5, "sideways, the middle is reachable")
        #expect(abs(snapped.placement.centre.y - 1.0 / 3) < 1e-9,
                "down, it is held at the foot of what is left: \(snapped.placement.centre)")
        #expect(snapped.marks == .centredAcross, "and only the axis that landed lights: \(snapped.marks)")
    }

    /// The four right angles, each side of each one, and the full turn with
    /// them — `rotated` keeps a rotation within one turn either way, so 356° is
    /// a real value that has to fall into 360 rather than into 0.
    ///
    /// ⚠️ **4° AND 6°, WRITTEN DOWN, NOT `squareReach` × 0.99 AND × 1.01.** A
    /// window stated relative to the constant it is testing widens and narrows
    /// with it and can never fail.
    @Test(arguments: [-270.0, -180.0, -90.0, 0.0, 90.0, 180.0, 270.0, 360.0])
    func aTurnSnapsWithinFiveDegreesOfARightAngleAndNotBeyond(degrees: Double) throws {
        let target = degrees * .pi / 180

        for side in [1.0, -1.0] {
            let inside = try #require(
                MediaOverlayGeometry.squared((degrees + side * 4) * .pi / 180),
                "\(degrees)° \(side > 0 ? "+" : "−") 4° should be square"
            )
            #expect(abs(inside - target) < 1e-9, "snapped to \(inside * 180 / .pi)°, wanted \(degrees)°")

            #expect(MediaOverlayGeometry.squared((degrees + side * 6) * .pi / 180) == nil,
                    "\(degrees)° \(side > 0 ? "+" : "−") 6° is a tilt the author meant")
        }
    }

    /// And halfway between two detents is nobody's right angle.
    @Test func aTurnBetweenTwoRightAnglesSnapsToNeither() {
        #expect(MediaOverlayGeometry.squared(.pi / 4) == nil)
        #expect(MediaOverlayGeometry.squared(-3 * .pi / 4) == nil)
    }

    /// ⚠️ **ON THE WAY IN, ONCE.** A `!=` here would click on the way out too,
    /// which is twice per detent crossed.
    @Test func aTickIsOwedOnlyForAMarkThatJustLit() {
        #expect(MediaOverlayGeometry.ticks(from: [], to: .centredAcross))
        #expect(!MediaOverlayGeometry.ticks(from: .centredAcross, to: .centredAcross),
                "not once per sample")
        #expect(!MediaOverlayGeometry.ticks(from: .centredAcross, to: []), "nothing on the way out")
        #expect(MediaOverlayGeometry.ticks(from: .centredAcross, to: [.centredAcross, .square]),
                "a second mark is its own tick")
    }

    // MARK: - Snapping, under a finger

    /// An overlay parked well off the middle and nowhere near a right angle, so
    /// a gesture starts with nothing lit.
    private static func parked(_ item: MediaOverlayItemView) {
        item.setPlacement(
            OverlayPlacement(centre: CGPoint(x: 0.2, y: 0.2), rotation: tilted), redraw: false
        )
    }

    /// ⚠️ **ONE TICK PER SNAP, WHATEVER THE SAMPLE RATE.** Thirty-six samples
    /// carry the overlay through the middle; the window is about three of them
    /// wide, and the hand is told once.
    @Test func oneTickPerSnapAndNoneForLeavingIt() throws {
        let (layer, _) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        Self.parked(item)

        layer.item(item, panned: .began, by: .zero, at: .zero)
        #expect(layer.debugTicks == 0, "landing on nothing owes nothing")

        // 180pt right, in 5pt steps: 0.2 of the picture to 0.8 of it, straight
        // through the middle.
        for _ in 0..<36 { layer.item(item, panned: .changed, by: CGPoint(x: 5, y: 0), at: .zero) }
        #expect(layer.debugTicks == 1, "one tick for the middle, not one per sample")

        for _ in 0..<36 { layer.item(item, panned: .changed, by: CGPoint(x: -5, y: 0), at: .zero) }
        #expect(layer.debugTicks == 2, "and one more coming back through it")

        layer.item(item, panned: .ended, by: .zero, at: .zero)
        #expect(layer.debugTicks == 2, "letting go is silent")
    }

    /// ⚠️ **A GESTURE THAT LANDS ON A SNAP OWES NOTHING.** Every overlay is
    /// born in the middle of the picture; a tick for touching one would fire on
    /// the first sample of every drag ever made.
    @Test func touchingAnOverlayThatIsAlreadySnappedIsSilent() throws {
        let (layer, _) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, panned: .began, by: .zero, at: .zero)
        layer.item(item, panned: .changed, by: .zero, at: .zero)

        #expect(layer.debugTicks == 0)
        #expect(layer.debugGuides.count == 2, "though the guides do say where it is")
    }

    /// ⚠️ **THE RAW PLACEMENT IS WHAT THE FINGERS ADVANCE.** Feeding the
    /// snapped value back in makes every detent a trap: at a drawn 0° a further
    /// 2° is 2°, which snaps to 0° again, for ever. Four two-degree steps have
    /// to leave the detent behind.
    @Test func aSnapDoesNotTrapTheOverlayInsideIt() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let step = 2 * Double.pi / 180

        layer.item(item, rotated: .began, by: 0)
        for _ in 0..<2 { layer.item(item, rotated: .changed, by: step) }
        #expect(item.overlay.placement.rotation == 0, "4° off square is drawn square")
        #expect(abs((layer.debugRawPlacement?.rotation ?? 0) - 2 * step) < 1e-9,
                "but the fingers' own angle is kept: \(String(describing: layer.debugRawPlacement))")

        for _ in 0..<2 { layer.item(item, rotated: .changed, by: step) }
        layer.item(item, rotated: .ended, by: 0)

        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.rotation - 4 * step) < 1e-9,
                "eight degrees out of the detent: \(placed.rotation * 180 / .pi)°")
    }

    /// The mark while it is snapped: two lines through the middle of the
    /// picture, drawn only while an overlay rests on them.
    @Test func theGuidesAreDrawnOnlyWhileTheOverlayRestsOnTheMiddle() throws {
        let (layer, _) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        Self.parked(item)

        layer.item(item, panned: .began, by: .zero, at: .zero)
        #expect(layer.debugGuides.isEmpty, "nothing is drawn off the middle")

        // 0.3 of a 300pt-wide picture across, 0.3 of a 150pt-tall one down.
        layer.item(item, panned: .changed, by: CGPoint(x: 90, y: 45), at: .zero)

        let guides = layer.debugGuides
        try #require(guides.count == 2, "both middles: \(guides)")
        let rect = layer.mediaRect
        #expect(guides.contains { abs($0.midX - rect.midX) < 0.001 && $0.height >= rect.height - 0.001 },
                "a line down the middle: \(guides)")
        #expect(guides.contains { abs($0.midY - rect.midY) < 0.001 && $0.width >= rect.width - 0.001 },
                "and one across it: \(guides)")
        #expect(item.debugOutlineDash != nil, "45° is not square, so the outline stays dashed")

        layer.item(item, panned: .ended, by: .zero, at: .zero)
        #expect(layer.debugGuides.isEmpty, "and they go with the fingers")
    }

    /// ⚠️ **ONE GESTURE IS ONE STEP IN THE AUTHOR'S HISTORY.** Pan, pinch and
    /// rotation are allowed to run together and each ends on its own clock;
    /// storing from every `.ended` filed a single two-fingered move two and
    /// three times, and the back arrow walked the author through the middle of
    /// their own gesture.
    @Test func aTwoFingeredGestureIsStoredOnce() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, pinched: .began, by: 1.2)
        layer.item(item, rotated: .began, by: 0.3)
        layer.item(item, pinched: .changed, by: 1.1)
        layer.item(item, rotated: .changed, by: 0.1)
        layer.item(item, pinched: .ended, by: 1)
        #expect(recorder.events.isEmpty, "the pinch let go, the turn has not: \(recorder.events)")

        layer.item(item, rotated: .ended, by: 0)

        #expect(recorder.events.count == 1, "\(recorder.events)")
        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.scale - 1.32) < 1e-9, "and it carries both fingers: \(placed.scale)")
        #expect(abs(placed.rotation - 0.4) < 1e-9, "\(placed.rotation)")
    }

    /// The angle's own mark: the selection outline stops being dashed.
    @Test func aSquareTurnSolidifiesTheOutlineAndDashesItAgain() throws {
        let (layer, _) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        Self.parked(item)

        layer.item(item, rotated: .began, by: 0)
        #expect(item.debugOutlineDash != nil, "45° is nobody's right angle")

        layer.item(item, rotated: .changed, by: 41 * .pi / 180)   // 86°
        #expect(item.debugOutlineDash == nil, "square: the dash goes")
        #expect(layer.debugTicks == 1)

        layer.item(item, rotated: .changed, by: 10 * .pi / 180)   // 96°
        #expect(item.debugOutlineDash != nil, "and comes back on the way out")
        #expect(layer.debugTicks == 1, "leaving a snap is silent")
    }
}
