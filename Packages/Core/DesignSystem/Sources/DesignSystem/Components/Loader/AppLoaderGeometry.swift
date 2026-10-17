import CoreGraphics
import Foundation

/// The branded loader's shapes (#1329): four pieces that take three forms —
///
/// - the **square** (the mark): a square cut in four by three lines, each
///   piece a pill (corner radius half its own shorter side);
/// - the **disc**: the same cuts out of a disc, every convex corner filleted;
/// - the **ring**: four round-capped arcs on a ring, the cap-to-cap gap the
///   square's gap.
///
/// Coordinates are normalised to the unit square, origin top-left, y down;
/// `AppLoaderView` scales them to its side.
///
/// ⚠️ **ONE OUTLINE SHAPE IN EVERY FORM.** A path only interpolates into a path
/// with the same number and kind of elements, so every outline here is
/// `pointCount` points resampled evenly by length, CLOCKWISE on screen, and
/// STARTING at the point furthest along the piece's anchor direction (its
/// quadrant's diagonal; for an arc, its own middle). Without the common start
/// and orientation the morph twists (the renders the issue was decided on
/// were made exactly this way).
public enum AppLoaderGeometry {
    /// Points per outline, in every form.
    public static let pointCount = 128

    /// Between pieces, in the square and between caps on the ring.
    static let gap: CGFloat = 0.075
    /// The one vertical cut, then a horizontal cut on each side of it.
    static let cutX: CGFloat = 0.46
    static let cutYLeft: CGFloat = 0.62
    static let cutYRight: CGFloat = 0.36
    /// A disc piece's fillets, as a share of its shorter straight edge.
    /// ⚠️ 0.33 is the ceiling: above ≈0.34 the rim and inner fillets overlap
    /// on the narrow pieces.
    static let filletRatio: CGFloat = 0.33
    /// The ring's stroke.
    static let ringWidth: CGFloat = 0.17

    static let center = CGPoint(x: 0.5, y: 0.5)
    static let radius: CGFloat = 0.5
    /// The ring's centre line: its outer edge touches the square's.
    static var ringRadius: CGFloat { radius - ringWidth / 2 }

    /// Pieces in order, clockwise from the pink: top-left, top-right,
    /// bottom-right, bottom-left.
    public static let pieceCount = 4

    /// A piece's quadrant diagonal: −135°, −45°, 45°, 135° (y down).
    static func diagonal(_ piece: Int) -> CGFloat {
        (-135 + 90 * CGFloat(piece)) * .pi / 180
    }

    // MARK: - The three forms

    /// The square's piece: a pill.
    public static func square(_ piece: Int) -> [CGPoint] { squares[piece] }
    /// The disc's piece: the square's cuts out of the disc, filleted.
    public static func disc(_ piece: Int) -> [CGPoint] { discs[piece] }
    /// The ring at rest: each arc a quarter, centred on its own diagonal.
    public static func restingRing(_ piece: Int) -> [CGPoint] { restingRings[piece] }

    private static let squares = (0..<pieceCount).map { normalized(pillOutline($0), anchor: diagonal($0)) }
    private static let discs = (0..<pieceCount).map { normalized(discOutline($0), anchor: diagonal($0)) }
    private static let restingRings = ring(fractions: equalQuarters)

    /// Equal quarters, the ring at rest and where every loop begins and ends.
    public static let equalQuarters: [CGFloat] = [0.25, 0.25, 0.25, 0.25]

    /// The ring with its four arcs covering `fractions` of the turn (summing
    /// to 1), in piece order. The top-left's share starts at −180°, so equal
    /// quarters centre each arc on its own diagonal.
    public static func ring(fractions: [CGFloat]) -> [[CGPoint]] {
        var start: CGFloat = -.pi
        return (0..<pieceCount).map { piece in
            let span = fractions[piece] * 2 * .pi
            defer { start += span }
            let (outline, middle) = arcOutline(from: start, span: span)
            return normalized(outline, anchor: middle)
        }
    }

    // MARK: - Point arithmetic

    /// `a` at 0, `b` at 1, point by point — and EXACTLY `a` or `b` at the
    /// ends, so a morph lands on the form itself (the loop's first keyframe
    /// is the pull's last frame, bit for bit: no jump on release).
    public static func mix(_ a: [CGPoint], _ b: [CGPoint], _ t: CGFloat) -> [CGPoint] {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
    }

