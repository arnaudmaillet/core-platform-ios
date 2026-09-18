import CoreGraphics
import MediaPlayback

/// Where an overlay stands on screen, worked out from where it stands on the
/// picture — and back.
///
/// ⚠️ **PURE, AND THE ONLY PLACE THE TWO SPACES MEET.** A placement is stored in
/// fractions of the finished picture (`OverlayPlacement`); a finger moves in the
/// page's points; and the picture is laid in the page either whole (`fit`) or
/// spilling past its edges (`fill`). Every conversion between the two goes
/// through here, so a drag on a filled page and a drag on a fitted one cannot
/// disagree about what "10 points to the right" is worth.
///
/// ⚠️ **A FILLED PICTURE IS LARGER THAN ITS PAGE.** `mediaRect` then runs past
/// the page's bounds, and a centre at `(0.02, 0.5)` is a real place on the
/// published picture that nobody can see or grab. That is why a new overlay is
/// put in the VISIBLE part (`visibleFractions`), and why a drag is held there.
enum MediaOverlayGeometry {
    /// A text overlay's point size at placement scale 1, as a fraction of the
    /// finished picture's width — the rasteriser's own rule, so the editor's
    /// fallback lettering is the size the export draws.
    static let textSizeFraction: CGFloat = 0.06
    /// An emoji's or a sticker's side at placement scale 1, the same way.
    static let emojiSizeFraction: CGFloat = 0.18

    /// How small and how large a pinch may make an overlay. Below the floor an
    /// overlay can no longer be grabbed; above the ceiling one word covers the
    /// picture many times over.
    static let scaleRange: ClosedRange<Double> = 0.25...8

    /// The rectangle a picture of `contentSize` is drawn in, inside `bounds`,
    /// laid the way `fit` says — `UIImageView`'s own aspect-fit and aspect-fill,
    /// centred.
    static func mediaRect(contentSize: CGSize, bounds: CGRect, fit: ContentFit) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let across = bounds.width / contentSize.width
        let down = bounds.height / contentSize.height
        let factor = fit == .fit ? min(across, down) : max(across, down)
        let size = CGSize(width: contentSize.width * factor, height: contentSize.height * factor)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// A stored centre, in the page's points.
    static func point(for centre: CGPoint, in mediaRect: CGRect) -> CGPoint {
        CGPoint(
            x: mediaRect.minX + centre.x * mediaRect.width,
            y: mediaRect.minY + centre.y * mediaRect.height
        )
    }

