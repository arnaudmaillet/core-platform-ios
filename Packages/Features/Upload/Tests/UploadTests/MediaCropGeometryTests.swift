import Testing
import UIKit
@testable import Upload

/// The arithmetic between a crop box on screen and the rectangle that gets
/// baked.
///
/// ⚠️ **THE INSTRUMENT HERE IS THE FOUR CORNERS, NOT THE FORMULA UNDER TEST.**
/// `MediaCropGeometry.covering` argues from bounding boxes — a leaning rectangle
/// is inside an upright one exactly when its bounds are — so a suite that
/// checked coverage the same way would be marking its own homework. `holds(_:)`
/// below carries each corner of the box into the picture's own space by hand and
/// asks whether it landed on the photograph. Two different arguments reaching
/// the same answer is the only reason to believe either.
struct MediaCropGeometryTests {
    private static let source = CGSize(width: 400, height: 300)
    private static let surface = CGRect(x: 0, y: 0, width: 390, height: 500)

    /// Whether every corner of `box` lands on the picture — computed corner by
    /// corner, deliberately unlike the code it judges.
    private func holds(_ box: CGRect, _ placement: CropPlacement, source: CGSize) -> Bool {
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
        ]
        let slack: CGFloat = 0.01
        return corners.allSatisfy { corner in
            let arm = CGPoint(x: corner.x - placement.centre.x, y: corner.y - placement.centre.y)
            let local = MediaCropGeometry.unturned(arm, by: placement.angle)
            return abs(local.x / placement.scale) <= source.width / 2 + slack
                && abs(local.y / placement.scale) <= source.height / 2 + slack
        }
    }

    private func near(_ a: CGFloat, _ b: CGFloat, _ slack: CGFloat = 0.001) -> Bool {
        abs(a - b) <= slack
    }

    private func near(_ a: CGRect, _ b: CGRect, _ slack: CGFloat = 0.001) -> Bool {
        near(a.minX, b.minX, slack) && near(a.minY, b.minY, slack)
            && near(a.width, b.width, slack) && near(a.height, b.height, slack)
    }

    // MARK: - The bounds a turned picture occupies

    @Test func turningAPictureWidensTheBoundsItNeeds() {
        let upright = MediaCropGeometry.turnedSize(of: Self.source, angle: 0)
        let leaning = MediaCropGeometry.turnedSize(of: Self.source, angle: 10)

        #expect(upright == Self.source, "an unturned picture occupies exactly itself")
        #expect(leaning.width > upright.width && leaning.height > upright.height,
                "ten degrees needs more room on both axes: got \(leaning)")
        // The numbers a reader can check by hand: 400·cos10 + 300·sin10, and the
        // same pair the other way round.
        #expect(near(leaning.width, 446.017, 0.01), "width was \(leaning.width)")
        #expect(near(leaning.height, 364.901, 0.01), "height was \(leaning.height)")
    }

    @Test func turningEitherWayNeedsTheSameRoom() {
        let clockwise = MediaCropGeometry.turnedSize(of: Self.source, angle: 12)
        let anticlockwise = MediaCropGeometry.turnedSize(of: Self.source, angle: -12)

        #expect(near(clockwise.width, anticlockwise.width, 0.0001))
        #expect(near(clockwise.height, anticlockwise.height, 0.0001))
    }

    @Test func aQuarterTurnSwapsTheSides() {
        let turned = MediaCropGeometry.turnedSize(of: Self.source, angle: 90)

        #expect(near(turned.width, Self.source.height, 0.0001), "width was \(turned.width)")
        #expect(near(turned.height, Self.source.width, 0.0001), "height was \(turned.height)")
    }

    // MARK: - Covering the box

    @Test func theCoveringScaleIsTheExactEdgeOfCoverage() {
        let box = CGRect(x: 95, y: 150, width: 200, height: 200)
        let angle: CGFloat = 10
        let edge = MediaCropGeometry.coveringScale(source: Self.source, box: box.size, angle: angle)
        let centred = CGPoint(x: box.midX, y: box.midY)

        let justEnough = CropPlacement(centre: centred, scale: edge * 1.002, angle: angle)
        let justShort = CropPlacement(centre: centred, scale: edge * 0.998, angle: angle)

        #expect(holds(box, justEnough, source: Self.source),
                "a hair above the covering scale must cover")
        #expect(!holds(box, justShort, source: Self.source),
                "a hair below it must NOT — or the scale is not the edge of anything")
        #expect(near(edge, 0.7723, 0.001), "the worked example: got \(edge)")
    }

    @Test func coveringLeavesAPlacementThatAlreadyFitsWhereItIs() {
        let box = CGRect(x: 95, y: 150, width: 200, height: 200)
        let roomy = CropPlacement(centre: CGPoint(x: box.midX, y: box.midY), scale: 2, angle: 0)

        let settled = MediaCropGeometry.covering(roomy, source: Self.source, box: box)

        #expect(settled == roomy, "nothing was wrong with it: got \(settled)")
    }

    @Test func coveringPullsBackAPictureShovedOffTheBox() {
        let box = CGRect(x: 95, y: 150, width: 200, height: 200)
        let shoved = CropPlacement(centre: CGPoint(x: 900, y: -400), scale: 1, angle: 8)

        #expect(!holds(box, shoved, source: Self.source),
                "guard: the shoved placement must really be off the box")

        let settled = MediaCropGeometry.covering(shoved, source: Self.source, box: box)

        #expect(holds(box, settled, source: Self.source), "got \(settled)")
    }

    @Test func coveringEnlargesAPictureTooSmallForTheBox() {
        let box = CGRect(x: 95, y: 150, width: 200, height: 200)
        let tiny = CropPlacement(centre: CGPoint(x: box.midX, y: box.midY), scale: 0.05, angle: 0)

        let settled = MediaCropGeometry.covering(tiny, source: Self.source, box: box)

        #expect(settled.scale > tiny.scale, "it had to grow: got \(settled.scale)")
        #expect(holds(box, settled, source: Self.source))
    }

    @Test func aCoveredBoxNeverKeepsAnythingOutsideThePicture() {
        let box = CGRect(x: 95, y: 150, width: 200, height: 260)
        for angle in stride(from: CGFloat(-45), through: 45, by: 7.5) {
            for shove in stride(from: CGFloat(-600), through: 600, by: 200) {
                let wild = CropPlacement(
                    centre: CGPoint(x: box.midX + shove, y: box.midY - shove / 2),
                    scale: 0.2, angle: angle
                )
                let settled = MediaCropGeometry.covering(wild, source: Self.source, box: box)
                let crop = MediaCropGeometry.crop(box: box, placement: settled, source: Self.source)

                // ⚠️ THE CORNER WITNESS FIRST. The two `rect` assertions below are
                // computed by `crop`, which shares its bounding-box argument with
                // `covering` — so on their own they would be the same reasoning
                // marking its own work. `holds` walks the four corners by hand.
                #expect(holds(box, settled, source: Self.source),
                        "angle \(angle) shove \(shove): a corner of the box left the picture")
                #expect(crop.rect.minX >= -0.001 && crop.rect.minY >= -0.001,
                        "angle \(angle) shove \(shove): \(crop.rect)")
                #expect(crop.rect.maxX <= 1.001 && crop.rect.maxY <= 1.001,
                        "angle \(angle) shove \(shove): \(crop.rect)")
            }
        }
    }

    // MARK: - What is framed is what is baked

    @Test func aBoxOverTheWholeTurnedPictureKeepsAllOfIt() {
        let placement = CropPlacement(centre: CGPoint(x: 200, y: 250), scale: 1, angle: 0)
        let whole = CGRect(x: 0, y: 100, width: 400, height: 300)

        let crop = MediaCropGeometry.crop(box: whole, placement: placement, source: Self.source)

        #expect(near(crop.rect, CGRect(x: 0, y: 0, width: 1, height: 1)), "got \(crop.rect)")
    }

    @Test func halfTheWidthComesOutAsHalfTheWidth() {
        let placement = CropPlacement(centre: CGPoint(x: 200, y: 250), scale: 1, angle: 0)
        let rightHalf = CGRect(x: 200, y: 100, width: 200, height: 300)

        let crop = MediaCropGeometry.crop(box: rightHalf, placement: placement, source: Self.source)

        #expect(near(crop.rect, CGRect(x: 0.5, y: 0, width: 0.5, height: 1)), "got \(crop.rect)")
    }

    @Test func theTopOfTheSurfaceIsTheTopOfTheCrop() {
        let placement = CropPlacement(centre: CGPoint(x: 200, y: 250), scale: 1, angle: 0)
        let topHalf = CGRect(x: 0, y: 100, width: 400, height: 150)

        let crop = MediaCropGeometry.crop(box: topHalf, placement: placement, source: Self.source)

        #expect(near(crop.rect.minY, 0), "a box at the top must cut from the top: got \(crop.rect)")
        #expect(near(crop.rect.height, 0.5), "got \(crop.rect)")
    }

    // MARK: - Reopening a crop shows the same photograph

    @Test func whatWasFramedComesBackFramedTheSameWay() {
        for angle in [CGFloat(0), 7, -13, 30, 90] {
            let box = MediaCropGeometry.box(ratio: 4.0 / 5.0, in: Self.surface)
            let placed = MediaCropGeometry.covering(
                CropPlacement(centre: CGPoint(x: box.midX + 20, y: box.midY - 15), scale: 1.4, angle: angle),
                source: Self.source, box: box
            )
            let crop = MediaCropGeometry.crop(box: box, placement: placed, source: Self.source)

            let again = MediaCropGeometry.framing(for: crop, source: Self.source, in: Self.surface)
            let round = MediaCropGeometry.crop(box: again.box, placement: again.placement, source: Self.source)

            #expect(near(again.box, box, 0.01), "angle \(angle): the box moved — \(again.box) vs \(box)")
            #expect(near(round.rect, crop.rect, 0.001), "angle \(angle): \(round.rect) vs \(crop.rect)")
            #expect(near(round.angle, crop.angle, 0.0001), "angle \(angle)")
        }
    }

    @Test func reopeningAnUntouchedCropShowsTheWholePictureAndNothingElse() {
        let framing = MediaCropGeometry.framing(for: .untouched, source: Self.source, in: Self.surface)
        let round = MediaCropGeometry.crop(
            box: framing.box, placement: framing.placement, source: Self.source
        )

        #expect(round.isUntouched, "got \(round)")
        #expect(near(framing.box.width / framing.box.height, 400.0 / 300.0, 0.001),
                "and the box wears the picture's own proportions: \(framing.box)")
    }

    // MARK: - Gestures, as arithmetic

    @Test func aPinchKeepsThePixelUnderTheFingersUnderTheFingers() {
        let placement = CropPlacement(centre: CGPoint(x: 200, y: 250), scale: 1, angle: 11)
        let anchor = CGPoint(x: 160, y: 300)
        let before = local(anchor, in: placement)

        let pinched = MediaCropGeometry.scaling(placement, by: 1.7, about: anchor)
        let after = local(anchor, in: pinched)

        #expect(near(pinched.scale, 1.7, 0.0001), "guard: it really did scale")
        #expect(near(before.x, after.x, 0.01) && near(before.y, after.y, 0.01),
                "\(before) became \(after)")
    }

    @Test func turningKeepsWhatTheBoxIsHoldingInTheBox() {
        let box = MediaCropGeometry.box(ratio: 1, in: Self.surface)
        let pivot = CGPoint(x: box.midX, y: box.midY)
        let placement = CropPlacement(centre: CGPoint(x: pivot.x + 40, y: pivot.y - 30), scale: 1.5, angle: 0)
        let before = local(pivot, in: placement)

        let turned = MediaCropGeometry.turning(placement, to: 14, about: pivot)
        let after = local(pivot, in: turned)

        #expect(near(turned.angle, 14, 0.0001), "guard: it really did turn")
        #expect(near(before.x, after.x, 0.01) && near(before.y, after.y, 0.01),
                "the pixel at the box's centre moved: \(before) became \(after)")
    }

    @Test func growingTheBoxBackKeepsTheSamePhotograph() {
        let dragged = CGRect(x: 120, y: 180, width: 150, height: 120)
        let placement = MediaCropGeometry.covering(
            CropPlacement(centre: CGPoint(x: dragged.midX, y: dragged.midY), scale: 0.6, angle: 9),
            source: Self.source, box: dragged
        )
        let before = MediaCropGeometry.crop(box: dragged, placement: placement, source: Self.source)

        let grown = MediaCropGeometry.reframed(box: dragged, placement: placement, in: Self.surface)
        let after = MediaCropGeometry.crop(box: grown.box, placement: grown.placement, source: Self.source)

        #expect(grown.box.width > dragged.width, "guard: it really did grow — \(grown.box)")
        #expect(near(after.rect, before.rect, 0.002), "\(after.rect) vs \(before.rect)")
    }

    // MARK: - A turn must be reversible

    /// ⚠️ **`covering` ONLY EVER ENLARGES, SO AN ABSOLUTE SCALE RATCHETS.** Turning
    /// needs more room and turning back needs less, but nothing gives the room
    /// back — a dial wiggled to and fro crept inwards a little on every pass, and
    /// four quarter turns came back to the same angle holding 56% of the
    /// photograph. Carrying the author's zoom across the turn instead is what
    /// makes it a round trip.
    @Test func turningAwayAndBackLeavesThePictureExactlyWhereItWas() {
        let box = MediaCropGeometry.box(ratio: 4.0 / 3.0, in: Self.surface)
        let start = MediaCropGeometry.covering(
            CropPlacement(centre: CGPoint(x: box.midX, y: box.midY), scale: 0.1, angle: 0),
            source: Self.source, box: box
        )
        let pivot = CGPoint(x: box.midX, y: box.midY)

        var placement = start
        for angle in [CGFloat(90), 180, 270, 0] {
            placement = MediaCropGeometry.covering(
                MediaCropGeometry.turning(
                    placement, to: angle, about: pivot, coveringBox: box, source: Self.source
                ),
                source: Self.source, box: box
            )
        }

        #expect(near(placement.scale, start.scale, 0.001),
                "four quarter turns: \(placement.scale) vs \(start.scale)")
        #expect(near(placement.centre.x, start.centre.x, 0.01))
        #expect(near(placement.centre.y, start.centre.y, 0.01))
    }

    @Test func aTurnKeepsHowFarTheAuthorHadZoomedIn() {
        let box = MediaCropGeometry.box(ratio: 1, in: Self.surface)
        let pivot = CGPoint(x: box.midX, y: box.midY)
        let zoomedIn = MediaCropGeometry.scaling(
            MediaCropGeometry.covering(
                CropPlacement(centre: pivot, scale: 0.1, angle: 0), source: Self.source, box: box
            ),
            by: 2, about: pivot
        )

        let before = MediaCropGeometry.zoom(of: zoomedIn, source: Self.source, box: box)
        let turned = MediaCropGeometry.turning(
            zoomedIn, to: 30, about: pivot, coveringBox: box, source: Self.source
        )
        let after = MediaCropGeometry.zoom(of: turned, source: Self.source, box: box)

        #expect(near(before, 2, 0.001), "guard: it really was zoomed to twice the minimum")
        #expect(near(after, before, 0.001), "and the turn kept it: \(after)")
    }

    // MARK: - The box a ratio asks for

    @Test func aRatioBoxWearsItsRatioAndStaysOnTheSurface() {
        for ratio in [CGFloat(1), 4.0 / 5.0, 16.0 / 9.0, 9.0 / 16.0] {
            let box = MediaCropGeometry.box(ratio: ratio, in: Self.surface)

            #expect(near(box.width / box.height, ratio, 0.001), "ratio \(ratio): got \(box)")
            #expect(Self.surface.insetBy(dx: -0.01, dy: -0.01).contains(box), "ratio \(ratio): got \(box)")
            #expect(near(box.midX, Self.surface.midX, 0.01) && near(box.midY, Self.surface.midY, 0.01),
                    "ratio \(ratio): not centred — \(box)")
        }
    }

    /// ⚠️ **THE DECISION BEHIND AN IDEMPOTENT CHIP, WRITTEN AS ARITHMETIC.**
    /// "From the original" means the largest rectangle of the chosen shape that
    /// fits the PICTURE at the angle it now stands — a tilted rectangle inscribed
    /// in the photograph, not the largest that fits its turned bounding box,
    /// whose corners are empty. `holds` walks the four corners by hand; the hair
    /// below the scale is what makes "largest" an edge rather than an adjective.
    @Test func fillingABoxTakesTheLargestRectangleOfItsShapeCentredOnThePicture() {
        for angle in [CGFloat(0), 12, -30, 90] {
            let box = MediaCropGeometry.box(ratio: 1, in: Self.surface)
            let placed = MediaCropGeometry.filling(
                box, source: Self.source, angle: angle, isMirrored: false
            )
            let crop = MediaCropGeometry.crop(box: box, placement: placed, source: Self.source)
            let ahair = CropPlacement(
                centre: placed.centre, scale: placed.scale * 0.998, angle: angle
            )

            #expect(holds(box, placed, source: Self.source),
                    "angle \(angle): a corner of the box left the picture")
            #expect(!holds(box, ahair, source: Self.source),
                    "angle \(angle): a hair less must NOT fit, or it is not the largest")
            #expect(near(crop.rect.midX, 0.5, 0.001) && near(crop.rect.midY, 0.5, 0.001),
                    "angle \(angle): centred on the picture — \(crop.rect)")
            #expect(near(placed.angle, angle, 0.0001), "angle \(angle): the turn is carried, not reset")
        }
    }

    /// The witness for the line above: the reflection is carried too, and it is
    /// the one field of a placement that no arithmetic here reads.
    @Test func fillingCarriesTheReflectionItWasGiven() {
        let box = MediaCropGeometry.box(ratio: 1, in: Self.surface)
        let mirrored = MediaCropGeometry.filling(
            box, source: Self.source, angle: 0, isMirrored: true
        )
        let plain = MediaCropGeometry.filling(
            box, source: Self.source, angle: 0, isMirrored: false
        )

        #expect(mirrored.isMirrored && !plain.isMirrored)
        #expect(near(mirrored.scale, plain.scale, 0.0001), "and it changes nothing else")
    }

    @Test func aRatioBoxIsAsLargeAsItCanBe() {
        let wide = MediaCropGeometry.box(ratio: 16.0 / 9.0, in: Self.surface)
        let tall = MediaCropGeometry.box(ratio: 9.0 / 16.0, in: Self.surface)

        #expect(near(wide.width, Self.surface.width, 0.01),
                "a box wider than the surface's own shape fills its width: \(wide)")
        #expect(near(tall.height, Self.surface.height, 0.01),
                "and a taller one fills its height: \(tall)")
    }

    // MARK: - Taking hold, and quarter turns

    @Test func aFingerJustOutsideAnEdgeStillTakesThatEdge() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 200)

        let justOutside = MediaCropGeometry.grip(
            at: CGPoint(x: box.minX - 10, y: box.midY), box: box, reach: 44
        )
        let farOutside = MediaCropGeometry.grip(
            at: CGPoint(x: box.minX - 200, y: box.midY), box: box, reach: 44
        )

        #expect(justOutside.contains(.left), "a handle is grabbable from both sides: \(justOutside)")
        #expect(farOutside.movesThePicture, "and far away is the picture: \(farOutside)")
    }

    @Test func aWholeAngleSplitsIntoQuarterTurnsAndFineStraightening() {
        #expect(MediaCropGeometry.split(0) == (0, 0))
        #expect(MediaCropGeometry.split(97).quarters == 1)
        #expect(near(MediaCropGeometry.split(97).fine, 7))
        #expect(MediaCropGeometry.split(-95).quarters == -1)
        #expect(near(MediaCropGeometry.split(-95).fine, -5))
        // The dial only ever holds half a quarter turn, so the split may never
        // hand it more.
        for whole in stride(from: CGFloat(-180), through: 180, by: 7) {
            #expect(abs(MediaCropGeometry.split(whole).fine) <= 45.001, "\(whole)")
        }
    }

    /// ⚠️ **THE TIE AT THE DIAL'S OWN STOP.** `Int((45 / 90).rounded())` is 1 —
    /// `.rounded()` rounds a half away from zero — so this returned one quarter
    /// turn and MINUS forty-five degrees for a picture straightened to plus
    /// forty-five. The renderer could not tell the two apart; every control could,
    /// and all four of them read wrong. 45 is exactly where the dial parks when a
    /// drag runs past its stop, so this is the ordinary case, not the exotic one.
    @Test func theDialsOwnStopIsNotAQuarterTurn() {
        #expect(MediaCropGeometry.split(45).quarters == 0, "got \(MediaCropGeometry.split(45))")
        #expect(near(MediaCropGeometry.split(45).fine, 45))
        #expect(MediaCropGeometry.split(-45).quarters == 0, "got \(MediaCropGeometry.split(-45))")
        #expect(near(MediaCropGeometry.split(-45).fine, -45))
        // And a quarter turn PLUS a full deflection still splits into the two
        // parts the two controls hold.
        #expect(MediaCropGeometry.split(135).quarters == 1, "got \(MediaCropGeometry.split(135))")
        #expect(near(MediaCropGeometry.split(135).fine, 45))
    }

    @Test func splittingAndSummingComeBackToTheSameAngle() {
        for whole in stride(from: CGFloat(-180), through: 180, by: 13) {
            let parts = MediaCropGeometry.split(whole)
            #expect(near(MediaCropGeometry.whole(quarters: parts.quarters, fine: parts.fine), whole),
                    "\(whole) split to \(parts)")
        }
    }

    @Test func aRatioLockedHandleNeverCutsBelowTheFloor() {
        let surface = Self.surface
        let box = MediaCropGeometry.box(ratio: 1, in: surface)

        let crushed = MediaCropGeometry.resized(
            box, grip: [.left, .top], by: CGPoint(x: 5000, y: 5000), ratio: 1, in: surface
        )

        #expect(crushed.width >= MediaCropGeometry.smallestBoxSide - 0.01, "\(crushed)")
        #expect(near(crushed.width / crushed.height, 1, 0.01), "and still square: \(crushed)")
    }

    /// Where a surface point lands on the picture, in the picture's own units.
    private func local(_ point: CGPoint, in placement: CropPlacement) -> CGPoint {
        let arm = CGPoint(x: point.x - placement.centre.x, y: point.y - placement.centre.y)
        let turned = MediaCropGeometry.unturned(arm, by: placement.angle)
        return CGPoint(x: turned.x / placement.scale, y: turned.y / placement.scale)
    }
}
