import UIKit

/// Where the picture sits under the crop box.
///
/// The interaction is the one Photos uses and the one people expect: the box
/// stands still and the PICTURE moves under it. A pan slides the picture, a
/// pinch scales it, the dial turns it — and the rectangle the author keeps is
/// whatever the box happens to be framing when they stop.
///
/// ⚠️ **`scale` MAPS SOURCE UNITS TO SURFACE POINTS, AND NOTHING ELSE MUST.**
/// Every function here mixes the two spaces, so the unit has to be stated once
/// and obeyed: `source` is in whatever units the caller measures the picture in
/// (its point size), and a placement of `scale` draws one of those units as
/// `scale` points on screen.
struct CropPlacement: Equatable {
    /// The centre of the picture, in the surface's coordinates.
    var centre: CGPoint

    /// How much the source is enlarged to reach the surface.
    var scale: CGFloat

    /// ⚠️ **THE SAME NUMBER AND THE SAME DIRECTION AS `MediaCrop.angle`** —
    /// degrees, positive turning the picture clockwise as the viewer sees it. A
    /// UIKit `CGAffineTransform(rotationAngle:)` of `+a` in radians turns a view
    /// clockwise on screen (y points down), and `MediaCropRenderer` negates for
    /// Core Image's y-up space to reach the same place. So the view transform,
    /// this field and the baked crop all carry the identical sign, and none of
    /// the three needs a flip the other two do not.
    var angle: CGFloat

    /// Whether the picture is shown as its own reflection — see
    /// `MediaCrop.isMirrored`.
    ///
    /// ⚠️ **IT CHANGES NOTHING IN THIS FILE'S ARITHMETIC, AND THAT IS THE POINT
    /// OF CARRYING IT AS A FLAG.** A reflection about the picture's own centre
    /// maps the source rectangle onto itself, so the bounds a turn needs, the
    /// scale that covers the box and the room a slide has are all identical
    /// either way. Only two places read it: the transform the surface hands to
    /// UIKit, and the `MediaCrop` this file emits.
    var isMirrored: Bool

    init(centre: CGPoint, scale: CGFloat, angle: CGFloat, isMirrored: Bool = false) {
        self.centre = centre
        self.scale = scale
        self.angle = angle
        self.isMirrored = isMirrored
    }
}

/// The arithmetic that keeps what the author framed and what the renderer bakes
/// the same rectangle.
///
/// ⚠️ **PURE, AND THAT IS THE WHOLE POINT.** A crop that is one degree or ten
/// points out does not fail — it publishes a slightly different photograph,
/// silently, on someone else's post. None of this can be measured through a
/// gesture recogniser after the fact, so none of it is allowed to live inside
/// one: the view below owns touches and geometry owns truth.
///
/// ⚠️ **`MediaCrop.rect` IS MEASURED AGAINST THE TURNED BOUNDING BOX, NOT THE
/// SOURCE.** `MediaCropRenderer.apply` rotates first and then cuts in fractions
/// of `straightened.extent` — which is the axis-aligned box that CONTAINS the
/// turned picture, and is larger than the picture on both axes for any angle
/// that is not a quarter turn. Deriving the rectangle against the source instead
/// returns a plausible photograph rather than an error, which is the failure
/// mode this whole file exists to make impossible.
enum MediaCropGeometry {
    /// Below this, a picture is not being cropped, it is being erased. Stated as
    /// a fraction of the surface rather than in points so it means the same
    /// thing on every phone.
    static let smallestBoxSide: CGFloat = 64

    static func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

    /// The axis-aligned bounds a `size` picture occupies once turned by `angle`.
    ///
    /// ⚠️ **ABSOLUTE VALUES, SO THE SIGN OF THE ANGLE CANNOT MATTER.** A picture
    /// turned five degrees one way covers exactly the same bounds as one turned
    /// five degrees the other; `cos` and `sin` alone would make one of the two
    /// come out negative and the bounding box inside out.
    static func turnedSize(of size: CGSize, angle: CGFloat) -> CGSize {
        let cosine = abs(cos(radians(angle)))
        let sine = abs(sin(radians(angle)))
        return CGSize(
            width: size.width * cosine + size.height * sine,
            height: size.width * sine + size.height * cosine
        )
    }