    /// A point on the page, as a centre on the picture.
    static func centre(for point: CGPoint, in mediaRect: CGRect) -> CGPoint {
        guard mediaRect.width > 0, mediaRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: (point.x - mediaRect.minX) / mediaRect.width,
            y: (point.y - mediaRect.minY) / mediaRect.height
        )
    }

    /// The turn and the size an overlay's view wears.
    ///
    /// ⚠️ **CLOCKWISE AS THE VIEWER SEES IT IS UIKit's POSITIVE ANGLE.** UIKit's
    /// y axis points down, so `CGAffineTransform(rotationAngle:)` with a
    /// positive angle already turns clockwise on screen — no sign to flip here.
    /// The flip belongs to the rasteriser, whose Core Image axis points up.
    static func transform(for placement: OverlayPlacement) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: placement.rotation)
            .scaledBy(x: placement.scale, y: placement.scale)
    }

    /// The part of the picture that can be seen on the page, in fractions of
    /// the picture — `window` being the part of `bounds` the chrome leaves
    /// clear.
    static func visibleFractions(mediaRect: CGRect, window: CGRect) -> CGRect {
        let seen = mediaRect.intersection(window)
        guard !seen.isNull, seen.width > 0, seen.height > 0,
              mediaRect.width > 0, mediaRect.height > 0
        else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: (seen.minX - mediaRect.minX) / mediaRect.width,
            y: (seen.minY - mediaRect.minY) / mediaRect.height,
            width: seen.width / mediaRect.width,
            height: seen.height / mediaRect.height
        )
    }

    /// `centre`, held inside `visible` (fractions of the picture).
    static func clamped(_ centre: CGPoint, into visible: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(centre.x, visible.minX), visible.maxX),
            y: min(max(centre.y, visible.minY), visible.maxY)
        )
    }

    /// `placement` dragged by `translation` page points, held inside `visible`.
    static func moved(
        _ placement: OverlayPlacement, by translation: CGPoint, in mediaRect: CGRect, visible: CGRect
    ) -> OverlayPlacement {
        guard mediaRect.width > 0, mediaRect.height > 0 else { return placement }
        var next = placement
        next.centre = clamped(
            CGPoint(
                x: placement.centre.x + translation.x / mediaRect.width,
                y: placement.centre.y + translation.y / mediaRect.height
            ),
            into: visible
        )
        return next
    }

    /// `placement` pinched by `factor`, held inside `scaleRange`.
    static func scaled(_ placement: OverlayPlacement, by factor: Double) -> OverlayPlacement {
        var next = placement
        next.scale = min(max(placement.scale * factor, scaleRange.lowerBound), scaleRange.upperBound)
        return next
    }

    /// `placement` turned by `radians`, clockwise as the viewer sees it, kept
    /// within one turn either way.
    static func rotated(_ placement: OverlayPlacement, by radians: Double) -> OverlayPlacement {
        var next = placement
        next.rotation = (placement.rotation + radians).truncatingRemainder(dividingBy: 2 * .pi)
        return next
    }

    // MARK: - Snapping

    /// How near the middle of the picture an overlay's centre has to come
    /// before it is taken to be ON it — in SCREEN POINTS on the page.
    ///
    /// ⚠️ **POINTS, NOT FRACTIONS, AND THE DIFFERENCE IS NOT COSMETIC.** The
    /// same 0.02 of the picture is 6pt of travel on a 300pt-wide fitted page and
    /// 24pt on the 1200pt-wide filled one this file's own tests use — the snap
    /// would grab four times as hard on one lay as on the other, for the same
    /// finger. A window stated in points is the same window under every finger,
    /// and the conversion is the one this type already owns.
    ///
    /// 8pt is under a fifth of the 44pt target a finger is given
    /// (`MediaOverlayItemView.minimumTarget`): near enough that an overlay the
    /// author *meant* to centre falls in, far enough that one they meant to
    /// leave 20pt off-centre stays where they left it.
    static let centreReach: CGFloat = 8

    /// How near a right angle a turn has to come before it is taken to BE one,
    /// in degrees either side.
    ///
    /// ⚠️ **5°, WHICH IS `StraightenDial.detent`'s NUMBER FOR THE SAME REASON.**
    /// A 5° window each side of four right angles claims 40 of the 360 degrees
    /// — a ninth of the dial — so eight ninths of a turn is still free. A
    /// window wide enough to catch a sloppy hand (15° is often suggested) makes
    /// a deliberate 10° tilt impossible to hold, and a tilt is a thing authors
    /// do on purpose.
    static let squareReach: Double = 5

    /// Which marks a placement lit by falling into a snap.
    ///
    /// ⚠️ **NAMED FOR WHAT IS TRUE OF THE OVERLAY, NOT FOR THE LINE DRAWN.**
    /// `centredAcross` means the centre sits on the picture's vertical middle —
    /// which is drawn as a VERTICAL guide. Naming the member after the line
    /// would have every reader ask which of the two axes "horizontal guide"
    /// refers to.
    struct OverlaySnapMarks: OptionSet, Hashable, Sendable {
        let rawValue: Int

        init(rawValue: Int) { self.rawValue = rawValue }

        /// Centred left-to-right: `centre.x == 0.5`.
        static let centredAcross = OverlaySnapMarks(rawValue: 1 << 0)
        /// Centred top-to-bottom: `centre.y == 0.5`.
        static let centredDown = OverlaySnapMarks(rawValue: 1 << 1)
        /// Turned to a right angle — 0, 90, 180, 270 or a full 360.
        static let square = OverlaySnapMarks(rawValue: 1 << 2)
    }

    /// A placement after the snaps, and what they lit.
    struct SnappedPlacement: Equatable {
        var placement: OverlayPlacement
        var marks: OverlaySnapMarks
    }

    /// The right angle `radians` is taken to be, or nil when it is between two.
    ///
    /// ⚠️ **THE FULL TURN IS ITS OWN DETENT, AND IT IS NOT FOLDED BACK TO
    /// ZERO.** `rotated` keeps a rotation within one turn either way, so a hand
    /// that has gone all the way round reads 6.28 and not 0. Answering `2π`
    /// here draws identically to answering 0 — `CGAffineTransform` does not care
    /// — and it keeps the answer a pure function of the input, which folding
    /// would not: the author who turned a full circle did turn a full circle.
    static func squared(_ radians: Double) -> Double? {
        let quarter = Double.pi / 2
        let nearest = (radians / quarter).rounded() * quarter
        let window = squareReach * .pi / 180
        // ⚠️ `<=`: the window is INCLUSIVE, so exactly 5° off snaps and 5°
        // plus a hair does not. The tests are written either side of that edge.
        return abs(radians - nearest) <= window ? nearest : nil
    }

    /// `placement` with every snap applied, and the marks they lit.
    ///
    /// ⚠️ **HAND IT THE RAW PLACEMENT, NEVER ITS OWN LAST ANSWER.** Feeding the
    /// snapped value back in is the numb-control failure `StraightenDial.advanced`
    /// records from the other side: at a snapped 0° a further 3° of turn is 3°,
    /// which snaps to 0° again, and the overlay can never be turned out of the
    /// detent at all. The caller advances an unsnapped placement of its own and
    /// asks this only for what to DRAW — which is why this takes a placement and
    /// not a delta.
    ///
    /// ⚠️ **THE CLAMP COMES AFTER THE SNAP, AND A CLAMPED AXIS LIGHTS NOTHING.**
    /// On a filled picture whose middle the chrome covers, pulling the centre to
    /// 0.5 would put it where nobody can grab it; `visible` wins, and the mark
    /// is only lit for an axis that actually ended on the middle.
    static func snapped(
        _ placement: OverlayPlacement, in mediaRect: CGRect, visible: CGRect
    ) -> SnappedPlacement {
        var next = placement
        if mediaRect.width > 0, abs(placement.centre.x - 0.5) * mediaRect.width <= centreReach {
            next.centre.x = 0.5
        }
        if mediaRect.height > 0, abs(placement.centre.y - 0.5) * mediaRect.height <= centreReach {
            next.centre.y = 0.5
        }
        next.centre = clamped(next.centre, into: visible)
        var marks: OverlaySnapMarks = []
        if next.centre.x == 0.5 { marks.insert(.centredAcross) }
        if next.centre.y == 0.5 { marks.insert(.centredDown) }
        if let turn = squared(placement.rotation) {
            next.rotation = turn
            marks.insert(.square)
        }
        return SnappedPlacement(placement: next, marks: marks)
    }

    /// Whether the engine owes a tick: a mark is lit now that was not lit a
    /// sample ago.
    ///
    /// ⚠️ **ON THE WAY IN ONLY, WHICH IS WHY THIS IS A SUBTRACTION AND NOT A
    /// `!=`.** Leaving a snap is not an event the hand needs told about —
    /// `MediaOverlayTrashView` arms with a tap and disarms in silence for the
    /// same reason — and a `!=` would click twice for every detent crossed.
    static func ticks(from previous: OverlaySnapMarks, to next: OverlaySnapMarks) -> Bool {
        !next.subtracting(previous).isEmpty
    }
}
