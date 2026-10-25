import CoreGraphics
import Foundation

/// The branded loader's shapes: four pieces that take two forms —
///
/// - the **icon** (the mark, #1744): the app icon's four soft pieces, pink
///   top-left, violet top-right, mauve bottom-right, orchid bottom-left,
///   turned `iconTurn` off the square's diagonals as on the icon;
/// - the **ring** (#1329): four round-capped arcs on a ring, the cap-to-cap
///   gap `gap`, turned by the same `iconTurn` at rest so no arc travels round
///   to its slot during the morph.
///
/// Coordinates are normalised to the unit square, origin top-left, y down;
/// `AppLoaderView` scales them to its side.
///
/// ⚠️ **ONE OUTLINE SHAPE IN EVERY FORM.** A path only interpolates into a path
/// with the same number and kind of elements, so every outline here is
/// `pointCount` points resampled evenly by length, CLOCKWISE on screen, and
/// STARTING at the point furthest along the piece's anchor direction (for an
/// icon piece, the direction of its centroid; for an arc, its own middle).
/// Without the common start and orientation the morph twists.
public enum AppLoaderGeometry {
    /// Points per outline, in every form.
    public static let pointCount = 128

    /// Between neighbouring caps on the ring.
    static let gap: CGFloat = 0.075
    /// The ring's stroke.
    static let ringWidth: CGFloat = 0.17
    /// The icon's pieces sit this far clockwise of the square's diagonals
    /// (their centroids measure 11–19°), and the resting ring is turned the
    /// same, so each piece thins into an arc already in its place.
    public static let iconTurn: CGFloat = 15 * .pi / 180

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

    // MARK: - The two forms

    /// The icon's piece, as on the app icon.
    public static func icon(_ piece: Int) -> [CGPoint] { icons[piece] }
    /// The ring at rest: each arc a quarter, centred on its own diagonal
    /// turned by `iconTurn`.
    public static func restingRing(_ piece: Int) -> [CGPoint] { restingRings[piece] }

    private static let icons = iconHarmonics.map { harmonics in
        let outline = fourierOutline(harmonics)
        let middle = centroid(outline)
        return normalized(outline, anchor: atan2(middle.y - center.y, middle.x - center.x))
    }
    private static let restingRings = ring(fractions: equalQuarters)

    /// Equal quarters, the ring at rest and where every loop begins and ends.
    public static let equalQuarters: [CGFloat] = [0.25, 0.25, 0.25, 0.25]