    /// The smallest scale at which the turned picture still covers `box`.
    ///
    /// ⚠️ **A ROTATED RECTANGLE IS INSIDE AN UPRIGHT ONE EXACTLY WHEN ITS
    /// BOUNDING BOX IS.** That equivalence is what makes this a formula rather
    /// than a search: carry the box into the picture's own upright space, where
    /// it is the thing that leans, and ask for its bounds to fit. `turnedSize`
    /// computes those bounds for both directions of the same question.
    static func coveringScale(source: CGSize, box: CGSize, angle: CGFloat) -> CGFloat {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else { return 1 }
        let leaning = turnedSize(of: box, angle: angle)
        return max(leaning.width / source.width, leaning.height / source.height)
    }

    /// Pulls a placement back until the box is covered — enlarging the picture
    /// if it has become too small, then sliding it until no corner of the box
    /// hangs off the edge.
    ///
    /// ⚠️ **SCALE FIRST, THEN THE SLIDE.** The room a slide has depends on the
    /// scale, so clamping the centre against a scale that is about to change
    /// would clamp against room that does not exist. Reversing these two lets a
    /// pinch-out leave a transparent wedge in a corner, which is the defect a
    /// covering rule exists to prevent.
    static func covering(_ placement: CropPlacement, source: CGSize, box: CGRect) -> CropPlacement {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else {
            return placement
        }
        var settled = placement
        settled.scale = max(
            placement.scale,
            coveringScale(source: source, box: box.size, angle: placement.angle)
        )

        // The box carried into the picture's own upright space, where the
        // picture is a plain rectangle and the box is the thing that leans.
        let leaning = turnedSize(of: box.size, angle: settled.angle)
        let room = CGSize(
            width: max(0, source.width - leaning.width / settled.scale) / 2,
            height: max(0, source.height - leaning.height / settled.scale) / 2
        )
        let offset = unturned(
            CGPoint(
                x: box.midX - settled.centre.x,
                y: box.midY - settled.centre.y
            ),
            by: settled.angle
        )
        let held = CGPoint(
            x: min(max(offset.x / settled.scale, -room.width), room.width),
            y: min(max(offset.y / settled.scale, -room.height), room.height)
        )
        let back = turned(
            CGPoint(x: held.x * settled.scale, y: held.y * settled.scale),
            by: settled.angle
        )
        settled.centre = CGPoint(x: box.midX - back.x, y: box.midY - back.y)
        return settled
    }

    /// The placement after a pinch of `factor` anchored at `anchor`.
    ///
    /// ⚠️ **ANCHORED, NOT CENTRED.** Scaling about the picture's own centre
    /// makes the content slide out from under the fingers — the pixel between
    /// them has to stay between them, which is what fixing `anchor` does.
    static func scaling(
        _ placement: CropPlacement, by factor: CGFloat, about anchor: CGPoint
    ) -> CropPlacement {
        guard factor > 0 else { return placement }
        return CropPlacement(
            centre: CGPoint(
                x: anchor.x + (placement.centre.x - anchor.x) * factor,
                y: anchor.y + (placement.centre.y - anchor.y) * factor
            ),
            scale: placement.scale * factor,
            angle: placement.angle,
            isMirrored: placement.isMirrored
        )
    }

    static func moving(_ placement: CropPlacement, by offset: CGPoint) -> CropPlacement {
        var moved = placement
        moved.centre = CGPoint(x: placement.centre.x + offset.x, y: placement.centre.y + offset.y)
        return moved
    }

    /// How far the author has zoomed in beyond the minimum that covers the box.
    ///
    /// ⚠️ **THIS IS WHAT MAKES A TURN REVERSIBLE.** `covering` only ever ENLARGES
    /// — it has to, or a corner of the box would leave the picture — so a turn
    /// that needs more scale and a turn back that needs less leave the picture
    /// permanently closer in. Four quarter turns came back to the same angle
    /// holding 56% of the photograph, and a dial wiggled back and forth crept
    /// inwards a little with every pass. Carrying the author's own zoom across the
    /// turn, rather than the absolute scale, is what makes the round trip exact.
    static func zoom(of placement: CropPlacement, source: CGSize, box: CGRect) -> CGFloat {
        let minimum = coveringScale(source: source, box: box.size, angle: placement.angle)
        guard minimum > 0 else { return 1 }
        return max(1, placement.scale / minimum)
    }

    /// Turning to `angle` about `pivot`, keeping the author's own zoom rather than
    /// their absolute scale — see `zoom(of:source:box:)` for why the difference
    /// matters.
    static func turning(
        _ placement: CropPlacement, to angle: CGFloat, about pivot: CGPoint,
        coveringBox box: CGRect, source: CGSize
    ) -> CropPlacement {
        let kept = zoom(of: placement, source: source, box: box)
        let turned = turning(placement, to: angle, about: pivot)
        let wanted = coveringScale(source: source, box: box.size, angle: angle) * kept
        guard turned.scale > 0, wanted > 0 else { return turned }
        return scaling(turned, by: wanted / turned.scale, about: pivot)
    }

