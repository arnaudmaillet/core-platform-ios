import CoreGraphics
import Foundation

/// When the loader's pieces take which form — pure, so the same pull always
/// draws the same frame and every rule is a test away.
///
/// - **Entry** (`entry(at:)`, #1744): the icon's pieces appear one after
///   another clockwise from the pink, the icon holds, then spins up to loop
///   speed while its pieces thin into the ring's arcs over `morphTurns` whole
///   turns — the morph keyed to the turn, not the clock, so each turn thins
///   them a little more — and lands on the resting ring turning at loop speed.
/// - **Pull** (`pull(_:)`, scrubbed by a finger): the start of that same entry
///   — the appearance and the first `pullTurns` of the spin; the rest plays on
///   release from the frame the pull reached.
/// - **Loop** (`loopKeyframes`): the ring turns once per `rotationPeriod`
///   while its arcs trade length — seeded keyframes that begin and end on
///   equal quarters, over a whole number of turns, so the loop has no seam.
/// - **Exit**: the mark fades and shrinks a little where it is, still
///   turning (the owner, 2026-10-17: no closing back into the mark).
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
    /// Loading ended: the mark fades and shrinks where it is.
    public static let exitFadeDuration: TimeInterval = 0.2
    public static let exitScale: CGFloat = 0.85

    /// Turns per loop — whole, which is what makes the loop seamless.
    public static var turnsPerLoop: Double { loopDuration / rotationPeriod }

    // MARK: - The entry

    /// Each piece's appearance, staggered clockwise from the pink: all four
    /// in by `appearEnd` (0.4 s).
    static let appearStagger: TimeInterval = 0.06
    static let appearLength: TimeInterval = 0.22
    static let appearScale: CGFloat = 0.3
    static var appearEnd: TimeInterval {
        Double(AppLoaderGeometry.pieceCount - 1) * appearStagger + appearLength
    }
    /// The icon holds still until here…
    static let spinStart: TimeInterval = 0.7
    /// …then spins up, accelerating evenly, to one turn per `rotationPeriod`.
    static let spinUpDuration: TimeInterval = 0.8
    /// The whole turns, counted from the spin's start, over which the icon's
    /// pieces thin into the ring's arcs.
    public static let morphTurns: CGFloat = 3
    /// How much of the spin a pull scrubs; the rest plays on release.
    static let pullTurns: CGFloat = 0.5

    /// The turn the spin-up ends on (a third of a turn).
    static var spinUpTurns: CGFloat { CGFloat(spinUpDuration / rotationPeriod / 2) }

    /// From the first piece appearing to the resting ring, without a pull
    /// (≈4.7 s).
    public static var entryDuration: TimeInterval { time(atTurns: morphTurns) }
    /// Where on the entry a full pull is: half a turn into the spin (1.7 s).
    public static var pullDuration: TimeInterval { time(atTurns: pullTurns) }
    /// The mark's turn as the entry lands on the ring.
    public static var landingRotation: CGFloat { 2 * .pi * morphTurns }

    /// The entry's frame `time` seconds in: the pieces appearing, the icon,
    /// then the icon thinning into the ring as it turns; from `entryDuration`
    /// on, the resting ring.
    public static func entry(at time: TimeInterval) -> Frame {
        let turn = rotation(at: time)
        let thinning = time >= entryDuration ? 1 : morph(atRotation: turn)
        var outlines: [[CGPoint]] = []
        var opacities: [CGFloat] = []
        for piece in 0..<AppLoaderGeometry.pieceCount {
            let start = Double(piece) * appearStagger
            let shown = easeOut(CGFloat(min(1, max(0, (time - start) / appearLength))))
            let form = AppLoaderGeometry.mix(
                AppLoaderGeometry.icon(piece), AppLoaderGeometry.restingRing(piece), thinning
            )
            outlines.append(shown >= 1 ? form : AppLoaderGeometry.scaled(form, by: appearScale + (1 - appearScale) * shown))
            opacities.append(shown)
        }
        return Frame(outlines: outlines, opacities: opacities, rotation: turn)
    }

    /// The frame for a pull `progress` (overscroll ÷ threshold), clamped to
    /// 0…1: the entry at `pullTime(progress)`. The same progress always gives
    /// the same frame.
    public static func pull(_ progress: CGFloat) -> Frame {
        entry(at: pullTime(progress))
    }

    /// Where on the entry a pull `progress` is — where release plays on from.
    public static func pullTime(_ progress: CGFloat) -> TimeInterval {
        Double(min(1, max(0, progress))) * pullDuration
    }

    /// The rest of the entry from `start`, sampled evenly in time at
    /// `entryFrameRate` — its first frame `entry(at: start)`, its last the
    /// resting ring. Played linearly over `entryDuration − start`.
    public static func entryRoute(from start: TimeInterval) -> [Frame] {
        let begin = min(max(0, start), entryDuration)
        let steps = max(1, Int(((entryDuration - begin) * entryFrameRate).rounded(.up)))
        return (0...steps).map { step in
            entry(at: step == steps ? entryDuration : begin + (entryDuration - begin) * Double(step) / Double(steps))
        }
    }

    /// Keyframes per second of the entry; the path animation interpolates
    /// between them.
    static let entryFrameRate: Double = 30

    /// Still until `spinStart`, an even spin-up over `spinUpDuration`, then
    /// one turn per `rotationPeriod` — on past the landing, as the loop does.
    static func rotation(at time: TimeInterval) -> CGFloat {
        let speed = 2 * .pi / rotationPeriod
        let spun = time - spinStart
        guard spun > 0 else { return 0 }
        if spun < spinUpDuration { return CGFloat(speed * spun * spun / (2 * spinUpDuration)) }
        return CGFloat(speed * (spinUpDuration / 2 + spun - spinUpDuration))
    }

    /// When the spin has made `turns` turns.
    static func time(atTurns turns: CGFloat) -> TimeInterval {
        let made = Double(max(0, turns))
        if made < Double(spinUpTurns) {
            return spinStart + (2 * spinUpDuration * made * rotationPeriod).squareRoot()
        }
        return spinStart + spinUpDuration + (made - Double(spinUpTurns)) * rotationPeriod
    }

    /// How far the icon has thinned into the ring after the spin's `rotation`:
    /// 0 still, 1 at `morphTurns` turns. Close to linear
    /// (`0.75·x + 0.25·sine`), so no single turn does most of the thinning.
    static func morph(atRotation rotation: CGFloat) -> CGFloat {
        let x = min(1, max(0, rotation / landingRotation))
        return 0.75 * x + 0.25 * (1 - cos(.pi * x)) / 2
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