    /// The ring with its four arcs covering `fractions` of the turn (summing
    /// to 1), in piece order. The top-left's share starts at −180° turned by
    /// `iconTurn`, so equal quarters centre each arc on its turned diagonal.
    public static func ring(fractions: [CGFloat]) -> [[CGPoint]] {
        var start: CGFloat = -.pi + iconTurn
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

    // MARK: - The icon

    /// The icon's pieces, traced from the owner's mark (the same outlines the
    /// #1744 reference renders were made from) and kept as Fourier series —
    /// `re, im` of the closed outline's harmonics −12…12, the outline being
    /// `Σ c_k e^(2πikt)` in unit coordinates. The mark is inscribed in the
    /// disc of diameter = side, as the ring is. Piece order, clockwise from
    /// the pink.
    private static let iconHarmonics: [[CGFloat]] = [
        // top-left, pink
        [
            -0.00002, 0.00000,
            -0.00005, -0.00006,
            -0.00013, -0.00010,
            -0.00007, -0.00010,
            -0.00027, 0.00022,
            0.00021, 0.00015,
            -0.00028, -0.00059,
            -0.00001, -0.00032,
            0.00137, -0.00019,
            0.00032, -0.00519,
            -0.01288, -0.00390,
            0.00070, -0.02629,
            0.33305, 0.24234,
            0.23430, 0.02736,
            -0.00131, -0.00081,
            -0.00266, 0.00844,
            -0.00673, 0.00061,
            -0.00112, 0.00291,
            0.00097, -0.00085,
            -0.00016, -0.00019,
            -0.00025, 0.00000,
            -0.00010, -0.00009,
            -0.00017, -0.00023,
            -0.00002, 0.00000,
            -0.00008, 0.00000,
        ],
        // top-right, violet
        [
            -0.00006, 0.00002,
            0.00002, -0.00003,
            0.00000, -0.00010,
            -0.00013, 0.00005,
            0.00016, -0.00001,
            -0.00020, 0.00027,
            -0.00029, -0.00038,
            -0.00013, 0.00018,
            -0.00039, 0.00104,
            0.00277, -0.00191,
            -0.00625, 0.00758,
            -0.00427, 0.01975,
            0.79895, 0.29761,
            0.17287, -0.02068,
            -0.00050, 0.00098,
            -0.00264, -0.00654,
            -0.00410, -0.00284,
            0.00158, 0.00114,
            -0.00074, 0.00028,
            0.00001, -0.00012,
            -0.00027, 0.00012,
            -0.00013, 0.00004,
            0.00018, 0.00002,
            -0.00007, 0.00002,
            -0.00001, 0.00009,
        ],
        // bottom-right, mauve
        [
            -0.00001, 0.00006,
            0.00002, -0.00010,
            -0.00001, 0.00015,
            -0.00004, -0.00002,
            0.00029, -0.00001,
            0.00022, 0.00021,
            -0.00028, 0.00086,
            0.00022, -0.00019,
            -0.00137, -0.00009,
            0.00127, -0.00558,
            0.01292, 0.00679,
            0.00755, -0.02251,
            0.62770, 0.74086,
            0.26882, 0.01206,
            0.00112, 0.00012,
            0.00108, 0.00760,
            0.00692, -0.00302,
            0.00013, 0.00374,
            -0.00037, 0.00077,
            -0.00005, -0.00007,
            0.00009, -0.00019,
            -0.00006, -0.00001,
            0.00028, -0.00004,
            -0.00009, -0.00003,
            0.00010, -0.00011,
        ],
        // bottom-left, orchid
        [
            -0.00001, -0.00004,
            -0.00001, 0.00002,
            -0.00005, -0.00002,
            -0.00006, 0.00006,
            0.00012, 0.00001,
            0.00015, 0.00021,
            0.00019, 0.00039,
            0.00013, 0.00023,
            -0.00028, -0.00125,
            0.00099, -0.00107,
            0.00358, -0.00577,
            -0.00508, 0.00898,
            0.16594, 0.65895,
            0.15348, -0.00231,
            0.00043, -0.00002,
            -0.00177, -0.00313,
            0.00209, 0.00302,
            0.00065, 0.00086,
            -0.00003, 0.00055,
            0.00005, -0.00011,
            0.00021, -0.00020,
            0.00002, -0.00012,
            0.00008, -0.00002,
            -0.00005, -0.00008,
            0.00003, 0.00001,
        ],
    ]

    /// A closed outline from its harmonics, densely sampled.
    private static func fourierOutline(_ harmonics: [CGFloat], samples: Int = 1024) -> [CGPoint] {
        let order = harmonics.count / 4
        return (0..<samples).map { sample in
            let t = 2 * .pi * CGFloat(sample) / CGFloat(samples)
            var point = CGPoint.zero
            for index in 0..<(harmonics.count / 2) {
                let re = harmonics[2 * index], im = harmonics[2 * index + 1]
                let angle = CGFloat(index - order) * t
                point.x += re * cos(angle) - im * sin(angle)
                point.y += re * sin(angle) + im * cos(angle)
            }
            return point
        }
    }

    // MARK: - The ring

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
        appendArc(center: center, radius: ringRadius + half, from: a, to: b, into: &points, includeStart: true)
        let capB = CGPoint(x: center.x + ringRadius * cos(b), y: center.y + ringRadius * sin(b))
        appendArc(center: capB, radius: half, from: b, to: b + .pi, into: &points)
        appendArc(center: center, radius: ringRadius - half, from: b, to: a, into: &points)
        let capA = CGPoint(x: center.x + ringRadius * cos(a), y: center.y + ringRadius * sin(a))
        appendArc(center: capA, radius: half, from: a + .pi, to: a + 2 * .pi, into: &points)
        return (points, (a + b) / 2)
    }

    /// Points along the circle about `c` from `a0` to `a1`, the sweep taken
    /// as given — a ring's arc can cover up to 0.7 of the turn.
    private static func appendArc(
        center c: CGPoint, radius r: CGFloat, from a0: CGFloat, to a1: CGFloat,
        into points: inout [CGPoint], includeStart: Bool = false
    ) {
        let sweep = a1 - a0
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