    /// The placement after turning to `angle` about `pivot`.
    ///
    /// ⚠️ **ABOUT THE BOX, NOT ABOUT THE PICTURE.** Turning around the picture's
    /// own centre swings whatever is framed out of frame the moment the picture
    /// is off-centre — the author straightens a horizon and watches their
    /// subject leave. Pivoting on the box keeps what is in the box in the box.
    static func turning(_ placement: CropPlacement, to angle: CGFloat, about pivot: CGPoint) -> CropPlacement {
        let swing = angle - placement.angle
        let arm = turned(
            CGPoint(x: placement.centre.x - pivot.x, y: placement.centre.y - pivot.y),
            by: swing
        )
        return CropPlacement(
            centre: CGPoint(x: pivot.x + arm.x, y: pivot.y + arm.y),
            scale: placement.scale,
            angle: angle,
            isMirrored: placement.isMirrored
        )
    }

    /// What the author kept, in the fractions `MediaCropRenderer` reads.
    ///
    /// ⚠️ **AGAINST THE TURNED BOUNDING BOX — SEE THE TYPE COMMENT.** The
    /// picture's bounding box is `turnedSize` scaled and centred on the
    /// placement; the fractions are the box's position inside THAT, top-left
    /// first, because that is the corner `MediaCrop.rect` measures from.
    static func crop(box: CGRect, placement: CropPlacement, source: CGSize) -> MediaCrop {
        let turnedSpan = turnedSize(of: source, angle: placement.angle)
        let span = CGSize(
            width: turnedSpan.width * placement.scale,
            height: turnedSpan.height * placement.scale
        )
        guard span.width > 0, span.height > 0 else { return .untouched }
        let corner = CGPoint(
            x: placement.centre.x - span.width / 2,
            y: placement.centre.y - span.height / 2
        )
        return MediaCrop(
            rect: CGRect(
                x: (box.minX - corner.x) / span.width,
                y: (box.minY - corner.y) / span.height,
                width: box.width / span.width,
                height: box.height / span.height
            ),
            angle: placement.angle,
            isMirrored: placement.isMirrored
        )
    }

    /// The inverse: the box and the placement that frame `crop` again.
    ///
    /// ⚠️ **THE BOX COMES OUT TOO, AND THAT IS WHAT MAKES THIS AN INVERSE.** A
    /// crop carries its own shape — a 4:5 cut reopened inside a 1:1 box is not
    /// the same photograph — so restoring one into a box chosen by somebody else
    /// would need two different scales at once and could only satisfy one of
    /// them. Deriving the box from the crop's own proportions makes the round
    /// trip exact, which `MediaCropGeometryTests` pins.
    static func framing(
        for crop: MediaCrop, source: CGSize, in surface: CGRect
    ) -> (box: CGRect, placement: CropPlacement) {
        let turnedSpan = turnedSize(of: source, angle: crop.angle)
        let kept = CGSize(
            width: crop.rect.width * turnedSpan.width,
            height: crop.rect.height * turnedSpan.height
        )
        guard kept.width > 0, kept.height > 0, surface.width > 0, surface.height > 0 else {
            return (
                surface,
                CropPlacement(
                    centre: CGPoint(x: surface.midX, y: surface.midY), scale: 1,
                    angle: crop.angle, isMirrored: crop.isMirrored
                )
            )
        }
        let box = self.box(ratio: kept.width / kept.height, in: surface)
        let scale = box.width / kept.width
        let span = CGSize(width: turnedSpan.width * scale, height: turnedSpan.height * scale)
        return (
            box,
            CropPlacement(
                centre: CGPoint(
                    x: box.midX + span.width * (0.5 - crop.rect.midX),
                    y: box.midY + span.height * (0.5 - crop.rect.midY)
                ),
                scale: scale,
                angle: crop.angle,
                isMirrored: crop.isMirrored
            )
        )
    }

