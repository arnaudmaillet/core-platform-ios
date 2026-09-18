import Testing
import UIKit
@testable import Upload

/// The editing surface: what a finger on the picture does to the rectangle that
/// will be baked.
@MainActor
struct MediaCropSurfaceTests {
    private static let source = CGSize(width: 400, height: 300)

    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: Self.source).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: Self.source))
        }
    }

    private func surface(crop: MediaCrop = .untouched, ratio: CropRatio = .free) -> MediaCropSurfaceView {
        let view = MediaCropSurfaceView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        view.show(picture(), crop: crop, ratio: ratio)
        view.layoutIfNeeded()
        return view
    }

    private func near(_ a: CGFloat, _ b: CGFloat, _ slack: CGFloat = 0.01) -> Bool {
        abs(a - b) <= slack
    }

    private func near(_ a: CGRect, _ b: CGRect, _ slack: CGFloat = 0.002) -> Bool {
        near(a.minX, b.minX, slack) && near(a.minY, b.minY, slack)
            && near(a.width, b.width, slack) && near(a.height, b.height, slack)
    }

    // MARK: - Where it starts

    @Test func aFreshSurfaceFramesTheWholePicture() {
        let view = surface()

        #expect(near(view.debugBox.width / view.debugBox.height, 400.0 / 300.0),
                "the box wears the picture's proportions: \(view.debugBox)")
        #expect(view.debugSurface.insetBy(dx: -0.01, dy: -0.01).contains(view.debugBox),
                "and stays inside the surface: \(view.debugBox) in \(view.debugSurface)")
        #expect(view.crop.isUntouched, "nothing has been cut yet: \(view.crop)")
    }

    @Test func aStoredCropComesBackFramedAsItWasLeft() {
        let kept = MediaCrop(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5), angle: 0)
        let view = surface(crop: kept)

        let again = MediaCropGeometry.crop(
            box: view.debugBox, placement: view.debugPlacement, source: Self.source
        )

        #expect(near(again.rect.minX, kept.rect.minX, 0.002), "got \(again.rect)")
        #expect(near(again.rect.width, kept.rect.width, 0.002), "got \(again.rect)")
        // ⚠️ **AND THE Y AXIS, WHICH IS THE ONE THAT SILENTLY LIES** — the whole
        // reason `MediaCropTests` crops a two-colour picture rather than checking
        // dimensions. An x-only assertion passes on a surface that frames the
        // bottom of the photograph when the author kept the top.
        #expect(near(again.rect.minY, kept.rect.minY, 0.002), "got \(again.rect)")
        #expect(near(again.rect.height, kept.rect.height, 0.002), "got \(again.rect)")
    }

    // MARK: - Moving the picture

    /// ⚠️ **A PICTURE THAT EXACTLY FILLS THE BOX HAS NOWHERE TO GO, AND THAT IS
    /// THE COVERING RULE DOING ITS JOB.** A fresh surface frames the whole
    /// photograph: sliding it would pull a transparent wedge into the frame, so
    /// the clamp puts it straight back. Photos behaves the same way — you zoom
    /// before you can pan. This is asserted rather than assumed because the first
    /// version of the test below was written expecting the opposite.
    @Test func aPictureThatFillsTheBoxHasNowhereToSlide() {
        let view = surface()

        view.debugBeginDrag(at: CGPoint(x: view.debugBox.midX, y: view.debugBox.midY))
        view.debugDrag(by: CGPoint(x: -60, y: 0))
        view.debugEndDrag()

        #expect(view.crop.isUntouched, "it came straight back: \(view.crop.rect)")
    }

    @Test func slidingAnEnlargedPictureChangesWhatIsKept() {
        let view = surface()
        view.debugPinch(by: 1.8, about: CGPoint(x: view.debugBox.midX, y: view.debugBox.midY))
        let before = view.crop
        var announced: [MediaCrop] = []
        view.onChange = { announced.append($0) }

        #expect(before.rect.width < 0.7, "guard: the pinch must really have zoomed in — \(before.rect)")

        view.debugBeginDrag(at: CGPoint(x: view.debugBox.midX, y: view.debugBox.midY))
        view.debugDrag(by: CGPoint(x: -60, y: 0))
        view.debugEndDrag()

        #expect(announced.count == 1, "one settled value, not sixty: \(announced.count)")
        #expect(view.crop.rect.minX > before.rect.minX,
                "sliding the picture left keeps more of its right: \(view.crop.rect) vs \(before.rect)")
    }

    /// The witness: without it the line above would pass on a surface that
    /// announced a different crop for any reason at all.
    @Test func aSlideThatComesHomeKeepsTheSameRectangle() {
        let view = surface()
        let before = view.crop

        view.debugBeginDrag(at: CGPoint(x: view.debugBox.midX, y: view.debugBox.midY))
        view.debugDrag(by: CGPoint(x: -60, y: 0))
        view.debugDrag(by: CGPoint(x: 60, y: 0))
        view.debugEndDrag()

        #expect(view.crop == before, "back where it started: \(view.crop.rect) vs \(before.rect)")
        #expect(view.crop.isUntouched, "and exactly untouched, not nearly")
    }

    // MARK: - The handles

    @Test func aCornerIsAHandleAndTheMiddleIsThePicture() {
        let view = surface()
        let box = view.debugBox

        let corner = view.debugGrip(at: CGPoint(x: box.minX, y: box.minY))
        let middle = view.debugGrip(at: CGPoint(x: box.midX, y: box.midY))

        #expect(corner.contains(.left) && corner.contains(.top), "got \(corner)")
        #expect(middle.movesThePicture, "a finger in the middle takes the picture: \(middle)")
    }

    @Test func draggingAHandleCutsAndDraggingTheMiddleDoesNot() {
        let cutting = surface()
        let moving = surface()
        let box = cutting.debugBox

        cutting.debugBeginDrag(at: CGPoint(x: box.minX, y: box.minY))
        cutting.debugDrag(by: CGPoint(x: 80, y: 60))
        cutting.debugEndDrag()
        let narrowed = cutting.crop

        moving.debugBeginDrag(at: CGPoint(x: box.midX, y: box.midY))
        moving.debugDrag(by: CGPoint(x: 80, y: 60))
        moving.debugEndDrag()

        #expect(narrowed.rect.width < 0.99 || narrowed.rect.height < 0.99,
                "a handle keeps less of the picture: \(narrowed.rect)")
        #expect(near(moving.crop.rect.width, 1, 0.02),
                "the middle keeps all of its width, it merely moves: \(moving.crop.rect)")
    }

    @Test func theBoxGrowsBackOnReleaseAndKeepsTheSamePhotograph() {
        let view = surface()
        let box = view.debugBox

        view.debugBeginDrag(at: CGPoint(x: box.minX, y: box.minY))
        view.debugDrag(by: CGPoint(x: 90, y: 70))
        let dragged = view.debugBox
        let keptWhileDragging = MediaCropGeometry.crop(
            box: dragged, placement: view.debugPlacement, source: Self.source
        )
        view.debugEndDrag()

        #expect(dragged.width < box.width, "guard: the drag must really have shrunk it")
        #expect(view.debugBox.width > dragged.width, "it grew back: \(view.debugBox)")
        #expect(near(view.crop.rect.width, keptWhileDragging.rect.width, 0.01),
                "and kept the same photograph: \(view.crop.rect) vs \(keptWhileDragging.rect)")
    }

    @Test func aHandleCannotCutThePictureDownToNothing() {
        let view = surface()
        let box = view.debugBox

        view.debugBeginDrag(at: CGPoint(x: box.minX, y: box.minY))
        view.debugDrag(by: CGPoint(x: 5000, y: 5000))

        #expect(view.debugBox.width >= MediaCropGeometry.smallestBoxSide - 0.01,
                "got \(view.debugBox)")
        #expect(view.debugBox.height >= MediaCropGeometry.smallestBoxSide - 0.01,
                "got \(view.debugBox)")
    }

    // MARK: - Shapes

    @Test func holdingTheBoxToAShapeGivesItThatShape() {
        let view = surface()

        view.choose(.square)

        #expect(near(view.debugBox.width / view.debugBox.height, 1),
                "got \(view.debugBox)")
        #expect(view.ratio == .square)
    }

    @Test func aHandleKeepsTheShapeItIsHeldTo() {
        let view = surface()
        view.choose(.square)
        let box = view.debugBox

        view.debugBeginDrag(at: CGPoint(x: box.minX, y: box.minY))
        view.debugDrag(by: CGPoint(x: 70, y: 10))

        #expect(view.debugBox.width < box.width, "guard: the drag must really have cut")
        #expect(near(view.debugBox.width / view.debugBox.height, 1, 0.02),
                "still square: \(view.debugBox)")
    }

    @Test func aFreeBoxTakesWhateverShapeItIsDraggedInto() {
        let view = surface()
        let box = view.debugBox

        view.debugBeginDrag(at: CGPoint(x: box.minX, y: box.midY))
        view.debugDrag(by: CGPoint(x: 90, y: 0))

        #expect(near(view.debugBox.height, box.height),
                "only the side that was dragged moved: \(view.debugBox) vs \(box)")
        #expect(view.debugBox.width < box.width)
    }

    // MARK: - A shape is always the same shape

    /// ⚠️ **THE REPORTED DEFECT, AS ARITHMETIC.** Choosing a shape used to settle
    /// the placement it found with `covering`, which only ever enlarges — so every
    /// tap kept whatever zoom the last shape had needed and the box crept inwards
    /// for as long as the author played with the chips. The literal rectangle is
    /// asserted, not merely "the same twice": the same twice was ALREADY true of
    /// the broken code, since a scale that has ratcheted stays ratcheted.
    ///
    /// The worked example: a 400x300 picture on a 358x468 surface, a square box of
    /// 358 points. Covering it takes 358/300, so the picture spans 477.3 points and
    /// the square keeps 358/477.3 = 0.75 of its width and all of its height.
    @Test func choosingTheSameShapeTwiceKeepsTheSameRectangle() {
        let view = surface()
        view.debugPinch(by: 2.2, about: CGPoint(x: view.debugBox.midX, y: view.debugBox.midY))
        #expect(view.crop.rect.width < 0.6, "guard: the pinch must really have zoomed in — \(view.crop.rect)")

        view.choose(.square)
        let once = view.crop
        view.choose(.square)

        #expect(near(view.crop.rect, once.rect), "twice: \(view.crop.rect) vs \(once.rect)")
        #expect(near(once.rect, CGRect(x: 0.125, y: 0, width: 0.75, height: 1)),
                "and it is the largest square the picture can give: \(once.rect)")
    }

    /// ⚠️ **A THEN B THEN A, WHICH IS WHAT THE AUTHOR ACTUALLY DID.** Under the
    /// old arithmetic the 4:5 box in the middle raised the scale from 1.193 to
    /// 1.492 and the square came back holding (0.2, 0.1, 0.6, 0.8) — 48% of the
    /// photograph — instead of the 75% one tap gives.
    ///
    /// ⚠️ **AND IT IS DONE OVER A MIRRORED PICTURE, WHICH IS THE ONLY LINE THAT
    /// CROSSES THE WIRE.** `filling` is handed the reflection to carry, and a
    /// version that simply passed `false` would be caught in this file and nowhere
    /// else in the surface's suite — the author's flip would survive every other
    /// control and quietly die on a tap of a shape.
    @Test func aShapeChosenAgainAfterAnotherLandsExactlyWhereItDidAlone() {
        let view = surface()
        view.flipAcross()
        view.choose(.square)
        let alone = view.crop

        view.choose(.portrait)
        let between = view.crop
        view.choose(.square)

        #expect(between.rect.width < alone.rect.width,
                "guard: 4:5 must really be a different rectangle — \(between.rect)")
        #expect(near(view.crop.rect, alone.rect), "\(view.crop.rect) vs \(alone.rect)")
        #expect(near(view.debugBox.width / view.debugBox.height, 1, 0.01),
                "and the box is square again: \(view.debugBox)")
        #expect(view.crop.isMirrored, "the reflection survived the shapes: \(view.crop)")
    }

    /// The report in its own words — *"ça crop de plus en plus"*. Five shapes in a
    /// row may not leave the author holding less of their photograph than one tap
    /// on the last of them.
    ///
    /// ⚠️ **THE ORDER IS CHOSEN SO THE LAST SHAPE IS NOT THE GREEDIEST, AND THE
    /// FIRST DRAFT OF THIS TEST WAS GREEN AGAINST THE BROKEN CODE FOR EXACTLY
    /// THAT REASON.** A ratcheting scale only shows when the run has already
    /// asked for MORE scale than the shape being measured needs: 9:16 wants 1.56
    /// of this picture and 1:1 wants 1.193, so a run that ends on 9:16 hides the
    /// defect perfectly. Ending on 1:1 leaves the broken code holding 44% where
    /// one tap holds 75%.
    @Test func aRunThroughFiveShapesNeverCutsDeeperThanTheLastOneAlone() {
        let alone = surface()
        alone.choose(.square)
        let target = alone.crop.rect

        let view = surface()
        for ratio in [CropRatio.portrait, .classic, .tall, .wide, .square] {
            view.choose(ratio)
        }
        let kept = view.crop.rect

        #expect(kept.width * kept.height >= target.width * target.height - 0.001,
                "five taps kept \(kept.width * kept.height), one tap keeps \(target.width * target.height)")
        #expect(near(kept, target), "and the very same rectangle: \(kept) vs \(target)")
    }

    /// ⚠️ **IDEMPOTENT *FOR THAT ANGLE*, WHICH IS THE ONLY THING IT CAN MEAN.**
    /// The straighten angle changes the bounding box `MediaCrop.rect` is measured
    /// against and changes how much picture a shape can be given, so a shape chosen
    /// over a turned picture cannot land where it lands over an upright one. What
    /// must hold is that at a FIXED angle the same tap is the same rectangle — and
    /// that the box is still inside the photograph, which at 12° is a tilted
    /// rectangle with empty corners around it.
    @Test func choosingShapesOverAStraightenedPictureIsIdempotentToo() {
        let view = surface()
        view.setAngle(12)
        view.choose(.square)
        let alone = view.crop

        view.choose(.tall)
        view.choose(.wide)
        view.choose(.square)

        #expect(view.crop.angle == 12, "guard: the straightening survived: \(view.crop.angle)")
        #expect(near(view.crop.rect, alone.rect), "\(view.crop.rect) vs \(alone.rect)")
        #expect(view.crop.rect.minX >= -0.002 && view.crop.rect.minY >= -0.002
                    && view.crop.rect.maxX <= 1.002 && view.crop.rect.maxY <= 1.002,
                "and nothing outside the picture was kept: \(view.crop.rect)")
        #expect(alone.rect.width < 0.75,
                "guard: 12° really does cost the square some width — \(alone.rect)")
    }

    /// ⚠️ **"FREE" IS THE AUTHOR'S OWN RECTANGLE AND MUST NOT BE RE-DERIVED FROM
    /// ANYTHING.** Every other chip now throws the placement away and computes
    /// from the picture; this one has no shape to compute from, and falling back
    /// to the box's current proportions would silently recentre what the author
    /// framed.
    @Test func theFreeShapeLeavesTheAuthorsOwnRectangleAlone() {
        let view = surface()
        let box = view.debugBox
        view.debugBeginDrag(at: CGPoint(x: box.minX, y: box.midY))
        view.debugDrag(by: CGPoint(x: 90, y: 0))
        view.debugEndDrag()
        let theirs = view.crop

        #expect(theirs.rect.minX > 0.05, "guard: the drag must really have kept the right side — \(theirs.rect)")

        view.choose(.free)

        #expect(view.ratio == .free)
        #expect(view.crop == theirs, "not a fraction moved: \(view.crop.rect) vs \(theirs.rect)")
    }

    // MARK: - Turning

    /// ⚠️ **"ORIGINAL" AFTER A QUARTER TURN IS THE TURNED SHAPE.** A portrait
    /// photograph on its side is a landscape one; offering its upright
    /// proportions would lay the box across the picture rather than around it.
    @Test func originalFollowsThePictureThroughAQuarterTurn() {
        let view = surface()
        view.choose(.original)
        let upright = view.debugBox.width / view.debugBox.height

        view.turnQuarter()
        view.choose(.original)
        let onItsSide = view.debugBox.width / view.debugBox.height

        #expect(near(upright, 400.0 / 300.0, 0.02), "guard: it starts at the picture's own shape")
        #expect(near(onItsSide, 300.0 / 400.0, 0.02), "and follows the turn: \(onItsSide)")
    }

    @Test func aQuarterTurnIsAQuarterTurn() {
        let view = surface()

        view.turnQuarter()

        #expect(view.debugTurn.quarters == 1)
        #expect(view.crop.angle == 90, "got \(view.crop.angle)")
    }

    /// ⚠️ **FOUR TAPS ARE A NO-OP, AND THEY HAVE TO BE EXACTLY ONE.** Without the
    /// wrap the picture came back to where it started while the stored angle read
    /// 360 — and `snapped` calls a crop untouched only at an angle of exactly
    /// zero, so the entry survived, undo stayed lit, and the post carried a full
    /// turn of a photograph nobody had turned.
    @Test func fourQuarterTurnsAreNoTurnAtAll() {
        let view = surface()

        for _ in 0..<4 { view.turnQuarter() }

        #expect(view.debugTurn.quarters == 0, "got \(view.debugTurn)")
        #expect(view.crop.isUntouched, "and it is exactly untouched: \(view.crop)")
    }

    /// ⚠️ **A PINCH IS NEVER A RESIZE.** The pan's maximum touch count is
    /// unbounded and it runs simultaneously with the pinch by design, so a
    /// two-finger gesture also begins the pan — and the grip used to be taken from
    /// the centroid of the two fingers. On a box inset 16pt from the screen, 44pt
    /// of handle band is most of where a thumb and forefinger naturally land, so
    /// zooming dragged the crop box instead.
    @Test func aTwoFingerGestureTakesThePictureAndNeverAHandle() {
        let view = surface()
        let corner = CGPoint(x: view.debugBox.minX, y: view.debugBox.minY)

        #expect(!view.debugGrip(at: corner).movesThePicture,
                "guard: one finger there really is a handle")

        view.debugBeginDrag(at: corner, fingers: 2)
        let box = view.debugBox
        view.debugDrag(by: CGPoint(x: 60, y: 60))

        #expect(near(view.debugBox.width, box.width), "the box did not move: \(view.debugBox)")
        #expect(near(view.debugBox.height, box.height))
    }

    @Test func flippingTheePictureIsAChangeAndFlippingBackIsNot() {
        let view = surface()

        view.flipAcross()
        let once = view.crop

        view.flipAcross()

        #expect(once.isMirrored, "got \(once)")
        #expect(!once.isUntouched, "a reflection is a change, not a no-op")
        #expect(!view.debugIsMirrored, "and twice is back: \(view.crop)")
        #expect(view.crop.isUntouched, "exactly untouched: \(view.crop)")
    }

    @Test func aReflectionDoesNotMoveTheBoxOrThePicture() {
        let view = surface()
        let box = view.debugBox
        let placement = view.debugPlacement

        view.flipAcross()

        #expect(near(view.debugBox.minX, box.minX), "the box stayed: \(view.debugBox)")
        #expect(near(view.debugPlacement.scale, placement.scale), "and so did the scale")
        #expect(near(view.debugPlacement.centre.x, placement.centre.x), "and the centre")
    }

    @Test func theDialAndTheQuarterTurnAddUpRatherThanReplacingEachOther() {
        let view = surface()

        view.turnQuarter()
        view.setAngle(7)

        #expect(view.crop.angle == 97, "got \(view.crop.angle)")
        #expect(view.debugTurn.fine == 7, "and the dial still holds only its own part")
    }

    @Test func whateverIsTurnedAndSlidStaysInsideThePicture() {
        let view = surface()

        for angle in stride(from: CGFloat(-45), through: 45, by: 15) {
            view.setAngle(angle)
            view.debugBeginDrag(at: CGPoint(x: view.debugBox.midX, y: view.debugBox.midY))
            view.debugDrag(by: CGPoint(x: 400, y: -300))
            view.debugEndDrag()

            #expect(view.crop.rect.minX >= -0.002 && view.crop.rect.minY >= -0.002,
                    "angle \(angle): \(view.crop.rect)")
            #expect(view.crop.rect.maxX <= 1.002 && view.crop.rect.maxY <= 1.002,
                    "angle \(angle): \(view.crop.rect)")
        }
    }

    @Test func undoingEverythingGivesBackAnExactlyUntouchedCrop() {
        let view = surface()
        view.setAngle(9)
        view.debugBeginDrag(at: CGPoint(x: view.debugBox.midX, y: view.debugBox.midY))
        view.debugDrag(by: CGPoint(x: 40, y: 20))
        view.debugEndDrag()
        #expect(!view.crop.isUntouched, "guard: it must really have been changed")

        view.reset()

        #expect(view.crop.isUntouched, "got \(view.crop)")
        #expect(view.crop == .untouched, "and identical, not merely equal-looking")
    }

    // MARK: - Whose touch it is

    @Test func theSurfaceIsAskedBeforeAnythingOutside() {
        let view = surface()
        let elsewhere = UIView()
        let sheetLikePan = UIPanGestureRecognizer()
        elsewhere.addGestureRecognizer(sheetLikePan)

        #expect(view.debugOwnsItsGestures,
                "guard: if UIKit asks someone else, the rule below never runs")
        #expect(view.debugIsAskedBefore(sheetLikePan), "an outsider waits")
    }

    @Test func butItsOwnChildrenKeepTheirOrdinaryRelationship() {
        let view = surface()
        let inside = UIView()
        view.addSubview(inside)
        let innerPan = UIPanGestureRecognizer()
        inside.addGestureRecognizer(innerPan)

        #expect(inside.isDescendant(of: view), "guard: it must really be inside")
        #expect(!view.debugIsAskedBefore(innerPan), "a child does not wait")
    }

    @Test func aHomelessRecogniserCountsAsAnOutsider() {
        let view = surface()
        let homeless = UIPanGestureRecognizer()

        #expect(homeless.view == nil, "guard: the whole point of this case is the nil")
        #expect(view.debugIsAskedBefore(homeless))
    }

    @Test func theSurfacesOwnPanAndPinchRunTogether() {
        let view = surface()

        #expect(view.debugPanAndPinchRunTogether,
                "a two-finger gesture that drifts must keep scaling")
    }
}
