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
}