    /// The largest box of `ratio` that fits in `surface`, centred in it.
    static func box(ratio: CGFloat, in surface: CGRect) -> CGRect {
        guard ratio > 0, surface.width > 0, surface.height > 0 else { return surface }
        var size = CGSize(width: surface.width, height: surface.width / ratio)
        if size.height > surface.height {
            size = CGSize(width: surface.height * ratio, height: surface.height)
        }
        return CGRect(
            x: surface.midX - size.width / 2,
            y: surface.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// After a handle drag: the box grows back to fill the surface and the
    /// picture follows it, so the same content stays framed.
    ///
    /// ⚠️ **WITHOUT THIS THE TOOL READS AS BROKEN.** A handle drag leaves a small
    /// box in the middle of a large surface; letting it stand shows the author a
    /// postage stamp of their own photograph and gives every later gesture a
    /// smaller target. Photos re-frames on release, and the arithmetic is exactly
    /// a scale about the old box's centre followed by the slide that carries that
    /// centre onto the new one — which is why the content does not shift.
    static func reframed(
        box: CGRect, placement: CropPlacement, in surface: CGRect
    ) -> (box: CGRect, placement: CropPlacement) {
        guard box.width > 0, box.height > 0 else { return (box, placement) }
        let grown = self.box(ratio: box.width / box.height, in: surface)
        let factor = grown.width / box.width
        let centre = CGPoint(x: box.midX, y: box.midY)
        let scaled = scaling(placement, by: factor, about: centre)
        return (
            grown,
            moving(scaled, by: CGPoint(x: grown.midX - centre.x, y: grown.midY - centre.y))
        )
    }

    // MARK: - Dragging a corner

    /// Which edges of the box a finger has taken hold of. Empty means the finger
    /// took the picture instead, which is the common case and the reason this is
    /// an `OptionSet` rather than an enum with a `.move` case: "no edge" already
    /// says it.
    struct Grip: OptionSet {
        let rawValue: Int
        static let left = Grip(rawValue: 1 << 0)
        static let right = Grip(rawValue: 1 << 1)
        static let top = Grip(rawValue: 1 << 2)
        static let bottom = Grip(rawValue: 1 << 3)
        var movesThePicture: Bool { isEmpty }
    }

    /// What a finger at `point` has hold of.
    ///
    /// ⚠️ **A CORNER IS BOTH OF ITS EDGES, AND THE REACH IS DELIBERATELY LARGER
    /// THAN THE DRAWN HANDLE.** The bracket in the corner is a few points of ink;
    /// a finger is 44. Sizing the target to the ink is the classic way to ship a
    /// handle that can be seen and not held.
    ///
    /// ⚠️ AND A POINT WELL INSIDE THE BOX TAKES THE PICTURE, NOT AN EDGE. Only
    /// the band within `reach` of an edge — measured from BOTH sides of it, so
    /// the grab works from just outside the box too — belongs to that edge.
    static func grip(at point: CGPoint, box: CGRect, reach: CGFloat) -> Grip {
        guard box.insetBy(dx: -reach, dy: -reach).contains(point) else { return [] }
        var grip: Grip = []
        if abs(point.x - box.minX) <= reach { grip.insert(.left) }
        else if abs(point.x - box.maxX) <= reach { grip.insert(.right) }
        if abs(point.y - box.minY) <= reach { grip.insert(.top) }
        else if abs(point.y - box.maxY) <= reach { grip.insert(.bottom) }
        return grip
    }

    /// The box after a handle has been dragged by `offset`.
    ///
    /// ⚠️ **THE OPPOSITE EDGE IS THE ANCHOR AND NEVER MOVES.** A resize that
    /// recentres the box as it grows is a box that runs away from the finger.
    ///
    /// ⚠️ **AND A LOCKED RATIO SHRINKS TO FIT RATHER THAN GROWING TO IT.** Given
    /// a dragged rectangle that is too wide for the ratio, the width is the side
    /// that gives — growing the height instead would take the box past the finger
    /// and, at the surface's edge, outside the surface entirely.
    static func resized(
        _ box: CGRect, grip: Grip, by offset: CGPoint, ratio: CGFloat?, in surface: CGRect
    ) -> CGRect {
        guard !grip.movesThePicture else { return box }
        var minX = box.minX, maxX = box.maxX, minY = box.minY, maxY = box.maxY
        if grip.contains(.left) { minX += offset.x }
        if grip.contains(.right) { maxX += offset.x }
        if grip.contains(.top) { minY += offset.y }
        if grip.contains(.bottom) { maxY += offset.y }

        minX = max(minX, surface.minX)
        maxX = min(maxX, surface.maxX)
        minY = max(minY, surface.minY)
        maxY = min(maxY, surface.maxY)

        let smallest = min(smallestBoxSide, min(surface.width, surface.height))
        if maxX - minX < smallest {
            if grip.contains(.left) { minX = maxX - smallest } else { maxX = minX + smallest }
        }
        if maxY - minY < smallest {
            if grip.contains(.top) { minY = maxY - smallest } else { maxY = minY + smallest }
        }

        let dragged = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio, ratio > 0 else { return dragged }
        return locked(dragged, to: ratio, anchoring: grip, smallest: smallest, in: surface)
    }

    private static func locked(
        _ box: CGRect, to ratio: CGFloat, anchoring grip: Grip, smallest: CGFloat, in surface: CGRect
    ) -> CGRect {
        var size = CGSize(width: box.width, height: box.height)
        if size.width / size.height > ratio {
            size.width = size.height * ratio
        } else {
            size.height = size.width / ratio
        }
        // A ratio can shrink a side below the floor; grow both back together
        // rather than breaking the ratio to honour the floor.
        let growth = max(1, max(smallest / size.width, smallest / size.height))
        size = CGSize(width: size.width * growth, height: size.height * growth)

        // The gripped edges are the ones that moved, so the others hold.
        var x = grip.contains(.left) ? box.maxX - size.width : box.minX
        var y = grip.contains(.top) ? box.maxY - size.height : box.minY
        x = min(max(x, surface.minX), max(surface.minX, surface.maxX - size.width))
        y = min(max(y, surface.minY), max(surface.minY, surface.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Quarter turns

    /// A whole angle split into the quarter turns a button made and the fine
    /// straightening a dial made.
    ///
    /// ⚠️ **ONE NUMBER IN THE MODEL, TWO CONTROLS ON SCREEN.** `MediaCrop.angle`
    /// is a single total and must stay one — a second field would be a second
    /// thing the renderer could disagree with. The split is derived on the way
    /// into the UI and summed on the way out, so a crop saved at 97° reopens as
    /// one quarter turn and seven degrees, which is what the author did.
    /// ⚠️ **THE TIE AT EXACTLY 45° BREAKS TOWARD ZERO, AND `.rounded()` ALONE
    /// BROKE IT THE OTHER WAY.** `Int((45 / 90).rounded())` is 1, not 0 —
    /// `.rounded()` is `.toNearestOrAwayFromZero` and 0.5 is exactly
    /// representable — so a picture straightened to +45° came back as one quarter
    /// turn and MINUS forty-five degrees. The same angle, and the renderer could
    /// not tell the difference; every control could. The readout spelled "-45°"
    /// for a picture turned the other way, the dial sat on its negative stop so
    /// the author could only go further from level, the readout's tap — the
    /// documented way back to level — left the picture at a quarter turn, and an
    /// odd `quarters` made "Original" offer the picture's proportions
    /// transposed.
    ///
    /// ⚠️ **AND 45 IS NOT AN EXOTIC INPUT: IT IS WHERE THE DIAL PARKS.**
    /// `StraightenDial.clamped` is `min(max(angle, -45), 45)`, so any drag past
    /// the stop lands on the literal 45.0 and nothing downstream perturbs it.
    /// Breaking the tie toward zero keeps `fine` inside `[-45, 45]` — the dial's
    /// own reachable range — at both ends.
    static func split(_ angle: CGFloat) -> (quarters: Int, fine: CGFloat) {
        let turns = angle / 90
        let isTie = abs(turns.truncatingRemainder(dividingBy: 1)) == 0.5
        let quarters = Int(isTie ? turns.rounded(.towardZero) : turns.rounded())
        return (quarters, angle - CGFloat(quarters) * 90)
    }

    static func whole(quarters: Int, fine: CGFloat) -> CGFloat {
        CGFloat(quarters) * 90 + fine
    }

    // MARK: - Turning a vector

    /// ⚠️ **CLOCKWISE, BECAUSE THE SURFACE'S Y POINTS DOWN.** This is UIKit's own
    /// rotation matrix, not the one from a maths textbook: with y increasing
    /// downwards, `(x cos - y sin, x sin + y cos)` turns a vector clockwise on
    /// screen. Writing the textbook version here would make the dial straighten
    /// the picture the wrong way — the one direction `MediaCropTests` explicitly
    /// says it cannot catch.
    static func turned(_ vector: CGPoint, by angle: CGFloat) -> CGPoint {
        let cosine = cos(radians(angle))
        let sine = sin(radians(angle))
        return CGPoint(
            x: vector.x * cosine - vector.y * sine,
            y: vector.x * sine + vector.y * cosine
        )
    }

    static func unturned(_ vector: CGPoint, by angle: CGFloat) -> CGPoint {
        turned(vector, by: -angle)
    }
}