    /// Scaled about the outline's own centroid — a piece growing in place.
    public static func scaled(_ points: [CGPoint], by scale: CGFloat) -> [CGPoint] {
        guard scale != 1, !points.isEmpty else { return points }
        let c = centroid(points)
        return points.map { CGPoint(x: c.x + ($0.x - c.x) * scale, y: c.y + ($0.y - c.y) * scale) }
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    /// Twice the signed area; POSITIVE for a clockwise outline on screen (y down).
    static func signedArea(_ points: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }

    // MARK: - Outlines, densely sampled

    /// The pieces' cut lines: a vertical one at `x` (the piece on the `xSide`
    /// of it, −1 left / +1 right) and a horizontal one at `y`.
    private static func cuts(_ piece: Int) -> (x: CGFloat, xSide: CGFloat, y: CGFloat, ySide: CGFloat) {
        let half = gap / 2
        switch piece {
        case 0: return (cutX - half, -1, cutYLeft - half, -1)
        case 1: return (cutX + half, 1, cutYRight - half, -1)
        case 2: return (cutX + half, 1, cutYRight + half, 1)
        default: return (cutX - half, -1, cutYLeft + half, 1)
        }
    }

    /// Every corner rounded by half the shorter side, clockwise from the top
    /// edge.
    private static func pillOutline(_ piece: Int) -> [CGPoint] {
        let cut = cuts(piece)
        let x0 = cut.xSide < 0 ? 0 : cut.x, x1 = cut.xSide < 0 ? cut.x : 1
        let y0 = cut.ySide < 0 ? 0 : cut.y, y1 = cut.ySide < 0 ? cut.y : 1
        let r = min(x1 - x0, y1 - y0) / 2
        var points = [CGPoint(x: x0 + r, y: y0), CGPoint(x: x1 - r, y: y0)]
        appendArc(center: CGPoint(x: x1 - r, y: y0 + r), radius: r, from: -.pi / 2, to: 0, into: &points)
        points.append(CGPoint(x: x1, y: y1 - r))
        appendArc(center: CGPoint(x: x1 - r, y: y1 - r), radius: r, from: 0, to: .pi / 2, into: &points)
        points.append(CGPoint(x: x0 + r, y: y1))
        appendArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r, from: .pi / 2, to: .pi, into: &points)
        points.append(CGPoint(x: x0, y: y0 + r))
        appendArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r, from: .pi, to: 1.5 * .pi, into: &points)
        return points
    }

    /// The disc's piece: bounded by its two cut lines and the rim, its inner
    /// corner a line/line fillet and its two rim corners line/circle fillets.
    private static func discOutline(_ piece: Int) -> [CGPoint] {
        let cut = cuts(piece)
        // Where each cut line meets the rim, on the piece's side.
        let rimY = center.y + cut.ySide * (radius * radius - pow(cut.x - center.x, 2)).squareRoot()
        let rimX = center.x + cut.xSide * (radius * radius - pow(cut.y - center.y, 2)).squareRoot()
        let fillet = filletRatio * min(abs(cut.y - rimY), abs(cut.x - rimX))

        // Inner corner: a quarter circle tangent to both cuts.
        let inner = CGPoint(x: cut.x + cut.xSide * fillet, y: cut.y + cut.ySide * fillet)
        // Rim fillets: tangent to their cut, internally tangent to the rim.
        let reach = radius - fillet
        let alongVertical = CGPoint(
            x: cut.x + cut.xSide * fillet,
            y: center.y + cut.ySide * (reach * reach - pow(cut.x + cut.xSide * fillet - center.x, 2)).squareRoot()
        )
        let alongHorizontal = CGPoint(
            x: center.x + cut.xSide * (reach * reach - pow(cut.y + cut.ySide * fillet - center.y, 2)).squareRoot(),
            y: cut.y + cut.ySide * fillet
        )
        func onRim(_ filletCenter: CGPoint) -> CGPoint {
            let scale = radius / reach
            return CGPoint(
                x: center.x + (filletCenter.x - center.x) * scale,
                y: center.y + (filletCenter.y - center.y) * scale
            )
        }

        var points = [CGPoint(x: cut.x, y: cut.y + cut.ySide * fillet), CGPoint(x: cut.x, y: alongVertical.y)]
        appendArc(center: alongVertical, radius: fillet,
                  from: angle(of: CGPoint(x: cut.x, y: alongVertical.y), around: alongVertical),
                  to: angle(of: onRim(alongVertical), around: alongVertical), into: &points)
        appendArc(center: center, radius: radius,
                  from: angle(of: onRim(alongVertical), around: center),
                  to: angle(of: onRim(alongHorizontal), around: center), into: &points)
        appendArc(center: alongHorizontal, radius: fillet,
                  from: angle(of: onRim(alongHorizontal), around: alongHorizontal),
                  to: angle(of: CGPoint(x: alongHorizontal.x, y: cut.y), around: alongHorizontal), into: &points)
        points.append(CGPoint(x: cut.x + cut.xSide * fillet, y: cut.y))
        appendArc(center: inner, radius: fillet,
                  from: angle(of: CGPoint(x: cut.x + cut.xSide * fillet, y: cut.y), around: inner),
                  to: angle(of: CGPoint(x: cut.x, y: cut.y + cut.ySide * fillet), around: inner), into: &points)
        return points
    }

    /// One round-capped arc whose share of the turn starts at `start` and
    /// spans `span` — its caps pulled in so the gap between neighbouring caps
    /// is exactly `gap`. Returns the outline and the arc's middle angle.
    private static func arcOutline(from start: CGFloat, span: CGFloat) -> ([CGPoint], CGFloat) {
        let half = ringWidth / 2
        // Cap centres a chord of `gap + ringWidth` apart across each boundary.
        let inset = asin(min(1, (gap + ringWidth) / (2 * ringRadius)))
        let a = start + inset
        let b = max(a + 0.001, start + span - inset)
        var points: [CGPoint] = []
        appendArc(center: center, radius: ringRadius + half, from: a, to: b, into: &points,
                  includeStart: true, literal: true)
        let capB = CGPoint(x: center.x + ringRadius * cos(b), y: center.y + ringRadius * sin(b))
        appendArc(center: capB, radius: half, from: b, to: b + .pi, into: &points, literal: true)
        appendArc(center: center, radius: ringRadius - half, from: b, to: a, into: &points, literal: true)
        let capA = CGPoint(x: center.x + ringRadius * cos(a), y: center.y + ringRadius * sin(a))
        appendArc(center: capA, radius: half, from: a + .pi, to: a + 2 * .pi, into: &points, literal: true)
        return (points, (a + b) / 2)
    }

    private static func angle(of point: CGPoint, around c: CGPoint) -> CGFloat {
        atan2(point.y - c.y, point.x - c.x)
    }

    /// The shorter way round from `a0` to `a1` for a fillet or rim arc —
    /// every one of them spans less than half a turn, and `atan2` hands their
    /// ends across the ±π seam — unless the sweep is meant `literal`ly: a
    /// ring's arc can cover up to 0.7 of the turn.
    private static func appendArc(
        center c: CGPoint, radius r: CGFloat, from a0: CGFloat, to a1: CGFloat,
        into points: inout [CGPoint], includeStart: Bool = false, literal: Bool = false
    ) {
        var sweep = a1 - a0
        if !literal, abs(sweep) > .pi {
            // A short arc asked across the ±π seam: take the short way.
            sweep = sweep > 0 ? sweep - 2 * .pi : sweep + 2 * .pi
        }
        let steps = max(4, Int(abs(sweep) / (.pi / 120)))
        for step in (includeStart ? 0 : 1)...steps {
            let a = a0 + sweep * CGFloat(step) / CGFloat(steps)
            points.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
    }

    // MARK: - Resampling

    /// Clockwise, `pointCount` points evenly by length, starting at the point
    /// furthest along `anchor` from the loader's centre.
    static func normalized(_ outline: [CGPoint], anchor: CGFloat) -> [CGPoint] {
        var points = outline
        if signedArea(points) < 0 { points.reverse() }
        let fine = resample(points, count: 4096)
        let direction = CGPoint(x: cos(anchor), y: sin(anchor))
        func reach(_ p: CGPoint) -> CGFloat { (p.x - center.x) * direction.x + (p.y - center.y) * direction.y }
        let start = fine.indices.max { reach(fine[$0]) < reach(fine[$1]) } ?? 0
        return resample(Array(fine[start...] + fine[..<start]), count: pointCount)
    }

    /// A closed polyline resampled to `count` points evenly spaced by length,
    /// the first point kept.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        var cumulative: [CGFloat] = [0]
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            cumulative.append(cumulative[index] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = cumulative[points.count]
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var segment = 0
        for k in 0..<count {
            let distance = total * CGFloat(k) / CGFloat(count)
            while segment < points.count - 1, cumulative[segment + 1] < distance { segment += 1 }
            let a = points[segment], b = points[(segment + 1) % points.count]
            let length = cumulative[segment + 1] - cumulative[segment]
            let t = length > 0 ? (distance - cumulative[segment]) / length : 0
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }
}
