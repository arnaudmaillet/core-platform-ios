import CoreGraphics
import Foundation

/// When the loader's pieces take which form (#1329) — pure, so the same pull
/// always draws the same frame and every rule is a test away.
///
/// - **Pull** (`pull(_:)`, scrubbed by a finger): the pills appear one after
///   another clockwise from the pink, the square rounds into the disc, the disc
///   opens into the ring, and from ≈0.35 the mark turns, accelerating, half a
///   turn by the threshold.
/// - **Loop** (`loopKeyframes`): the ring turns once per `rotationPeriod`
///   while its arcs trade length — seeded keyframes that begin and end on
///   equal quarters, over a whole number of turns, so the loop has no seam.
/// - **Exit**: ring → disc → square, then the mark fades and shrinks a little.
public enum AppLoaderTimeline {
    /// One frame of the four pieces.
    public struct Frame: Equatable {
        /// Normalised outlines, one per piece (`AppLoaderGeometry`).
        public var outlines: [[CGPoint]]
        public var opacities: [CGFloat]
        /// The whole mark's turn, in radians, clockwise.
        public var rotation: CGFloat
    }

    // MARK: - Timings

    /// One turn of the ring while loading.
    public static let rotationPeriod: TimeInterval = 1.2
    /// One loop of the arcs trading length — three turns, so it closes on
    /// the frame it opened with.
    public static let loopDuration: TimeInterval = 3.6
    /// Without a pull: pills in, square → disc → ring.
    public static let entryDuration: TimeInterval = 0.6
    /// Ring → disc → square once loading ends.
    public static let exitMorphDuration: TimeInterval = 0.9
    /// Then the mark fades and shrinks.
    public static let exitFadeDuration: TimeInterval = 0.2
    public static let exitScale: CGFloat = 0.85

    /// Turns per loop — whole, which is what makes the loop seamless.
    public static var turnsPerLoop: Double { loopDuration / rotationPeriod }

    // MARK: - The pull

    /// Where the pills have all appeared (the square at rest).
    static let appearEnd: CGFloat = 0.25
    /// Where the square has become the disc.
    static let discAt: CGFloat = 0.60
    /// Where the mark starts to turn.
    static let turnStart: CGFloat = 0.35
    /// Each pill's appearance, staggered clockwise.
    static let appearStagger: CGFloat = 0.05
    static let appearLength: CGFloat = 0.10
    static let appearScale: CGFloat = 0.3

    /// The frame for a pull `progress` (overscroll ÷ threshold), clamped to
    /// 0…1. The same progress always gives the same frame.
    public static func pull(_ progress: CGFloat) -> Frame {
        let p = min(1, max(0, progress))
        var outlines: [[CGPoint]] = []
        var opacities: [CGFloat] = []
        for piece in 0..<AppLoaderGeometry.pieceCount {
            let start = CGFloat(piece) * appearStagger
            let shown = easeOut(min(1, max(0, (p - start) / appearLength)))
            outlines.append(AppLoaderGeometry.scaled(form(at: p, piece: piece), by: appearScale + (1 - appearScale) * shown))
            opacities.append(shown)
        }
        return Frame(outlines: outlines, opacities: opacities, rotation: pullRotation(p))
    }

    /// The square up to `appearEnd`, the disc at `discAt`, the resting ring at 1.
    static func form(at p: CGFloat, piece: Int) -> [CGPoint] {
        if p <= appearEnd { return AppLoaderGeometry.square(piece) }
        if p <= discAt {
            let t = easeInOut((p - appearEnd) / (discAt - appearEnd))
            return AppLoaderGeometry.mix(AppLoaderGeometry.square(piece), AppLoaderGeometry.disc(piece), t)
        }
        let t = easeInOut((p - discAt) / (1 - discAt))
        return AppLoaderGeometry.mix(AppLoaderGeometry.disc(piece), AppLoaderGeometry.restingRing(piece), t)
    }

    /// Still until `turnStart`, then accelerating: half a turn by the threshold.
    static func pullRotation(_ p: CGFloat) -> CGFloat {
        guard p > turnStart else { return 0 }
        let t = (p - turnStart) / (1 - turnStart)
        return .pi * t * t
    }

    // MARK: - The loop

    /// The seed the shipped loop is drawn from.
    public static let defaultSeed: UInt64 = 0x5EED_1329

    /// Arc fractions over one loop: equal quarters, `anchors` seeded shapes
    /// (each arc at least `minimumFraction`, the four summing to 1), equal
    /// quarters again — then `samplesPerStep` eased steps between each pair,
    /// so every keyframe is an exact ring and the path interpolation between
    /// neighbours stays a hair from one.
    public static func loopFractions(
        seed: UInt64 = defaultSeed, anchors: Int = 4, samplesPerStep: Int = 9
    ) -> [[CGFloat]] {
        var generator = SplitMix64(seed: seed)
        var keys = [AppLoaderGeometry.equalQuarters]
        for _ in 0..<anchors {
            let weights = (0..<AppLoaderGeometry.pieceCount).map { _ in 0.15 + generator.nextUnit() }
            let total = weights.reduce(0, +)
            let free = 1 - CGFloat(AppLoaderGeometry.pieceCount) * minimumFraction
            keys.append(weights.map { minimumFraction + free * CGFloat($0 / total) })
        }
        keys.append(AppLoaderGeometry.equalQuarters)
        var frames: [[CGFloat]] = []
        for index in 0..<(keys.count - 1) {
            for step in 0..<samplesPerStep {
                let t = easeInOut(CGFloat(step) / CGFloat(samplesPerStep))
                frames.append(zip(keys[index], keys[index + 1]).map { $0 + ($1 - $0) * t })
            }
        }
        frames.append(AppLoaderGeometry.equalQuarters)
        return frames
    }

    /// The smallest share of the turn an arc ever covers.
    public static let minimumFraction: CGFloat = 0.1

    /// The loop's outlines per piece: `[piece][keyframe]`.
    public static func loopKeyframes(seed: UInt64 = defaultSeed) -> [[[CGPoint]]] {
        let rings = loopFractions(seed: seed).map(AppLoaderGeometry.ring(fractions:))
        return (0..<AppLoaderGeometry.pieceCount).map { piece in rings.map { $0[piece] } }
    }

    // MARK: - Easing

    static func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

    static func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// A small deterministic generator, so a seed always draws the same loop.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
