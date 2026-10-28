import CoreGraphics
import Foundation

/// The loader's wave (#1795, the owner 2026-10-27): three pills rippling left
/// to right, never stopping — pure, so the same time always draws the same
/// frame and every rule is a test away.
///
/// ONE FUNCTION OF TIME, TWO DRIVERS:
/// - each pill's height is a continuous cosine, `½ − ½·cos(2πt / period)`:
///   no hold at the top, no rest at the bottom; pill `i` runs `i × stagger`
///   behind pill `i − 1`;
/// - the PULL reads it at `t = progress × period`, so a full pull plays at
///   most one cycle and pulling back plays it in reverse. Each pill stays a
///   dot until its own time starts — progress 0 is three dots — and the cosine
///   leaves zero with zero speed, so each start is smooth;
/// - the LOOP (loading) runs the same function from the `t` the pull reached,
///   so a release never jumps.
///
/// Behind each pill, its LEAD: the same pill `leadAhead` seconds ahead, in a
/// lighter tone — a pale wake while the pill rises, hidden behind it while it
/// falls. Its head start grows in over the first `leadAhead` of the wave, so
/// pull 0 is three plain dots.
///
/// Exit: the pills fade and shrink a little where they are.
public enum AppLoaderTimeline {
    /// The heights, 0 (a dot) … 1 (the peak), of the pills and their leads.
    public struct Frame: Equatable {
        public var heights: [CGFloat]
        public var leadHeights: [CGFloat]
    }

    // MARK: - Timings

    /// One cycle of a pill: dot, peak, dot.
    public static let period: TimeInterval = 1.2
    /// How far each pill runs behind the one before it: a sixth of a cycle.
    public static let stagger: TimeInterval = 0.2
    /// How far each lead runs ahead of its pill.
    public static let leadAhead: TimeInterval = 0.1
    /// Loading ended: the pills fade and shrink where they are.
    public static let exitFadeDuration: TimeInterval = 0.2
    public static let exitScale: CGFloat = 0.85

    // MARK: - The wave

    /// One pill's height `time` seconds into its own cycle: 0 before it
    /// starts, then the continuous cosine.
    public static func wave(at time: TimeInterval) -> CGFloat {
        guard time > 0 else { return 0 }
        return CGFloat(0.5 - 0.5 * cos(2 * .pi * time / period))
    }

    /// Pill `index`'s height `time` seconds into the wave.
    public static func height(pill index: Int, at time: TimeInterval) -> CGFloat {
        wave(at: time - Double(index) * stagger)
    }

    /// Pill `index`'s lead's height: the pill, `leadAhead` ahead — that head
    /// start growing in over the wave's first `leadAhead`, so nothing shows
    /// before the wave starts.
    public static func leadHeight(pill index: Int, at time: TimeInterval) -> CGFloat {
        guard time > 0 else { return 0 }
        return wave(at: time - Double(index) * stagger + min(time, leadAhead))
    }

    /// The whole frame `time` seconds into the wave.
    public static func frame(at time: TimeInterval) -> Frame {
        let pills = 0..<AppLoaderGeometry.pillCount
        return Frame(
            heights: pills.map { height(pill: $0, at: time) },
            leadHeights: pills.map { leadHeight(pill: $0, at: time) }
        )
    }

    // MARK: - The pull

    /// The frame for a pull `progress` (overscroll ÷ threshold), clamped to
    /// 0…1. The same progress always gives the same frame.
    public static func pull(_ progress: CGFloat) -> Frame {
        frame(at: pullTime(progress))
    }

    /// Where on the wave a pull `progress` is — where release plays on from.
    public static func pullTime(_ progress: CGFloat) -> TimeInterval {
        Double(min(1, max(0, progress))) * period
    }

    // MARK: - The loop

    /// One cycle of a pill's height, sampled evenly from the start of its
    /// cycle — the keyframes the loop repeats. The first and last are the
    /// same dot, so the repeat has no seam.
    public static func cycleSamples(count: Int = 48) -> [CGFloat] {
        (0...count).map { step in
            step == count ? 0 : wave(at: period * Double(step) / Double(count))
        }
    }

    /// Where in its own cycle pill `index` is `time` seconds into the wave —
    /// negative while it has yet to start (its loop then waits that long).
    public static func cycleTime(pill index: Int, at time: TimeInterval, lead: Bool = false) -> TimeInterval {
        let own = time - Double(index) * stagger + (lead ? min(max(0, time), leadAhead) : 0)
        guard own > 0 else { return own }
        return own.truncatingRemainder(dividingBy: period)
    }
}
